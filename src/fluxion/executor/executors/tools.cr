module Fluxion::Executor
  # The external tools Fluxion delegates to, with their release digests.
  #
  # The digests are the point. Fluxion downloads these tools and then runs
  # them, so a release asset it cannot recognise is not installed — the catalog
  # is the trust anchor, not the fact that GitHub served the bytes.
  module KnownTools
    extend self

    record Spec,
      name : String,
      repository : String,
      version : String,
      asset_template : String,
      executable : String,
      digests : Hash(String, String) do
      # Release assets are named per platform, so the template is expanded
      # against the host rather than guessed.
      def asset(architecture : Architecture) : String
        asset_template
          .gsub("${name}", name)
          .gsub("${version}", version)
          .gsub("${os}", "linux")
          .gsub("${arch}", architecture.config_name)
      end

      def url(architecture : Architecture) : String
        "https://github.com/#{repository}/releases/download/#{version}/#{asset(architecture)}"
      end

      def digest(architecture : Architecture) : String?
        digests[asset(architecture)]?
      end
    end

    DOTBOT = Spec.new(
      name: "dotbot",
      repository: "worxbend/dotbot-go",
      version: DotbotStep::DEFAULT_INSTALLER_VERSION,
      asset_template: "dotbot-${os}-${arch}.tar.gz",
      executable: "dotbot",
      digests: {
        "dotbot-linux-amd64.tar.gz" => "a7229b8d098454ffeb2858ddcf1b63602dfc7be06e08b57c39d839c08f9dbd01",
        "dotbot-linux-arm64.tar.gz" => "21e94e915de43f2cbe086973437ec6a5f81e46ddbc5280707165c0ebb6090b45",
      },
    )

    NERD_FONTS = Spec.new(
      name: "nerd-fonts-installer",
      repository: "worxbend/nerd-fonts-installer",
      version: NerdFontsStep::DEFAULT_INSTALLER_VERSION,
      asset_template: "nerd-fonts-installer_${version}_${os}_${arch}.tar.gz",
      executable: "nerd-fonts-installer",
      digests: {
        "nerd-fonts-installer_v1.0.7_linux_amd64.tar.gz" => "0903de2304b07035794546256cbfbfe117a04c12d1e9ae92c544e8a9ee7bd8b2",
        "nerd-fonts-installer_v1.0.7_linux_arm64.tar.gz" => "49b30cf173b6a5465dcc7271ae19b5dddf083ba360cc51063121773ad3da6517",
      },
    )

    BINSTALLER = Spec.new(
      name: "binstaller",
      repository: "worxbend/binstaller",
      version: BinstallerProfileStep::DEFAULT_INSTALLER_VERSION,
      asset_template: "binstaller-${version}-${os}-${arch}.tar.gz",
      executable: "binstaller",
      digests: {
        "binstaller-v0.2.0-linux-amd64.tar.gz" => "802bf5da1f6af5f0f00984751f45cb5c0448ee24283729ff21e5ea7f0718f951",
        "binstaller-v0.2.0-linux-arm64.tar.gz" => "48135498e3973347b6c0f0b843942def56f5dbba22c95d8f75d5272186a74d52",
      },
    )

    def all : Array(Spec)
      [DOTBOT, NERD_FONTS, BINSTALLER]
    end
  end

  # Finds a delegated tool, downloading it only when the host has none.
  #
  # Resolution order matters: a copy already on PATH is used as-is and never
  # replaced. Fluxion is a bootstrapper, not a package manager for other
  # people's tools — if the user manages `dotbot` themselves, theirs wins.
  class ToolBroker
    include DownloadSupport

    def initialize(@runner : ShellRunner)
    end

    def self.cache_root : String
      File.join(Paths.cache_root, "tools")
    end

    # Where a tool would come from, without fetching anything. Backs
    # `fluxion tools list`.
    enum Source
      Path
      Cache
      Download
    end

    record Resolution, source : Source, path : String, spec : KnownTools::Spec

    def locate(spec : KnownTools::Spec) : Resolution
      if found = on_path(spec.executable)
        return Resolution.new(Source::Path, found, spec)
      end

      cached = cache_path(spec)
      return Resolution.new(Source::Cache, cached, spec) if usable?(cached)

      architecture = Host.architecture || Architecture::Amd64
      Resolution.new(Source::Download, spec.url(architecture), spec)
    end

    # Returns an executable path, downloading and verifying if necessary.
    def resolve(spec : KnownTools::Spec) : String
      resolution = locate(spec)
      return resolution.path unless resolution.source.download?

      install(spec)
    end

    def install(spec : KnownTools::Spec) : String
      architecture = Host.architecture || Architecture::Amd64
      asset = spec.asset(architecture)

      digest = spec.digest(architecture)
      unless digest
        # Refusing beats downloading something unverifiable: this tool is about
        # to be executed.
        raise TrustError.new(
          "#{asset} is not in Fluxion's trusted release-digest catalog")
      end

      destination = cache_path(spec)
      Dir.mkdir_p(File.dirname(destination), 0o700)

      with_workspace do |workspace|
        archive = File.join(workspace, asset)
        downloader.download_verified(spec.url(architecture), archive,
          Checksum.new(ChecksumAlgorithm::Sha256, digest))

        member = Archive.members(archive).find { |entry| File.basename(entry.path) == spec.executable }
        unless member
          raise TrustError.new("#{asset} does not contain an executable named #{spec.executable}")
        end

        extracted = File.join(workspace, spec.executable)
        Archive.extract(archive, member.path, extracted)
        File.chmod(extracted, 0o700)
        File.rename(extracted, destination)
      end

      destination
    end

    private def cache_path(spec : KnownTools::Spec) : String
      File.join(ToolBroker.cache_root, spec.name, spec.version, spec.executable)
    end

    # One question, one answer. This used to ask the injected runner whether the
    # command existed and then walk `PATH` itself, so a substituted runner could
    # say yes while the second scan said no — the seam reporting a
    # contradiction with itself.
    private def on_path(executable : String) : String?
      @runner.resolve_command(executable)
    end

    private def usable?(path : String) : Bool
      info = File.info?(path)
      !info.nil? && info.file? && info.permissions.owner_execute?
    end
  end

  # The kinds that hand their work to another tool.
  #
  # Each runs one delegated executable against that tool's own config file, so
  # the only things that differ between them are which tool, how long it may
  # take, and how its argument list is spelled.
  abstract class DelegatedToolExecutor < StepExecutor
    abstract def spec : KnownTools::Spec
    abstract def timeout : Time::Span
    abstract def config_label : String
    protected abstract def argv(step : Step, executable : String, preview : Bool) : Array(String)

    def commands(step : Step, item : StepItem) : Array(Command)
      [Command.new(argv(step, spec.executable, true), timeout: preview_timeout)]
    end

    # Same as the run unless the delegate's dry run is cheaper.
    def preview_timeout : Time::Span
      timeout
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      started = Time.instant
      config = step.delegated_config

      unless config && File.exists?(config)
        return StepResult::Failure.new(item.key, "#{config_label} config not found: #{config}", 1)
      end

      executable = ToolBroker.new(runner).resolve(spec)
      result = runner.run(Command.new(argv(step, executable, false), timeout: timeout)) do |line|
        sink.call(line)
      end

      outcome(item, result, started, spec.name)
    rescue error : Error
      failure(item, error, "failed to prepare #{spec.name}")
    end
  end

  # `dotbot` — apply a dotfiles configuration.
  class DotbotExecutor < DelegatedToolExecutor
    TIMEOUT = 5.minutes

    def supports?(step : Step) : Bool
      step.is_a?(DotbotStep)
    end

    def spec : KnownTools::Spec
      KnownTools::DOTBOT
    end

    def timeout : Time::Span
      TIMEOUT
    end

    def config_label : String
      "dotbot"
    end

    # dotbot's own dry run, so the preview is its per-link plan rather than an
    # opaque command string. Same flag spelling as the run: the preview used
    # `-c` where `execute` uses `--config`, and took its executable from a
    # `dotbotBinary` field the run ignored — so the two could name a
    # different program with a different flag.
    protected def argv(step : Step, executable : String, preview : Bool) : Array(String)
      argv = [executable, "--config", step.as(DotbotStep).config]
      argv << "--dry-run" if preview
      argv
    end
  end

  # `nerd-fonts` — install font families.
  class NerdFontsExecutor < DelegatedToolExecutor
    TIMEOUT = 15.minutes

    def supports?(step : Step) : Bool
      step.is_a?(NerdFontsStep)
    end

    def spec : KnownTools::Spec
      KnownTools::NERD_FONTS
    end

    def timeout : Time::Span
      TIMEOUT
    end

    def config_label : String
      "nerd-fonts"
    end

    # The installer's own dry run, so the preview is its per-family plan
    # rather than an opaque command string.
    protected def argv(step : Step, executable : String, preview : Bool) : Array(String)
      argv = [executable, "--config", step.as(NerdFontsStep).config]
      argv << "--dry-run" if preview
      argv
    end
  end

  # `binstaller-profile` — hand binary distribution to binstaller.
  class BinstallerExecutor < DelegatedToolExecutor
    APPLY_TIMEOUT = 30.minutes
    PLAN_TIMEOUT  = 5.minutes

    def supports?(step : Step) : Bool
      step.is_a?(BinstallerProfileStep)
    end

    def spec : KnownTools::Spec
      KnownTools::BINSTALLER
    end

    def timeout : Time::Span
      APPLY_TIMEOUT
    end

    def preview_timeout : Time::Span
      PLAN_TIMEOUT
    end

    def config_label : String
      "binstaller"
    end

    # The one place a binstaller invocation is built.
    #
    # A preview must never be able to install anything, so it maps onto
    # binstaller's `plan`, never its `apply`. Everything else about the
    # invocation is identical to the run, because both come from here — the
    # preview used to assemble its own, omitting the lock flags entirely, so
    # `dry-run` described a different command than `apply` ran.
    protected def argv(step : Step, executable : String, preview : Bool) : Array(String)
      profile = step.as(BinstallerProfileStep)
      argv = [executable, preview ? "plan" : "apply", "--config", profile.config]
      profile.only.each { |tool| argv.concat(["--only", tool]) }
      profile.skip.each { |tool| argv.concat(["--skip", tool]) }

      argv << "--locked" if profile.locked?
      # Outside the `locked?` branch: `lockFile` without `locked` used to be
      # accepted by the parser and then silently dropped here, so a profile
      # naming a lock file ran unlocked against whatever was current.
      profile.lock_file.try { |lock| argv.concat(["--lock-file", lock]) }
      argv
    end
  end
end
