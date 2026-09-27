module Fluxion::Executor
  # What `cargo install --list` says about one crate.
  #
  # It prints every installed crate and pays no attention to the name it was
  # asked about, so its exit code says nothing about this item and the listing
  # has to be scanned the way the flatpak probe scans its own.
  #
  # Each crate is a line at column 0 reading "name vX.Y.Z:", with the source
  # in parentheses when it came from a git checkout or a local path, and the
  # binaries it provides indented underneath. Matching on the name followed
  # by a space is therefore enough to tell a crate named `rg` from a binary
  # named `rg` listed under some other crate.
  #
  # The cargo asked is the one on PATH or, failing that, the one rustup
  # installs into `$CARGO_HOME/bin` (`~/.cargo/bin` when unset). rustup adds
  # that directory to PATH only through `~/.cargo/env`, which a shell sources
  # at login — and not at all under `--no-modify-path` — so a report run from
  # any other shell used to call every crate unknown although cargo was right
  # there to ask.
  module CargoInstallList
    LIST_ARGV = PackageManager::Cargo.query_argv("")

    # The listing for the cargo `executable` found, or nil without one.
    def self.list(runner : ShellRunner) : ProcessResult?
      cargo = executable(runner)
      return unless cargo
      runner.run(Command.new([cargo] + LIST_ARGV[1..], timeout: PROBE_TIMEOUT))
    end

    def self.executable(runner : ShellRunner) : String?
      command = LIST_ARGV.first
      return command if runner.command_exists?(command)

      fallback = File.join(home, "bin", command)
      fallback if File.file?(fallback) && File::Info.executable?(fallback)
    end

    def self.home : String
      ENV["CARGO_HOME"]?.presence || File.join(Host.home, ".cargo")
    end

    def self.not_found(key : String) : InstallationStatus
      InstallationStatus::Unknown.new(key, "cargo is not on PATH or in #{File.join(home, "bin")}")
    end

    def self.status(key : String, result : ProcessResult) : InstallationStatus
      unless result.success?
        return InstallationStatus::Unknown.new(key, "cargo install --list exited #{result.exit_code}")
      end

      line = result.stdout.lines.find(&.starts_with?("#{key} "))
      return InstallationStatus::NotInstalled.new(key) unless line

      # "ripgrep v14.1.0:" and "mycrate v0.1.0 (/home/me/src):" both yield the
      # bare version, since only the first spelling carries the colon.
      version = line.split(' ')[1]?.try(&.lchop('v').rchop(':'))
      InstallationStatus::InstalledByProbe.new(key, version.presence)
    end
  end

  # `tool-packages` items installed by `cargo` or `cargo-binstall`.
  #
  # cargo-binstall records what it installs in cargo's own install list, so
  # both backends are answered by the same listing `PackageProbe` reads for
  # `cargo-packages`. Without this every crate was unknown to `status`, and
  # `--re-probe` ran every install again.
  #
  # The other backends are not claimed, so a step's `probeCommand` still
  # answers for them.
  class ToolPackageProbe < Probe
    BACKENDS = [ToolBackend::Cargo, ToolBackend::CargoBinstall]

    def supports?(item : StepItem) : Bool
      item.item_type.tool_package? && !package(item).nil?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      package = package(item).not_nil!
      listing = CargoInstallList.list(runner)
      return CargoInstallList.not_found(item.key) unless listing

      status = CargoInstallList.status(item.key, listing)
      pin = package.version
      return status unless pin && status.is_a?(InstallationStatus::InstalledByProbe)

      pinned?(status.detected_version, pin) ? status : InstallationStatus::NotInstalled.new(item.key)
    end

    # A crate installed at another version than the pin is not the configured
    # item, the same reading `GitRepoProbe` gives a checkout at the wrong
    # commit; otherwise a changed pin would never be applied under
    # `--re-probe`. A plain or partial version ("0.10.2", "0.10", "=0.10.2")
    # is compared component by component. A requirement with an operator is
    # left to the installer, which resolves it against the registry — this
    # probe cannot, so presence is the answer it gives.
    private def pinned?(installed : String?, pin : String) : Bool
      wanted = pin.strip.lchop('=').strip
      return true unless wanted.matches?(/\A\d+(\.\d+){0,2}(-[0-9A-Za-z.-]+)?\z/)
      return false unless installed

      installed == wanted || installed.starts_with?("#{wanted}.")
    end

    private def package(item : StepItem) : ToolPackage?
      step = item.step.as?(ToolPackagesStep)
      return unless step && BACKENDS.includes?(step.backend)
      step.packages.find { |candidate| candidate.name == item.key }
    end
  end
end
