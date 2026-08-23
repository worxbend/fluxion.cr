require "../spec_helper"

# `ToolBroker#install` is what puts a delegated tool (`dotbot`, the Nerd Fonts
# installer, `binstaller`) on a machine that has none, and nothing exercised it.
# That is how it kept publishing the executable with a `File.rename` out of the
# scratch workspace under `TMPDIR` into the cache under `$XDG_CACHE_HOME`: two
# different filesystems on any host with a tmpfs `/tmp`, where `rename` fails
# with EXDEV and the resulting `File::Error` — not a `Fluxion::Error` — escaped
# every per-item rescue and killed the whole run.

# A scratch directory that always goes away, matching spec/executor/archive_spec.cr.
private def with_directory(& : String ->) : Nil
  directory = File.tempname("fluxion-tool-broker-spec")
  Dir.mkdir_p(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory) rescue nil
  end
end

# Environment juggling, spelled the same way spec/paths_spec.cr spells it.
private def with_env(values : Hash(String, String?), &)
  previous = values.keys.to_h { |key| {key, ENV[key]?} }
  values.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  begin
    yield
  ensure
    previous.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  end
end

# The seam: the real broker with a canned transport in front of it, so the
# download, the digest check, the archive reader and the publish are all the
# production ones.
private class FakeToolBroker < Fluxion::Executor::ToolBroker
  def initialize(@transport : Fluxion::Executor::FakeHttpTransport)
    super(Fluxion::Executor::FakeShellRunner.new)
  end

  protected def http_transport : Fluxion::Executor::HttpTransport
    @transport
  end
end

private ARCHITECTURE = Fluxion::Host.architecture || Fluxion::Architecture::Amd64

private TOOL_BODY = "#!/bin/sh\necho dotbot\n"

# Builds a real release tarball holding one executable, and returns it together
# with the SHA-256 a catalog entry would pin it to.
private def build_archive(directory : String, executable : String) : {String, String}
  content = File.join(directory, "content")
  Dir.mkdir_p(content)
  File.write(File.join(content, executable), TOOL_BODY)

  archive = File.join(directory, "tool.tar.gz")
  status = Process.run("tar", ["-czf", archive, "-C", content, executable])
  raise "tar failed" unless status.success?

  {archive, Digest::SHA256.hexdigest(File.read(archive))}
end

private def tool_spec(digest : String) : Fluxion::Executor::KnownTools::Spec
  template = Fluxion::Executor::KnownTools::Spec.new(
    name: "dotbot",
    repository: "worxbend/dotbot-go",
    version: "v9.9.9",
    asset_template: "dotbot-${version}-${os}-${arch}.tar.gz",
    executable: "dotbot",
    digests: {} of String => String,
  )
  template.copy_with(digests: {template.asset(ARCHITECTURE) => digest})
end

# A directory on a filesystem other than the one holding the scratch workspace.
# The bug is a rename across a device boundary, so the spec has to arrange one;
# it probes with an actual rename instead of assuming which mounts are tmpfs,
# and answers `nil` when the host has no such pair — there the same test still
# covers the ordinary install.
private def directory_on_another_filesystem : String?
  # `FLUXION_SPEC_OTHER_FS` lets a host name the directory outright; otherwise
  # the home directory is tried, since a tmpfs `/tmp` beside a disk-backed home
  # is the systemd default this bug was found on.
  candidates = [ENV["FLUXION_SPEC_OTHER_FS"]?, Fluxion::Host.home].compact

  candidates.each do |candidate|
    next unless File.directory?(candidate)

    probe = File.tempname("fluxion-cross-device-probe")
    File.write(probe, "probe")
    moved = File.join(candidate, ".fluxion-cross-device-probe-#{Random::Secure.hex(6)}")
    begin
      File.rename(probe, moved)
      File.delete(moved) rescue nil
    rescue error : File::Error
      File.delete(probe) rescue nil
      # Only EXDEV is the boundary being looked for. Anything else — most often
      # a home directory this account cannot write, as on some CI images — says
      # nothing about filesystems, and returning it would hand `with_cache_home`
      # a directory it cannot create anything in.
      return candidate if error.os_error == Errno::EXDEV
    end
  end
  nil
end

private def with_cache_home(& : String ->) : Nil
  parent = directory_on_another_filesystem || Dir.tempdir
  cache_home = File.join(parent, ".fluxion-tool-broker-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(cache_home)
  begin
    with_env({"XDG_CACHE_HOME" => cache_home}) { yield cache_home }
  ensure
    FileUtils.rm_rf(cache_home) rescue nil
  end
end

describe Fluxion::Executor::ToolBroker do
  describe "#install" do
    it "publishes the tool into the cache even when the workspace is on another filesystem" do
      with_directory do |directory|
        archive, digest = build_archive(directory, "dotbot")
        spec = tool_spec(digest)

        with_cache_home do |cache_home|
          transport = Fluxion::Executor::FakeHttpTransport.new
            .on(spec.url(ARCHITECTURE), File.read(archive))

          path = FakeToolBroker.new(transport).install(spec)

          path.should start_with(cache_home)
          File.read(path).should eq(TOOL_BODY)
          (File.info(path).permissions.value & 0o777).should eq(0o700)
        end
      end
    end

    it "reports a failed publish as a Fluxion error instead of a bare filesystem one" do
      with_directory do |directory|
        archive, digest = build_archive(directory, "dotbot")
        spec = tool_spec(digest)

        with_cache_home do |cache_home|
          transport = Fluxion::Executor::FakeHttpTransport.new
            .on(spec.url(ARCHITECTURE), File.read(archive))
          broker = FakeToolBroker.new(transport)

          # Something already sits where the tool belongs, and it is not a file
          # a rename can replace. Any filesystem refusal has to arrive as a
          # `Fluxion::Error`: that is the only kind the executors and the
          # orchestrator turn into one failed step rather than letting it
          # unwind and abort the run.
          destination = File.join(cache_home, "fluxion", "tools",
            spec.name, spec.version, spec.executable)
          Dir.mkdir_p(destination)
          File.write(File.join(destination, "occupant"), "in the way\n")

          error = expect_raises(Fluxion::ExecutionError) { broker.install(spec) }
          error.message.not_nil!.should contain("Failed to install dotbot")

          # And nothing half-installed is left behind next to the destination.
          leftovers = Dir.children(File.dirname(destination))
          leftovers.should eq([spec.executable])
        end
      end
    end
  end
end
