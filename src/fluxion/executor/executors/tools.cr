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

  # `dotbot` — apply a dotfiles configuration.
  class DotbotExecutor < StepExecutor
    TIMEOUT = 5.minutes

    def supports?(step : Step) : Bool
      step.is_a?(DotbotStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      dotbot = step.as(DotbotStep)
      # The preview is dotbot's own dry run rather than an opaque command
      # string, so what is shown is dotbot's per-link plan.
      [Command.new([dotbot.binary, "-c", dotbot.config, "--dry-run"], timeout: TIMEOUT)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      dotbot = step.as(DotbotStep)
      started = Time.instant

      unless File.exists?(dotbot.config)
        return StepResult::Failure.new(item.key, "dotbot config not found: #{dotbot.config}", 1)
      end

      executable = ToolBroker.new(runner).resolve(KnownTools::DOTBOT)
      result = runner.run(Command.new([executable, "--config", dotbot.config], timeout: TIMEOUT)) do |line|
        sink.call(line)
      end

      outcome(item, result, started, "dotbot")
    rescue error : Error
      StepResult::Failure.new(item.key, "failed to prepare dotbot: #{error.message}", 1)
    end
  end

  # `nerd-fonts` — install font families.
  class NerdFontsExecutor < StepExecutor
    include DownloadSupport

    TIMEOUT = 15.minutes

    def supports?(step : Step) : Bool
      step.is_a?(NerdFontsStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      fonts = step.as(NerdFontsStep)
      config = fonts.config_path || "<generated from profile>"
      [Command.new([fonts.binary, "--config", config, "--dry-run"], timeout: TIMEOUT)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      fonts = step.as(NerdFontsStep)
      started = Time.instant
      executable = ToolBroker.new(runner).resolve(KnownTools::NERD_FONTS)

      with_workspace do |workspace|
        config = fonts.config_path || render_config(fonts, workspace)
        unless File.exists?(config)
          return StepResult::Failure.new(item.key, "nerd-fonts config not found: #{config}", 1)
        end

        result = runner.run(Command.new([executable, "--config", config], timeout: TIMEOUT)) do |line|
          sink.call(line)
        end

        outcome(item, result, started, "nerd-fonts-installer")
      end
    rescue error : Error
      StepResult::Failure.new(item.key, "failed to prepare nerd-fonts-installer: #{error.message}", 1)
    end

    # An inline profile config is rendered into the installer's own format, so
    # the profile stays the single source of truth for the font set.
    private def render_config(step : NerdFontsStep, workspace : String) : String
      config = step.config
      raise ExecutionError.new("nerd-fonts requires either config or configPath") unless config

      path = File.join(workspace, "nerd-fonts.yaml")
      File.write(path, String.build do |io|
        io << "release: " << config.release << '\n'
        config.destination.try { |destination| io << "destination: " << destination << '\n' }
        io << "refresh_font_cache: " << config.refresh_font_cache? << '\n'
        io << "families:\n"
        config.families.each { |family| io << "  - " << family << '\n' }
      end)
      path
    end
  end

  # `binstaller-profile` — hand binary distribution to binstaller.
  class BinstallerExecutor < StepExecutor
    APPLY_TIMEOUT = 30.minutes
    PLAN_TIMEOUT  = 5.minutes

    def supports?(step : Step) : Bool
      step.is_a?(BinstallerProfileStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      profile = step.as(BinstallerProfileStep)
      # A preview must never be able to install anything, so it maps onto
      # binstaller's `plan`, never its `apply`. Everything else about the
      # invocation is identical to the run, because both come from `argv`.
      [Command.new(argv(profile, "plan", KnownTools::BINSTALLER.executable), timeout: PLAN_TIMEOUT)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      profile = step.as(BinstallerProfileStep)
      started = Time.instant

      unless File.exists?(profile.config)
        return StepResult::Failure.new(item.key, "binstaller config not found: #{profile.config}", 1)
      end

      executable = ToolBroker.new(runner).resolve(KnownTools::BINSTALLER)
      result = runner.run(Command.new(argv(profile, "apply", executable), timeout: APPLY_TIMEOUT)) do |line|
        sink.call(line)
      end
      outcome(item, result, started, "binstaller")
    rescue error : Error
      StepResult::Failure.new(item.key, "failed to prepare binstaller: #{error.message}", 1)
    end

    # The one place a binstaller invocation is built.
    #
    # The preview used to assemble its own, omitting the lock flags entirely, so
    # `plan --show-commands` described a different command than `apply` ran —
    # in a codebase whose whole point is that both come from one method.
    private def argv(step : BinstallerProfileStep, verb : String, executable : String) : Array(String)
      argv = [executable, verb, "--config", step.config]
      step.only.each { |tool| argv.concat(["--only", tool]) }
      step.skip.each { |tool| argv.concat(["--skip", tool]) }

      argv << "--locked" if step.locked?
      # Outside the `locked?` branch: `lockFile` without `locked` used to be
      # accepted by the parser and then silently dropped here, so a profile
      # naming a lock file ran unlocked against whatever was current.
      step.lock_file.try { |lock| argv.concat(["--lock-file", lock]) }
      argv
    end
  end
end
