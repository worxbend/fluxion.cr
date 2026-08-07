require "../spec_helper"

# `Interpolator` rewrites every string in a profile before anything is mapped,
# and it owns a security rule — no substitution into a shell expression — that
# had no coverage at all.
private def interpolate(yaml : String, host : Fluxion::HostFacts = Fluxion::HostFacts.new)
  subject = Fluxion::Config::Interpolator.new(host)
  result = subject.interpolate(Fluxion::Config::Node.root(YAML.parse(yaml)))
  {result, subject.diagnostics}
end

# Environment variables are a real input to this class, so the specs that depend
# on one set it for their own duration rather than assuming the runner's.
private def with_env(name : String, value : String, &)
  previous = ENV[name]?
  ENV[name] = value
  begin
    yield
  ensure
    previous ? (ENV[name] = previous) : ENV.delete(name)
  end
end

describe Fluxion::Config::Interpolator do
  describe "what counts as a token" do
    it "substitutes a braced variable" do
      with_env("FLUXION_SPEC_TOKEN", "resolved") do
        result, diagnostics = interpolate("value: pre-${FLUXION_SPEC_TOKEN}-post")

        diagnostics.empty?.should be_true
        result["value"].as_s.should eq("pre-resolved-post")
      end
    end

    it "leaves shell syntax alone" do
      # `$(...)`, backticks and bare `$VAR` belong to whatever shell eventually
      # reads them, so interpreting them here would change their meaning.
      result, diagnostics = interpolate(<<-YAML)
        a: $(date)
        b: "`hostname`"
        c: $HOME
        d: "*.txt"
        YAML

      diagnostics.empty?.should be_true
      result["a"].as_s.should eq("$(date)")
      result["b"].as_s.should eq("`hostname`")
      result["c"].as_s.should eq("$HOME")
      result["d"].as_s.should eq("*.txt")
    end

    it "never interpolates a mapping key" do
      # A variable naming a schema field would make the document's shape depend
      # on the environment.
      with_env("FLUXION_SPEC_KEY", "surprise") do
        result, _ = interpolate("${FLUXION_SPEC_KEY}: value")

        result.as_h.keys.map(&.as_s).should eq(["${FLUXION_SPEC_KEY}"])
      end
    end

    it "reports an unresolved variable rather than leaving it silently" do
      result, diagnostics = interpolate("value: ${FLUXION_SPEC_DEFINITELY_UNSET}")

      diagnostics.empty?.should be_false
      result["value"].as_s.should eq("${FLUXION_SPEC_DEFINITELY_UNSET}")
    end

    it "reports an empty token" do
      _, diagnostics = interpolate("value: ${}")

      diagnostics.empty?.should be_false
    end
  end

  describe "spec.vars" do
    it "resolves vars against each other" do
      result, diagnostics = interpolate(<<-YAML)
        spec:
          vars:
            base: /opt
            full: ${base}/tools
          value: ${full}/bin
        YAML

      diagnostics.empty?.should be_true
      result["spec"]["value"].as_s.should eq("/opt/tools/bin")
    end

    it "reports a cyclic reference instead of looping" do
      _, diagnostics = interpolate(<<-YAML)
        spec:
          vars:
            a: ${b}
            b: ${a}
        YAML

      diagnostics.empty?.should be_false
    end

    it "lets the environment win over spec.vars" do
      # Later sources only fill gaps, so a profile cannot shadow the real
      # environment by accident.
      with_env("FLUXION_SPEC_PRECEDENCE", "from-env") do
        result, _ = interpolate(<<-YAML)
          spec:
            vars:
              FLUXION_SPEC_PRECEDENCE: from-profile
            value: ${FLUXION_SPEC_PRECEDENCE}
          YAML

        result["spec"]["value"].as_s.should eq("from-env")
      end
    end
  end

  describe "host facts" do
    it "exposes the detected host" do
      host = Fluxion::HostFacts.new(Fluxion::Distribution::Fedora, Fluxion::OsFamily::Fedora,
        "fedora", "41", nil, Fluxion::Architecture::Amd64)
      result, diagnostics = interpolate("value: ${host.os.name}-${host.os.arch}", host)

      diagnostics.empty?.should be_true
      result["value"].as_s.should eq("fedora-amd64")
    end
  end

  describe "shell expressions" do
    it "refuses to substitute into a command step's commands" do
      # The whole point: substituting into a field a shell will parse cannot be
      # made safe without reimplementing every shell grammar, so it is an error
      # rather than a silent injection point.
      with_env("FLUXION_SPEC_INJECT", "; rm -rf /") do
        result, diagnostics = interpolate(<<-YAML)
          spec:
            phases:
              - name: base
                steps:
                  - name: risky
                    kind: commands
                    spec:
                      commands:
                        - echo ${FLUXION_SPEC_INJECT}
          YAML

        diagnostics.empty?.should be_false
        command = result["spec"]["phases"][0]["steps"][0]["spec"]["commands"][0]
        command.as_s.should eq("echo ${FLUXION_SPEC_INJECT}")
      end
    end

    it "refuses to substitute into unless and probeCommand" do
      %w[unless probeCommand].each do |field|
        with_env("FLUXION_SPEC_INJECT", "x") do
          _, diagnostics = interpolate(<<-YAML)
            spec:
              phases:
                - name: base
                  steps:
                    - name: risky
                      kind: commands
                      #{field}: test -f ${FLUXION_SPEC_INJECT}
                      spec: {}
            YAML

          diagnostics.empty?.should be_false
        end
      end
    end

    it "refuses to substitute into an assert step's command" do
      with_env("FLUXION_SPEC_INJECT", "x") do
        _, diagnostics = interpolate(<<-YAML)
          spec:
            phases:
              - name: base
                steps:
                  - name: check
                    kind: assert
                    spec:
                      command: test -f ${FLUXION_SPEC_INJECT}
          YAML

        diagnostics.empty?.should be_false
      end
    end

    it "still substitutes into ordinary fields of the same step" do
      # The rule is scoped to shell-parsed fields, not to the whole step.
      with_env("FLUXION_SPEC_SAFE", "tools") do
        result, diagnostics = interpolate(<<-YAML)
          spec:
            phases:
              - name: base
                steps:
                  - name: pkgs
                    kind: dnf-packages
                    description: install ${FLUXION_SPEC_SAFE}
                    spec:
                      packages: [git]
          YAML

        diagnostics.empty?.should be_true
        result["spec"]["phases"][0]["steps"][0]["description"].as_s.should eq("install tools")
      end
    end
  end
end
