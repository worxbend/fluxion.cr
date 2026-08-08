require "../spec_helper"

private def parse_step(yaml : String)
  ProfileHelpers.parse(ProfileHelpers.manifest(yaml))
end

describe "shell-scripts schema" do
  describe "shell" do
    it "accepts the three shells at step level" do
      %w[bash sh zsh].each do |shell|
        result = parse_step(<<-STEP)
          - name: setup
            kind: shell-scripts
            spec:
              shell: #{shell}
              scripts:
                - name: one
                  content: "echo hi"
          STEP

        result.errors.should be_empty
        result.step("setup").as(Fluxion::ShellScriptStep).shell
          .should eq(Fluxion::ShellKind.from_config?(shell))
      end
    end

    it "rejects a shell it does not support" do
      result = parse_step(<<-STEP)
        - name: setup
          kind: shell-scripts
          spec:
            shell: fish
            scripts:
              - name: one
                content: "echo hi"
        STEP

      message = result.error_messages.find!(&.includes?("unsupported shell 'fish'"))
      message.should contain("bash")
    end

    it "rejects an absolute path and points at commands" do
      # `shell-scripts` hands a file to an interpreter; anything else is an
      # argv, which is what `commands` is for.
      result = parse_step(<<-STEP)
        - name: setup
          kind: shell-scripts
          spec:
            shell: /usr/bin/fish
            scripts:
              - name: one
                content: "echo hi"
        STEP

      message = result.error_messages.find!(&.includes?("bare shell name"))
      message.should contain("kind: commands")
    end
  end

  describe "content" do
    it "accepts an inline body with a declared shell" do
      result = parse_step(<<-STEP)
        - name: setup
          kind: shell-scripts
          spec:
            scripts:
              - name: linger
                shell: bash
                content: |
                  set -euo pipefail
                  echo hi
        STEP

      result.errors.should be_empty
      script = result.step("setup").as(Fluxion::ShellScriptStep).scripts.first
      script.inline?.should be_true
      script.content.to_s.should contain("set -euo pipefail")
    end

    it "requires a shell for an inline body" do
      # There is no shebang to read and no file to open.
      result = parse_step(<<-STEP)
        - name: setup
          kind: shell-scripts
          spec:
            scripts:
              - name: linger
                content: "echo hi"
        STEP

      message = result.error_messages.find!(&.includes?("required for an inline content script"))
      message.should contain("no shebang")
    end

    it "refuses more than one source" do
      result = parse_step(<<-STEP)
        - name: setup
          kind: shell-scripts
          spec:
            scripts:
              - name: both
                shell: bash
                content: "echo hi"
                url: https://example.org/install.sh
        STEP

      result.error_messages.any?(&.includes?("exactly one of script, url or content")).should be_true
    end

    it "refuses a digest on an inline body" do
      # The bytes are already in the profile, which is the trust root.
      result = parse_step(<<-STEP)
        - name: setup
          kind: shell-scripts
          spec:
            scripts:
              - name: linger
                shell: bash
                content: "echo hi"
                sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        STEP

      result.error_messages.any?(&.includes?("only valid for a remote URL")).should be_true
    end
  end

  describe "interpolation" do
    it "refuses a variable inside an inline body" do
      # The body goes straight to an interpreter, so substituting into it is
      # the injection point the rule exists to close.
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEP))
        - name: setup
          kind: shell-scripts
          spec:
            scripts:
              - name: linger
                shell: bash
                content: "echo ${HOME}"
        STEP

      result.error_messages.any?(&.includes?("cannot interpolate")).should be_true
    end

    it "still interpolates args, which cross as separate argv entries" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEP))
        - name: setup
          kind: shell-scripts
          spec:
            scripts:
              - name: linger
                shell: bash
                content: "echo hi"
                args: ["${HOME}"]
        STEP

      result.errors.should be_empty
      result.step("setup").as(Fluxion::ShellScriptStep).scripts.first.args.first
        .should_not contain("${")
    end
  end
end
