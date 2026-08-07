require "./spec_helper"

private def with_env(values : Hash(String, String?), &)
  previous = values.keys.to_h { |key| {key, ENV[key]?} }
  values.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  begin
    yield
  ensure
    previous.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  end
end

describe Fluxion::Paths do
  it "honours the XDG variables" do
    with_env({
      "XDG_CONFIG_HOME" => "/opt/cfg",
      "XDG_CACHE_HOME"  => "/opt/cache",
      "XDG_DATA_HOME"   => "/opt/data",
    }) do
      Fluxion::Paths.config_root.should eq("/opt/cfg/fluxion")
      Fluxion::Paths.cache_root.should eq("/opt/cache/fluxion")
      Fluxion::Paths.data_root.should eq("/opt/data/fluxion")
    end
  end

  it "falls back to the conventional directories under HOME" do
    with_env({
      "HOME"            => "/home/tester",
      "XDG_CONFIG_HOME" => nil,
      "XDG_CACHE_HOME"  => nil,
      "XDG_DATA_HOME"   => nil,
    }) do
      Fluxion::Paths.config_root.should eq("/home/tester/.config/fluxion")
      Fluxion::Paths.cache_root.should eq("/home/tester/.cache/fluxion")
      Fluxion::Paths.data_root.should eq("/home/tester/.local/share/fluxion")
    end
  end

  it "treats an empty XDG variable as unset" do
    # Per the specification: `XDG_CONFIG_HOME=` means "no preference", not "use
    # the filesystem root".
    with_env({"HOME" => "/home/tester", "XDG_CONFIG_HOME" => ""}) do
      Fluxion::Paths.config_root.should eq("/home/tester/.config/fluxion")
    end
  end

  it "puts the default profile under the same config root the registry uses" do
    # The bug this module exists to prevent: `Config::Loader.default_path`
    # ignored XDG_CONFIG_HOME while `registry install` honoured it, so with the
    # variable set the two wrote to different trees.
    with_env({"XDG_CONFIG_HOME" => "/opt/cfg"}) do
      Fluxion::Config::Loader.default_path.should eq("/opt/cfg/fluxion/default.yaml")
      Fluxion::Registry::Source.install_root.should eq("/opt/cfg/fluxion/registries")
      Fluxion::Registry::Source.settings_path.should eq("/opt/cfg/fluxion/registries.yaml")
    end
  end

  it "keeps the disposable roots out of the config root" do
    # The mirror is a clone that `sync` may blow away; installed profiles are
    # the user's. If these shared a root, "installed" would mean nothing.
    with_env({"XDG_CONFIG_HOME" => "/opt/cfg", "XDG_CACHE_HOME" => "/opt/cache"}) do
      Fluxion::Registry::Source.mirror_root.should eq("/opt/cache/fluxion/registries")
      Fluxion::Executor::ToolBroker.cache_root.should eq("/opt/cache/fluxion/tools")
    end
  end

  it "never resolves the default profile relative to the working directory" do
    # With HOME unset the old fallback was `"."`, so `fluxion apply` read
    # `./.config/fluxion/default.yaml` — a different file per directory.
    with_env({"HOME" => nil, "XDG_CONFIG_HOME" => nil}) do
      Fluxion::Paths.default_profile.should start_with("/")
    end
  end
end
