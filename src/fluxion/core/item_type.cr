module Fluxion
  # What kind of thing an item is.
  #
  # This is the discriminator persisted in the state file and printed by
  # `status`, `diff`, and `state show`. It is deliberately finer-grained than
  # the step kind: one `packages` step produces both `PackageAction` and
  # `Package` items, and `state forget --type` needs to tell them apart.
  enum ItemType
    PackageAction
    Package
    AptRepository
    RpmRepository
    ZypperRepository
    PacmanRepository
    FileWrite
    Flatpak
    FlatpakRemote
    ShellScript
    # Retired with the `binary-downloads` kind. Kept because it is the
    # discriminator in state files previous runs wrote, and in files the Java
    # implementation wrote — deleting it would make those unreadable. Nothing
    # produces it any more.
    CompiledBinary
    Dotbot
    DefaultShell
    OhMyZsh
    Toolchain
    NerdFont
    ShellReload
    ShellCommand
    Assert
    Manual
    Interrupt
    SdkmanPackage
    BinstallerProfile
    UserGroup
    GitConfig
    GitRepo
    SystemdUnit
    SystemSetting
    SystemUpdate
    GpgKey
    ToolPackage

    # Screaming snake case, as persisted in state files and printed by
    # `state show` and `state forget`.
    def state_name : String
      String.build do |io|
        to_s.each_char_with_index do |char, index|
          io << '_' if index > 0 && char.uppercase?
          io << char.upcase
        end
      end
    end

    # Lowercase snake case, as emitted in JSON output.
    def json_name : String
      state_name.downcase
    end

    # Accepts what a user would plausibly type for `state forget --type`:
    # either spelling of the separator, in any case.
    def self.from_config?(value : String?) : self?
      return unless value
      normalized = value.strip.downcase.tr("-", "_")
      each { |member| return member if member.json_name == normalized }
      nil
    end

    def to_s(io : IO) : Nil
      io << state_name
    end
  end

  # Outcome recorded for a phase in the state file.
  enum PhaseStatus
    Completed
    Failed
    Blocked
    Skipped

    def state_name : String
      to_s.upcase
    end

    def json_name : String
      to_s.downcase
    end

    def self.from_config?(value : String?) : self?
      return unless value
      parse?(value.strip.downcase) rescue nil
    end
  end
end
