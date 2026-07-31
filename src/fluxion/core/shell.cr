module Fluxion
  # Login shells Fluxion can re-enter to pick up startup-file changes made by
  # an earlier step.
  enum ShellKind
    Zsh
    Bash
    Sh

    def self.from_config?(value : String?) : self?
      return unless value
      # Accept both a bare name and an absolute path, since profiles write
      # `shell: zsh` for restart policies but `shell: /bin/zsh` for commands.
      case File.basename(value.strip).downcase
      when "zsh"  then Zsh
      when "bash" then Bash
      when "sh"   then Sh
      end
    end

    def config_name : String
      to_s.downcase
    end

    def command : String
      config_name
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end
end
