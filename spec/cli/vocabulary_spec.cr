require "../spec_helper"

# One vocabulary for an item's type, across every command that prints one.
#
# `plan --format json` used to emit `ItemRef#type` — a free string each Step
# writes by hand — while `status`/`diff`/`explain` emitted `ItemType#json_name`.
# They disagreed for six kinds, so the two outputs could not be joined on
# `type`, and `state forget --type` rejected the value `plan` had just printed.
private def step_for(kind : String) : Fluxion::Step
  case kind
  when "compiled-binary"
    Fluxion::CompiledBinaryStep.new(
      name: "rg", binary_name: "rg", url: "https://example.test/rg",
      trust: Fluxion::TrustAnchor::Digest.new(
        Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, "0" * 64)),
      install_path: "/usr/local/bin/rg", format: Fluxion::ArtifactFormat::PlainBinary)
  when "shell-command"
    Fluxion::ShellCommandStep.new("cmds", [Fluxion::ShellCommandItem.shell("true")])
  when "shell-script"
    Fluxion::ShellScriptStep.new("scripts",
      [Fluxion::ShellScriptItem.new(name: "setup", script: "/tmp/setup.sh")])
  when "dotbot"
    Fluxion::DotbotStep.new("dots", "/tmp/install.conf.yaml")
  else
    raise "unknown kind #{kind}"
  end
end

describe "item type vocabulary" do
  # The six kinds whose hand-written `ItemRef#type` differs from the enum.
  {
    "compiled-binary" => "compiled_binary",
    "shell-command"   => "shell_command",
    "shell-script"    => "shell_script",
    "dotbot"          => "dotbot",
  }.each do |kind, expected|
    it "reports #{kind} as #{expected} everywhere" do
      step = step_for(kind)

      # What `status`, `diff` and `explain` print.
      Fluxion::Executor::ItemTypes.for(step).json_name.should eq(expected)

      # And what `state forget --type` will accept, which is the round trip
      # that used to fail.
      Fluxion::ItemType.from_config?(expected).should_not be_nil
    end
  end

  it "accepts every ItemType spelling back through state forget" do
    # Whatever any command prints must be parseable by the flag that consumes
    # it, for every kind rather than the four sampled above.
    Fluxion::ItemType.values.each do |type|
      Fluxion::ItemType.from_config?(type.json_name).should eq(type)
    end
  end
end

describe "restart effect vocabulary" do
  it "spells every policy the same way in JSON" do
    # `plan --format json` said `prompt_logout` while `status`/`explain` said
    # `prompt-logout`, so a script branching on `restartEffect` matched one
    # command and silently never matched the other.
    policies = [
      Fluxion::RestartPolicy::None.new,
      Fluxion::RestartPolicy::PromptLogout.new,
      Fluxion::RestartPolicy::RequiresNewShell.new,
    ] of Fluxion::RestartPolicy

    policies.map(&.json_name).should eq(%w[none prompt_logout requires_new_shell])
  end

  it "leaves to_s alone, because the phase fingerprint hashes it" do
    # Changing this would make every completed phase look edited and re-run.
    Fluxion::RestartPolicy::PromptLogout.new.to_s.should eq("prompt-logout")
  end
end
