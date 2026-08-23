require "../spec_helper"

# `status`, `diff` and `explain` are three views of one computation, so these
# specs drive the commands end to end with an injected runner and store — the
# same approach as `spec/cli/deps_spec.cr` — rather than assembling a report by
# hand and testing something the user never sees.
private record Invocation, exit_code : Fluxion::CLI::ExitCode, stdout : String, stderr : String do
  def json : JSON::Any
    JSON.parse(stdout)
  end
end

private def invoke(arguments : Array(String), deps : Fluxion::CLI::Deps) : Invocation
  output = IO::Memory.new
  errors = IO::Memory.new
  code = Fluxion::CLI::Style.with_color(false) do
    Fluxion::CLI::App.new(Fluxion::CLI::GlobalOptions.new, output, errors, deps).run(arguments)
  end
  Invocation.new(code, output.to_s, errors.to_s)
end

private def with_state(& : Fluxion::State::Store -> T) : T forall T
  directory = File.tempname("fluxion-status-state")
  begin
    yield Fluxion::State::Store.new(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

# A profile whose Flatpak remote is declared under `spec.sources`, which is
# where every shipped example declares one. Source setups are not part of any
# phase, so a report built from the phases alone cannot see this remote.
private SOURCED_PROFILE = <<-YAML
  apiVersion: initkit.io/v1alpha1
  kind: WorkstationProfile
  metadata:
    name: sourced
  spec:
    target:
      os:
        distribution: fedora
    sources:
      flatpak:
        - name: flathub
          kind: flatpak-remote
          spec:
            remote: flathub
            url: https://flathub.org/repo/flathub.flatpakrepo
            system: true
            checksum:
              algorithm: sha256
              value: 3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a
    phases:
      - name: desktop
        steps:
          - name: apps
            kind: flatpak-packages
            spec:
              apps: [com.spotify.Client]
  YAML

# A runner on which flatpak exists and reports flathub as a configured remote,
# so the remote probes as installed and the application probes as missing.
private def flatpak_runner : Fluxion::Executor::FakeShellRunner
  Fluxion::Executor::FakeShellRunner.new
    .available("flatpak")
    .on("flatpak remotes", 0, "flathub\n")
end

# Records the remote as a previous run would have, which is what turned it into
# a phantom "no longer declared" entry while the report ignored `spec.sources`.
private def record_flathub(store : Fluxion::State::Store) : Nil
  document = store.load("default")
  document.record(Fluxion::State::ItemRecord.new(
    profile: "default", step: "flathub", item_key: "flathub",
    item_type: "flatpak_remote", completed_at: Time.utc))
  store.save(document)
end

describe Fluxion::CLI::StatusCommand do
  it "reports a source setup the profile still declares" do
    with_state do |store|
      record_flathub(store)
      deps = Fluxion::CLI::Deps.new(runner: flatpak_runner, store: store)

      ProfileHelpers.with_profile(SOURCED_PROFILE) do |path|
        items = invoke(["status", "--format", "json", "-c", path], deps).json["items"].as_a

        remote = items.find { |item| item["key"].as_s == "flathub" }.should_not be_nil
        remote["type"].as_s.should eq("flatpak_remote")
        remote["status"].as_s.should eq("installed")
        # The state record belongs to a remote `spec.sources` still declares,
        # so inviting the user to forget it would be wrong.
        items.map(&.["status"].as_s).should_not contain("state-only")
      end
    end
  end

  it "counts a source setup among the items it reports" do
    with_state do |store|
      deps = Fluxion::CLI::Deps.new(runner: flatpak_runner, store: store)

      ProfileHelpers.with_profile(SOURCED_PROFILE) do |path|
        summary = invoke(["status", "--format", "json", "-c", path], deps).json["summary"]

        # One remote plus the one application the phase declares.
        summary["total"].as_i.should eq(2)
        summary["installed"].as_i.should eq(1)
      end
    end
  end

  it "reports a state file another account can write instead of ignoring it" do
    with_state do |store|
      record_flathub(store)
      # A state file a second account can write could make Fluxion skip work
      # that was never done, which is why the store refuses to read one.
      File.chmod(store.path("default"), 0o666)
      deps = Fluxion::CLI::Deps.new(runner: flatpak_runner, store: store)

      ProfileHelpers.with_profile(SOURCED_PROFILE) do |path|
        result = invoke(["status", "-c", path], deps)

        result.exit_code.should eq(Fluxion::CLI::ExitCode::ExternalDependencyError)
        result.stderr.should contain("writable by another account")
      end
    end
  end

  it "omits the listing from --summary JSON rather than emitting an empty one" do
    with_state do |store|
      deps = Fluxion::CLI::Deps.new(runner: flatpak_runner, store: store)

      ProfileHelpers.with_profile(SOURCED_PROFILE) do |path|
        json = invoke(["status", "--summary", "--format", "json", "-c", path], deps).json

        json["summary"]["total"].as_i.should eq(2)
        # An empty `items` beside a summary counting two of them is a document
        # that contradicts itself.
        json.as_h.has_key?("items").should be_false
      end
    end
  end
end

describe Fluxion::CLI::DiffCommand do
  it "shows a source setup the host is missing" do
    with_state do |store|
      # No remote configured on this host, so the source setup is work `apply`
      # would do — and `diff` exists to say so before it happens.
      runner = Fluxion::Executor::FakeShellRunner.new.available("flatpak")
      deps = Fluxion::CLI::Deps.new(runner: runner, store: store)

      ProfileHelpers.with_profile(SOURCED_PROFILE) do |path|
        result = invoke(["diff", "-c", path], deps)

        result.exit_code.should eq(Fluxion::CLI::ExitCode::Success)
        result.stdout.should contain("flathub")
      end
    end
  end
end
