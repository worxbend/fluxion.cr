module Fluxion::Config
  # The kinds a phase step may declare.
  #
  # One table, read by the manifest mapper, by `validate`, and by
  # `fluxion kinds`. Keeping it single-sourced is what stops the documented
  # list, the accepted list, and the executable list from drifting apart.
  module PlanKinds
    extend self

    enum Category
      Packages
      Apps
      Sdkman
      Installer
      Control

      def config_name : String
        to_s.downcase
      end
    end

    struct Kind
      getter id : String
      getter summary : String
      getter category : Category

      # Pre-install actions this kind's `spec.actions` accepts.
      getter package_actions : Array(String)

      # The package manager a package kind installs with. Nil for kinds where
      # the manifest picks one, or where the concept does not apply.
      getter package_manager : PackageManager?

      def initialize(@id : String, @summary : String, @category : Category,
                     @package_actions : Array(String) = [] of String,
                     @package_manager : PackageManager? = nil)
      end
    end

    APT_ACTIONS    = %w[update upgrade dist-upgrade]
    DNF_ACTIONS    = %w[check-update upgrade swap groupupdate group-update]
    PACMAN_ACTIONS = %w[sync-upgrade syu upgrade]
    ZYPPER_ACTIONS = %w[refresh update dup dup-from]

    # Declaration order is also the order `fluxion kinds` prints and the
    # tie-break order for did-you-mean suggestions.
    ALL = [
      Kind.new("apt-packages", "Install packages with apt.", Category::Packages, APT_ACTIONS, PackageManager::Apt),
      Kind.new("aur-packages", "Install AUR packages with paru or yay.", Category::Packages),
      Kind.new("cargo-packages", "Install crates with cargo.", Category::Packages, package_manager: PackageManager::Cargo),
      Kind.new("dnf-packages", "Install packages with dnf.", Category::Packages, DNF_ACTIONS, PackageManager::Dnf),
      Kind.new("pacman-packages", "Install packages with pacman.", Category::Packages, PACMAN_ACTIONS, PackageManager::Pacman),
      Kind.new("zypper-packages", "Install packages with zypper.", Category::Packages, ZYPPER_ACTIONS, PackageManager::Zypper),
      Kind.new("sdkman-packages", "Install SDKMAN candidates such as java or maven.", Category::Sdkman),
      Kind.new("flatpak-packages", "Install Flatpak applications.", Category::Apps),
      Kind.new("binary-downloads", "Download and install a compiled binary or archive.", Category::Installer),
      Kind.new("shell-scripts", "Run local or HTTPS-fetched shell scripts.", Category::Installer),
      Kind.new("commands", "Run shell or direct argv commands.", Category::Installer),
      Kind.new("file-writes", "Write files from inline content or a source path.", Category::Installer),
      Kind.new("nerd-fonts", "Install Nerd Font families via nerd-fonts-installer.", Category::Installer),
      Kind.new("dotfiles-apply", "Apply a Dotbot configuration via dotbot.", Category::Installer),
      Kind.new("binstaller-profile", "Install binaries from a binstaller BinaryDistributionProfile.", Category::Installer),
      Kind.new("user-groups", "Add the user to groups. Append-only; never removes membership.", Category::Installer),
      Kind.new("git-config", "Set git config entries at global, system or local scope.", Category::Installer),
      Kind.new("git-repo", "Clone git repositories at an exact commit.", Category::Installer),
      Kind.new("systemd-unit", "Enable, mask, start or stop systemd units.", Category::Installer),
      Kind.new("system-setting", "Set timezone, hostname, locale, NTP and the RTC mode.", Category::Installer),
      Kind.new("system-update", "Refresh package metadata or upgrade every installed package.", Category::Installer),
      Kind.new("gpg-key", "Import repository signing keys into a keyring.", Category::Installer),
      Kind.new("tool-packages", "Install via a language tool: cargo-binstall, pipx, snap, uv, npm, go.", Category::Installer),
      Kind.new("toolchain", "Install a language toolchain from its official installer script.", Category::Installer),
      Kind.new("oh-my-zsh", "Install Oh My Zsh at a pinned commit.", Category::Installer),
      Kind.new("default-shell", "Change the user's login shell.", Category::Installer),
      # The repository kinds are also reachable through `spec.sources`. Having
      # them as step kinds too lets a profile place a repository exactly where
      # it is needed when the sources prelude runs too early.
      Kind.new("apt-repository", "Add an apt repository, with its signing key.", Category::Installer),
      Kind.new("rpm-repository", "Add a dnf/yum repository, with its signing key.", Category::Installer),
      Kind.new("zypper-repository", "Add an openSUSE repository, with its signing key.", Category::Installer),
      Kind.new("pacman-repository", "Add a pacman repository to pacman.conf.", Category::Installer),
      Kind.new("flatpak-remote", "Add a Flatpak remote from a verified descriptor.", Category::Installer),
      Kind.new("interrupt", "Write a resumable checkpoint and stop cleanly.", Category::Control),
      Kind.new("shell-reload", "Re-exec the shell so earlier environment changes take effect.", Category::Control),
      Kind.new("assert", "Fail the run unless a command succeeds.", Category::Control),
      Kind.new("manual", "Describe a step the user has to carry out by hand.", Category::Control),
    ]

    def ids : Array(String)
      ALL.map(&.id)
    end

    # Lookup is on the already-normalized id, so `find("APT-PACKAGES")` misses
    # and the caller reports it with a suggestion rather than silently
    # accepting a spelling the docs do not describe.
    def find(id : String) : Kind?
      ALL.find { |kind| kind.id == id }
    end

    def suggestion_for(id : String) : String?
      return if id.empty?
      budget = Math.max(2, id.size // 3)
      best : String? = nil
      best_distance = Int32::MAX

      ALL.each do |kind|
        distance = StepParser.levenshtein(id, kind.id)
        next if distance > budget || distance >= best_distance
        best = kind.id
        best_distance = distance
      end

      best.try { |match| "Did you mean '#{match}'?" }
    end

    # The internal step type each kind maps onto. Only the kinds whose spec
    # shape differs from their builder's — the package family, `file-writes`,
    # and `interrupt` — are absent, because the mapper handles those directly.
    STEP_TYPES = {
      "binary-downloads"   => "compiled-binary",
      "shell-scripts"      => "shell-script",
      "commands"           => "shell-command",
      "nerd-fonts"         => "nerd-fonts",
      "dotfiles-apply"     => "dotbot",
      "binstaller-profile" => "binstaller-profile",
      "user-groups"        => "user-groups",
      "git-config"         => "git-config",
      "git-repo"           => "git-repo",
      "systemd-unit"       => "systemd-unit",
      "system-setting"     => "system-setting",
      "system-update"      => "system-update",
      "gpg-key"            => "gpg-key",
      "tool-packages"      => "tool-packages",
      "toolchain"          => "toolchain",
      "oh-my-zsh"          => "oh-my-zsh",
      "default-shell"      => "default-shell",
      "apt-repository"     => "apt-repository",
      "rpm-repository"     => "rpm-repository",
      "zypper-repository"  => "zypper-repository",
      "pacman-repository"  => "pacman-repository",
      "flatpak-remote"     => "flatpak-remote",
      "shell-reload"       => "shell-reload",
      "assert"             => "assert",
      "manual"             => "manual",
    }
  end
end
