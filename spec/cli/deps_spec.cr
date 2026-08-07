require "../spec_helper"

# What the composition root buys: commands that reach the outside world can now
# be driven end to end with fakes.
#
# Before `Deps`, every one of these called `SystemShellRunner.new` or
# `State::Store.new` inline, so `spec/cli/commands_spec.cr` could only cover the
# five commands that never touch a runner — `apply`, `status`, `doctor`,
# `tools` and `generate` had no spec file at all.
private def with_profile(body : String, & : String -> T) : T forall T
  directory = File.tempname("fluxion-deps")
  Dir.mkdir_p(directory)
  path = File.join(directory, "profile.yaml")
  File.write(path, body)
  begin
    yield path
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def with_state(& : Fluxion::State::Store -> T) : T forall T
  directory = File.tempname("fluxion-deps-state")
  begin
    yield Fluxion::State::Store.new(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

private record Invocation, exit_code : Fluxion::CLI::ExitCode, stdout : String, stderr : String

private def invoke(arguments : Array(String), deps : Fluxion::CLI::Deps) : Invocation
  output = IO::Memory.new
  errors = IO::Memory.new
  code = Fluxion::CLI::Style.with_color(false) do
    Fluxion::CLI::App.new(Fluxion::CLI::GlobalOptions.new, output, errors, deps).run(arguments)
  end
  Invocation.new(code, output.to_s, errors.to_s)
end

private ONE_COMMAND = <<-YAML
  apiVersion: initkit.io/v1alpha1
  kind: WorkstationProfile
  metadata:
    name: deps-spec
  spec:
    target:
      os:
        distribution: fedora
    phases:
      - name: base
        steps:
          - name: tools
            kind: commands
            spec:
              commands: ["true"]
  YAML

describe Fluxion::CLI::Deps do
  it "hands every command the same runner" do
    runner = Fluxion::Executor::FakeShellRunner.new
    deps = Fluxion::CLI::Deps.new(runner: runner)

    deps.runner.should be(runner)
    deps.tool_broker.should be_a(Fluxion::Executor::ToolBroker)
    deps.git.should be_a(Fluxion::Registry::Git)
  end

  it "defaults to the real collaborators" do
    Fluxion::CLI::Deps.new.runner.should be_a(Fluxion::Executor::SystemShellRunner)
  end

  describe "apply, driven with a fake runner" do
    it "runs the profile's commands without spawning anything" do
      runner = Fluxion::Executor::FakeShellRunner.new

      with_state do |store|
        with_profile(ONE_COMMAND) do |path|
          result = invoke(["apply", "--no-tui", "-c", path],
            Fluxion::CLI::Deps.new(runner: runner, store: store))

          result.exit_code.should eq(Fluxion::CLI::ExitCode::Success)
          runner.ran?("true").should be_true
          result.stdout.should contain("1 ok")
        end
      end
    end

    it "reports a failing command and exits non-zero" do
      runner = Fluxion::Executor::FakeShellRunner.new.on("true", 1)

      with_state do |store|
        with_profile(ONE_COMMAND) do |path|
          result = invoke(["apply", "--no-tui", "-c", path],
            Fluxion::CLI::Deps.new(runner: runner, store: store))

          result.exit_code.should eq(Fluxion::CLI::ExitCode::ExternalDependencyError)
          result.stdout.should contain("1 failed")
        end
      end
    end

    it "records what it ran into the injected store" do
      runner = Fluxion::Executor::FakeShellRunner.new

      with_state do |store|
        with_profile(ONE_COMMAND) do |path|
          invoke(["apply", "--no-tui", "-c", path],
            Fluxion::CLI::Deps.new(runner: runner, store: store))

          store.load("default").items.map(&.item_key).should contain("true")
        end
      end
    end

    it "changes nothing on the host during a dry run" do
      runner = Fluxion::Executor::FakeShellRunner.new

      with_state do |store|
        with_profile(ONE_COMMAND) do |path|
          result = invoke(["dry-run", "--no-tui", "-c", path],
            Fluxion::CLI::Deps.new(runner: runner, store: store))

          result.exit_code.should eq(Fluxion::CLI::ExitCode::Success)
          runner.commands.should be_empty
          # A read-only run records nothing: state claiming work was done would
          # make the next real run skip it.
          store.exists?("default").should be_false
        end
      end
    end
  end

  describe "state, driven with an injected store" do
    it "reads the store it was given rather than the user's real one" do
      runner = Fluxion::Executor::FakeShellRunner.new

      with_state do |store|
        with_profile(ONE_COMMAND) do |path|
          deps = Fluxion::CLI::Deps.new(runner: runner, store: store)
          invoke(["apply", "--no-tui", "-c", path], deps)

          result = invoke(["state", "show"], deps)
          result.stdout.should contain("true")
        end
      end
    end
  end
end
