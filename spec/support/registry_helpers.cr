require "file_utils"

# Builds a throwaway registry — a mirror, an install directory, and the XDG
# variables pointing at both — so registry specs exercise the real paths
# without touching the machine running them.
module RegistryHelpers
  extend self

  record Sandbox,
    root : String,
    repository : String,
    source : Fluxion::Registry::Source do
    def store : Fluxion::Registry::Store
      Fluxion::Registry::Store.new(source)
    end

    def mirror_file(relative : String) : String
      File.join(source.mirror_path, relative)
    end

    def installed_file(id : String) : String
      File.join(source.install_path, "#{id}.yaml")
    end

    # Writes into the mirror, standing in for what a `sync` would have fetched.
    def publish_upstream(relative : String, body : String) : Nil
      path = mirror_file(relative)
      Dir.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
  end

  MANIFEST = <<-YAML
    apiVersion: fluxion.dev/registry/v1
    kind: Registry

    metadata:
      name: demo-profiles
      description: Demo bootstrap configurations

    entries:
      - id: base
        name: Base tools
        description: The handful of things every machine needs
        path: profiles/base.yaml
        distributions: [arch]
        tags: [core]

      - id: workstation
        name: Developer workstation
        path: profiles/workstation.yaml
        distributions: [arch, fedora]
        tags: [developer]
        requires: [base]
    YAML

  def profile(name : String, package : String = "git") : String
    <<-YAML
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile

      metadata:
        name: #{name}

      spec:
        target:
          os:
            distribution: arch
        phases:
          - name: #{name}-phase
            steps:
              - name: #{name}-packages
                kind: pacman-packages
                spec:
                  packages: [#{package}]
      YAML
  end

  # A document Fluxion recognises as a profile but refuses: it carries the
  # header, so the failure is validation rather than "this is not a profile
  # at all", which is what the install and stage guards are about.
  def invalid_profile : String
    <<-YAML
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile

      metadata:
        name: broken

      spec:
        target:
          os:
            distribution: arch
        phases: []
      YAML
  end

  # Runs `block` with XDG pointed at a temporary tree, restoring the
  # environment afterwards so one spec cannot leak into the next.
  def with_sandbox(name : String = "demo", & : Sandbox -> T) : T forall T
    root = File.tempname("fluxion-registry-spec")
    previous_config = ENV["XDG_CONFIG_HOME"]?
    previous_cache = ENV["XDG_CACHE_HOME"]?

    ENV["XDG_CONFIG_HOME"] = File.join(root, "config")
    ENV["XDG_CACHE_HOME"] = File.join(root, "cache")

    # `registry publish` commits through the user's own git, which refuses to
    # commit without an identity. A CI container has none configured, so the
    # spec supplies one instead of depending on whatever the host happens to
    # have set.
    identity = {
      "GIT_AUTHOR_NAME"     => "fluxion-spec",
      "GIT_AUTHOR_EMAIL"    => "spec@fluxion.test",
      "GIT_COMMITTER_NAME"  => "fluxion-spec",
      "GIT_COMMITTER_EMAIL" => "spec@fluxion.test",
    }
    previous_identity = identity.keys.to_h { |key| {key, ENV[key]?} }
    identity.each { |key, value| ENV[key] = value }

    begin
      repository = File.join(root, "repository")
      source = Fluxion::Registry::Source.new(name, "file://#{repository}", default: true)
      sandbox = Sandbox.new(root, repository, source)

      Dir.mkdir_p(File.join(source.mirror_path, "profiles"))
      sandbox.publish_upstream(Fluxion::Registry::Manifest::FILE_NAME, MANIFEST)
      sandbox.publish_upstream("profiles/base.yaml", profile("base"))
      sandbox.publish_upstream("profiles/workstation.yaml", profile("workstation", "neovim"))

      yield sandbox
    ensure
      previous_config ? (ENV["XDG_CONFIG_HOME"] = previous_config) : ENV.delete("XDG_CONFIG_HOME")
      previous_cache ? (ENV["XDG_CACHE_HOME"] = previous_cache) : ENV.delete("XDG_CACHE_HOME")
      previous_identity.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
      FileUtils.rm_rf(root)
    end
  end

  # A real git repository, for the commands that clone and push.
  def with_git_registry(& : Sandbox -> T) : T forall T
    with_sandbox do |sandbox|
      Dir.mkdir_p(File.join(sandbox.repository, "profiles"))
      File.write(File.join(sandbox.repository, Fluxion::Registry::Manifest::FILE_NAME), MANIFEST)
      File.write(File.join(sandbox.repository, "profiles", "base.yaml"), profile("base"))
      File.write(File.join(sandbox.repository, "profiles", "workstation.yaml"), profile("workstation", "neovim"))

      git(sandbox.repository, "init", "-q", "-b", "main", ".")
      # A checked-out branch refuses a push by default, and the spec pushes to
      # this repository rather than to a bare one.
      git(sandbox.repository, "config", "receive.denyCurrentBranch", "updateInstead")
      git(sandbox.repository, "add", "-A")
      git(sandbox.repository, "commit", "-qm", "initial")

      # The mirror is re-created by `sync`; anything staged by `with_sandbox`
      # would otherwise sit in the way of the clone.
      FileUtils.rm_rf(sandbox.source.mirror_path)

      yield sandbox
    end
  end

  def git(directory : String, *arguments : String) : Nil
    status = Process.run("git",
      ["-C", directory,
       "-c", "user.email=spec@fluxion.test",
       "-c", "user.name=fluxion-spec",
       "-c", "commit.gpgsign=false"] + arguments.to_a,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close)
    raise "git #{arguments.join(' ')} failed" unless status.success?
  end

  def git?(directory : String, *arguments : String) : String
    output = IO::Memory.new
    Process.run("git", ["-C", directory] + arguments.to_a,
      output: output, error: Process::Redirect::Close)
    output.to_s
  end

  def git_available? : Bool
    Process.find_executable("git") != nil
  end
end
