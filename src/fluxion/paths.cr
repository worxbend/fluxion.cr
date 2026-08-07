require "./host"

module Fluxion
  # Where Fluxion keeps things, resolved once.
  #
  # The XDG variables were previously read at six separate call sites, and one
  # of them disagreed with the rest: `Config::Loader.default_path` ignored
  # `XDG_CONFIG_HOME` entirely and fell back to `"."`, so with the variable set
  # `registry install` wrote under it while a bare `apply` read from
  # `$HOME/.config` — and with `HOME` unset the default profile resolved
  # relative to the current directory.
  #
  # Everything that needs a base directory asks here, so the answer cannot
  # differ between two commands.
  module Paths
    extend self

    # The application's own subdirectory inside each XDG root.
    APPLICATION = "fluxion"

    # `$XDG_CONFIG_HOME/fluxion`, or `~/.config/fluxion`.
    def config_root : String
      File.join(base("XDG_CONFIG_HOME", ".config"), APPLICATION)
    end

    # `$XDG_CACHE_HOME/fluxion`, or `~/.cache/fluxion`. Disposable by
    # definition: the registry mirror and the tool cache both live here.
    def cache_root : String
      File.join(base("XDG_CACHE_HOME", ".cache"), APPLICATION)
    end

    # `$XDG_DATA_HOME/fluxion`, or `~/.local/share/fluxion`. What previous runs
    # recorded, and the one root whose loss actually costs the user something.
    def data_root : String
      File.join(base("XDG_DATA_HOME", ".local", "share"), APPLICATION)
    end

    # The profile used when `-c` is not given.
    def default_profile : String
      File.join(config_root, "default.yaml")
    end

    # An empty variable is treated as unset, matching the XDG specification —
    # `XDG_CONFIG_HOME=` means "no preference", not "use the root directory".
    private def base(variable : String, *fallback : String) : String
      ENV[variable]?.presence || File.join(Host.home, *fallback)
    end
  end
end
