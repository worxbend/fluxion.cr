module Fluxion::Executor
  # Shared plumbing for kinds that fetch something before they can act.
  #
  # The ordering is deliberate everywhere it appears: download, verify, *then*
  # use. Nothing here hands an unverified path to anything that executes or
  # installs it.
  module DownloadSupport
    # Runs a block with a private scratch directory that is always removed.
    protected def with_workspace(& : String -> T) : T forall T
      directory = File.tempname("fluxion")
      Dir.mkdir_p(directory, 0o700)
      begin
        yield directory
      ensure
        FileUtils.rm_rf(directory) rescue nil
      end
    end

    # The seam. Overridable rather than a constructor argument because
    # `ExecutorRegistry.default` builds every executor with none — a spec
    # subclasses the executor it is exercising and returns a
    # `FakeHttpTransport`, which is what makes `execute` reachable without a
    # network.
    protected def http_transport : HttpTransport
      SystemHttpTransport.new
    end

    protected def downloader(max_bytes : Int64 = Downloader::MAX_ARTIFACT_BYTES) : Downloader
      Downloader.new(max_bytes, http_transport)
    end
  end

  # `toolchain` — run an upstream installer script at a pinned digest.
  #
  # The pin is what makes this safe to automate: when upstream changes the
  # script the run fails rather than executing bytes nobody reviewed.
  class ToolchainExecutor < StepExecutor
    include DownloadSupport

    INSTALL_TIMEOUT = 15.minutes

    def supports?(step : Step) : Bool
      step.is_a?(ToolchainStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      toolchain = step.as(ToolchainStep)
      preview = ["download", PublicUrl.from(toolchain.install_script_url),
                 "verify", toolchain.sha256.value, "run", "sh"]
      [Command.new(preview + toolchain.install_args)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      toolchain = step.as(ToolchainStep)
      started = Time.instant

      with_workspace do |workspace|
        script = File.join(workspace, "install.sh")
        sink.call("downloading #{PublicUrl.from(toolchain.install_script_url)}")
        downloader(Downloader::MAX_TEXT_BYTES)
          .download_verified(toolchain.install_script_url, script, toolchain.sha256)

        result = runner.run(Command.new(
          ["sh", script] + toolchain.install_args,
          env: environment(toolchain),
          timeout: INSTALL_TIMEOUT,
        )) { |line| sink.call(line) }

        outcome(item, result, started, "toolchain installer")
      end
    rescue error : Error
      failure(item, error)
    end

    # Each installer reads its own variables, and leaving them unset makes them
    # guess at locations that may not match the rest of the profile.
    private def environment(step : ToolchainStep) : Hash(String, String)
      home = Host.home
      case step.toolchain
      when .rustup?
        {
          "RUSTUP_INIT_SKIP_PATH_CHECK" => "yes",
          "CARGO_HOME"                  => File.join(home, ".cargo"),
          "RUSTUP_HOME"                 => File.join(home, ".rustup"),
        }
      when .sdkman?
        {"SDKMAN_DIR" => File.join(home, ".sdkman")}
      else
        {} of String => String
      end
    end
  end

  # `oh-my-zsh` — install at an exact commit.
  #
  # The commit is part of the URL, so the pinned digest describes exactly the
  # installer that will run. A branch would make the digest meaningless.
  class OhMyZshExecutor < StepExecutor
    include DownloadSupport

    INSTALL_TIMEOUT = 5.minutes
    INSTALLER_URL   = "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/%s/tools/install.sh"

    def supports?(step : Step) : Bool
      step.is_a?(OhMyZshStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      omz = step.as(OhMyZshStep)
      [Command.new(["download", installer_url(omz), "verify", omz.sha256.value, "run", "sh"])]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      omz = step.as(OhMyZshStep)
      started = Time.instant

      with_workspace do |workspace|
        script = File.join(workspace, "install.sh")
        sink.call("downloading oh-my-zsh installer at #{omz.revision[0, 7]}")
        downloader(Downloader::MAX_TEXT_BYTES).download_verified(installer_url(omz), script, omz.sha256)

        result = runner.run(Command.new(
          ["sh", script],
          # The installer would otherwise start an interactive shell and change
          # the login shell itself; both are the profile's decisions, not its.
          env: {
            "RUNZSH" => "no",
            "CHSH"   => "no",
            "ZSH"    => omz.install_dir,
            "HOME"   => Host.home,
          },
          timeout: INSTALL_TIMEOUT,
        )) { |line| sink.call(line) }

        outcome(item, result, started, "oh-my-zsh installer")
      end
    rescue error : Error
      failure(item, error)
    end

    private def installer_url(step : OhMyZshStep) : String
      INSTALLER_URL % step.revision
    end
  end

  # `file-writes` — write files from inline content or a local source.
  class FileWriteExecutor < StepExecutor
    def supports?(step : Step) : Bool
      step.is_a?(FileWriteStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      file = find(step, item)
      return [] of Command unless file

      preview = ["write", file.destination, file.content ? "content" : "source"]
      file.source.try { |source| preview << source }
      file.mode.try { |mode| preview.concat(["mode", mode]) }
      file.owner.try { |owner| preview.concat(["owner", owner]) }
      file.group.try { |group| preview.concat(["group", group]) }
      [Command.new(preview)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &_sink : String ->) : StepResult
      file = find(step, item)
      return StepResult::Success.new(item.key) unless file
      started = Time.instant

      content = if inline = file.content
                  inline
                else
                  source = file.source.not_nil!
                  unless File.exists?(source)
                    return StepResult::Failure.new(item.key, "source file not found: #{source}", 1)
                  end
                  File.read(source)
                end

      Installer.new(runner).write(content, file.destination,
        file.mode || "0644", file.owner, file.group)

      StepResult::Success.new(item.key, Time.instant - started)
    rescue error : Error
      failure(item, error)
    end

    private def find(step : Step, item : StepItem) : FileWriteItem?
      step.as(FileWriteStep).files.find { |file| file.item_key == item.key }
    end
  end
end
