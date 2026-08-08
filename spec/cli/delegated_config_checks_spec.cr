require "../spec_helper"

# Fluxion refused a binary download with no digest at parse time. That refusal
# moved into binstaller's own `spec.policy.mode: strict`, so `lint` says when a
# referenced profile is not asking for it, and `doctor` says when the file is
# not there at all.
private def with_pair(binstaller : String, & : String -> T) : T forall T
  directory = File.tempname("fluxion-delegated-checks")
  Dir.mkdir_p(directory)
  File.write(File.join(directory, "binstaller.yaml"), binstaller)
  File.write(File.join(directory, "profile.yaml"), <<-YAML)
    apiVersion: initkit.io/v1alpha1
    kind: WorkstationProfile
    metadata:
      name: delegated
    spec:
      target:
        os:
          distribution: fedora
      phases:
        - name: base
          steps:
            - name: portable
              kind: binstaller-profile
              spec:
                config: ./binstaller.yaml
    YAML
  begin
    yield File.join(directory, "profile.yaml")
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def lint(path : String) : String
  output = IO::Memory.new
  Fluxion::CLI::Style.with_color(false) do
    Fluxion::CLI::App.new(Fluxion::CLI::GlobalOptions.new, output, IO::Memory.new)
      .run(["lint", "-c", path])
  end
  output.to_s
end

private STRICT_PINNED = <<-YAML
  apiVersion: binstaller.io/v1alpha1
  kind: BinaryDistributionProfile
  spec:
    policy:
      mode: strict
    plan:
      - name: kubectl
        kind: binary-tool
        spec:
          download:
            url: https://example.test/kubectl
            checksum:
              algorithm: sha256
              value: aa
  YAML

describe "delegated config checks" do
  describe "lint" do
    it "says nothing about a strict, fully pinned profile" do
      with_pair(STRICT_PINNED) do |path|
        lint(path).should_not contain("binstaller-")
      end
    end

    it "warns when the referenced profile is not strict" do
      with_pair(STRICT_PINNED.sub("mode: strict", "mode: warn")) do |path|
        report = lint(path)
        report.should contain("binstaller-not-strict")
        report.should contain("only flagged rather than refused")
      end
    end

    it "names the entries that declare no checksum" do
      loose = <<-YAML
        apiVersion: binstaller.io/v1alpha1
        kind: BinaryDistributionProfile
        spec:
          policy:
            mode: strict
          plan:
            - name: lazygit
              kind: binary-tool
              spec:
                download:
                  url: https://example.test/lazygit.tar.gz
        YAML

      with_pair(loose) do |path|
        report = lint(path)
        report.should contain("binstaller-unpinned")
        report.should contain("1 entry declares")
        report.should contain("lazygit")
      end
    end

    it "stays quiet about a file it cannot read or does not recognise" do
      # The file belongs to another tool, may not exist when lint runs, and its
      # schema is not Fluxion's to validate — advisory or silent, never fatal.
      with_pair("not: a binstaller profile\n") do |path|
        lint(path).should_not contain("binstaller-")
      end
    end

    it "never fails the command over a delegated config" do
      with_pair("{{{ not yaml at all") do |path|
        output = IO::Memory.new
        code = Fluxion::CLI::Style.with_color(false) do
          Fluxion::CLI::App.new(Fluxion::CLI::GlobalOptions.new, output, IO::Memory.new)
            .run(["lint", "-c", path])
        end
        code.should eq(Fluxion::CLI::ExitCode::Success)
      end
    end
  end
end
