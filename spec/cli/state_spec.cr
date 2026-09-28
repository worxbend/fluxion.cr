require "../spec_helper"

# `fluxion state` driven end to end with an injected store, the same way
# `spec/cli/status_spec.cr` drives `status`.
private record StateInvocation, exit_code : Fluxion::CLI::ExitCode, stdout : String, stderr : String

private def invoke_state(arguments : Array(String), store : Fluxion::State::Store) : StateInvocation
  output = IO::Memory.new
  errors = IO::Memory.new
  deps = Fluxion::CLI::Deps.new(runner: Fluxion::Executor::FakeShellRunner.new, store: store)
  code = Fluxion::CLI::Style.with_color(false) do
    Fluxion::CLI::App.new(Fluxion::CLI::GlobalOptions.new, output, errors, deps).run(arguments)
  end
  StateInvocation.new(code, output.to_s, errors.to_s)
end

private def with_state_store(& : Fluxion::State::Store -> T) : T forall T
  directory = File.tempname("fluxion-state-command")
  begin
    yield Fluxion::State::Store.new(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def record_item(store : Fluxion::State::Store, profile : String, key : String) : Nil
  document = store.load(profile)
  document.record(Fluxion::State::ItemRecord.new(
    profile: profile, step: "apps", item_key: key, item_type: "shell_command", completed_at: Time.utc))
  store.save(document)
end

private def recorded_keys(store : Fluxion::State::Store, profile : String) : Array(String)
  store.load(profile).items.map(&.item_key)
end

describe Fluxion::CLI::StateForgetCommand do
  # `show`, `path` and `reset` all take the profile as a positional argument.
  # `forget` read only `--profile`, so the same spelling silently acted on the
  # profile "default", reported that it had no state, and exited 0 — leaving
  # the item the user asked about exactly where it was.
  it "takes the profile as a positional argument, like the other state subcommands" do
    with_state_store do |store|
      record_item(store, "test-apps", "stale-step")
      record_item(store, "test-apps", "kept-step")

      run = invoke_state(%w[state forget test-apps --item stale-step], store)

      run.exit_code.should eq(Fluxion::CLI::ExitCode::Success)
      recorded_keys(store, "test-apps").should eq(["kept-step"])
    end
  end

  it "still accepts --profile" do
    with_state_store do |store|
      record_item(store, "test-apps", "stale-step")

      invoke_state(%w[state forget --profile=test-apps --item stale-step], store)
        .exit_code.should eq(Fluxion::CLI::ExitCode::Success)
      recorded_keys(store, "test-apps").should be_empty
    end
  end

  it "refuses two different profiles rather than picking one" do
    with_state_store do |store|
      record_item(store, "test-apps", "stale-step")

      run = invoke_state(%w[state forget test-apps --profile=other --item stale-step], store)

      run.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
      run.stderr.should contain("test-apps")
      run.stderr.should contain("other")
      recorded_keys(store, "test-apps").should eq(["stale-step"])
    end
  end

  it "refuses an argument it has no use for" do
    with_state_store do |store|
      record_item(store, "test-apps", "stale-step")

      run = invoke_state(%w[state forget test-apps stale-step --item stale-step], store)

      run.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
      run.stderr.should contain("stale-step")
      recorded_keys(store, "test-apps").should eq(["stale-step"])
    end
  end
end
