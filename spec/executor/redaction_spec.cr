require "../spec_helper"

private alias Redaction = Fluxion::Executor::Redaction

private def secret(name : String, value : String)
  [Fluxion::ShellEnvironmentVariable.new(name, value, true)]
end

describe Fluxion::Executor::Redaction do
  describe "#redact" do
    it "removes credentials from a URL" do
      Redaction.redact("cloning https://alice:hunter2@example.test/repo.git")
        .should eq("cloning https://<redacted>@example.test/repo.git")
    end

    it "uses the last @ in the authority, since a password may contain one" do
      Redaction.redact("https://user:p@ss@example.test/x")
        .should_not contain("p@ss")
    end

    it "masks an Authorization bearer header" do
      Redaction.redact(%(Authorization: Bearer abc.def.ghi))
        .should_not contain("abc.def.ghi")
    end

    it "masks a bare bearer token anywhere in the line" do
      Redaction.redact("curl -H 'bearer sk_live_abcdef123456'")
        .should contain("Bearer <redacted>")
    end

    it "masks assignment forms regardless of quoting or separator" do
      [
        %(GITHUB_TOKEN=ghp_secret),
        %("api_key": "ghp_secret"),
        %(password = ghp_secret),
        %(PASSWD:ghp_secret),
      ].each do |input|
        Redaction.redact(input).should_not contain("ghp_secret")
      end
    end

    it "masks a sensitive flag's value" do
      Redaction.redact("tool --access-key ghp_secret --verbose")
        .should_not contain("ghp_secret")
      Redaction.redact("tool --token=ghp_secret").should_not contain("ghp_secret")
    end

    it "leaves ordinary text alone" do
      # A word that merely contains a sensitive substring is not an assignment.
      Redaction.redact("MONKEY=banana passwordless=true")
        .should eq("MONKEY=banana passwordless=true")
    end

    it "masks an entire PEM private key block" do
      pem = <<-PEM
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----
        PEM

      redacted = Redaction.redact(pem)
      redacted.should eq("<redacted>")
    end
  end

  describe "#strip_controls" do
    it "removes CSI colour and cursor sequences" do
      Redaction.strip_controls("\e[31mred\e[0m").should eq("red")
      Redaction.strip_controls("\e[2J\e[Hcleared").should eq("cleared")
    end

    it "removes OSC sequences including their terminator" do
      Redaction.strip_controls("\e]0;forged title\aactual").should eq("actual")
    end

    it "applies backspace instead of emitting it" do
      # Without this, output could overprint an earlier line to forge one of
      # Fluxion's own status messages.
      Redaction.strip_controls("abc\b\bX").should eq("aX")
    end

    it "drops bidirectional overrides" do
      Redaction.strip_controls("rm -rf \u202E/tmp").should eq("rm -rf /tmp")
    end

    it "collapses a newline into the line by default" do
      Redaction.strip_controls("first\nforged").should_not contain('\n')
    end

    it "keeps newlines when asked" do
      Redaction.strip_controls("first\nsecond", preserve_newlines: true).should eq("first\nsecond")
    end

    it "turns other control characters into spaces" do
      Redaction.strip_controls("a\u0000b").should eq("a b")
    end
  end

  describe "#sanitize_command" do
    it "masks the argument after a sensitive flag" do
      Redaction.sanitize_command(["tool", "--password", "hunter2", "--verbose"])
        .should eq(["tool", "--password", "<redacted>", "--verbose"])
    end

    it "does not mask the argument after an inline assignment" do
      # `--token=x` already carries its value, so the next argument is unrelated.
      Redaction.sanitize_command(["tool", "--token=x", "install"])
        .last.should eq("install")
    end

    it "masks curl's attached -u form" do
      Redaction.sanitize_command(["curl", "-uadmin:hunter2", "https://example.test"])
        .should eq(["curl", "-u<redacted>", "https://example.test"])
    end

    it "masks curl's detached -u form" do
      Redaction.sanitize_command(["curl", "-u", "admin:hunter2"])
        .should eq(["curl", "-u", "<redacted>"])
    end

    it "strips escape sequences from every argument" do
      Redaction.sanitize_command(["echo", "\e[31mred"]).should eq(["echo", "red"])
    end
  end

  describe "#mask_values" do
    it "masks a known secret that no pattern would catch" do
      Redaction.mask_values("installed banana successfully", secret("TOKEN", "banana"))
        .should eq("installed <redacted> successfully")
    end

    it "ignores a variable that is not marked sensitive" do
      plain = [Fluxion::ShellEnvironmentVariable.new("EDITOR", "vim", false)]
      Redaction.mask_values("using vim", plain).should eq("using vim")
    end

    it "masks the whole line for a secret too short to replace safely" do
      # Replacing a two-character secret would both match everywhere and reveal
      # its length, so the line goes entirely.
      Redaction.mask_values("value is ab", secret("PIN", "ab")).should eq("<redacted>")
    end
  end

  describe "#sensitive_name?" do
    it "recognises the usual spellings" do
      %w[TOKEN api_key API-KEY githubToken PASSWORD passwd my_secret credentials].each do |name|
        Redaction.sensitive_name?(name).should be_true
      end
    end

    it "does not fire on unrelated names" do
      %w[EDITOR PATH HOME monkey tokenizer].each do |name|
        Redaction.sensitive_name?(name).should be_false
      end
    end
  end

  describe Fluxion::Executor::Redaction::StreamingSanitizer do
    it "masks a private key spanning several output lines" do
      sanitizer = Fluxion::Executor::Redaction::StreamingSanitizer.new
      lines = [
        "writing key:",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAA",
        "AAAAB3NzaC1yc2EAAAADAQAB",
        "-----END OPENSSH PRIVATE KEY-----",
        "done",
      ]

      output = lines.map { |line| sanitizer.line(line) }
      output.first.should eq("writing key:")
      output[1..4].each(&.should(eq("<redacted>")))
      output.last.should eq("done")
      output.join.should_not contain("b3BlbnNz")
    end

    it "recognises a marker split across two reads" do
      sanitizer = Fluxion::Executor::Redaction::StreamingSanitizer.new
      first = sanitizer.line("noise -----BE")
      second = sanitizer.line("GIN RSA PRIVATE KEY-----")

      (first + second).should_not contain("BEGIN RSA PRIVATE KEY")
      sanitizer.line("payload").should eq("<redacted>")
    end

    it "returns carried text when the stream ends mid-marker" do
      sanitizer = Fluxion::Executor::Redaction::StreamingSanitizer.new
      # The partial marker is held back; everything before it is emitted.
      sanitizer.line("tail -----BE").should eq("tail ")
      sanitizer.finish.should eq("-----BE")
    end

    it "masks known secrets in ordinary lines too" do
      sanitizer = Fluxion::Executor::Redaction::StreamingSanitizer.new(secret("TOKEN", "banana"))
      sanitizer.line("fetched with banana").should eq("fetched with <redacted>")
    end
  end
end
