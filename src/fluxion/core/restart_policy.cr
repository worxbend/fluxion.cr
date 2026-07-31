module Fluxion
  # What has to happen to the user's session before a job's effects are
  # actually usable.
  #
  # This exists because several kinds of setup exit 0 while the running session
  # still cannot see the result — `usermod -aG docker` is the canonical case.
  # Modelling it lets Fluxion stop cleanly and print a resume command instead of
  # letting later steps fail for reasons the user cannot diagnose.
  abstract struct RestartPolicy
    # Nothing special; the job's effects are live as soon as it finishes.
    struct None < RestartPolicy
      def to_s(io : IO) : Nil
        io << "none"
      end
    end

    # Record state, print a resume command, and stop. The user logs out, logs
    # back in, and reruns.
    struct PromptLogout < RestartPolicy
      DEFAULT_MESSAGE = "Log out and back in, then re-run fluxion."

      getter message : String

      def initialize(@message : String = DEFAULT_MESSAGE)
      end

      def to_s(io : IO) : Nil
        io << "prompt-logout"
      end
    end

    # Run later effects through a fresh login shell so tools that wrote into
    # shell startup files become visible without a full logout.
    struct RequiresNewShell < RestartPolicy
      getter shell : ShellKind

      def initialize(@shell : ShellKind = ShellKind::Bash)
      end

      def to_s(io : IO) : Nil
        io << "requires-new-shell"
      end
    end

    def self.valid_type?(type : String?) : String?
      return unless type
      normalized = type.strip.downcase
      TYPES.includes?(normalized) ? normalized : nil
    end

    TYPES = %w[none prompt-logout requires-new-shell]

    # True when reaching this policy ends the run rather than continuing to the
    # next job.
    def halts? : Bool
      is_a?(PromptLogout)
    end

    def config_name : String
      to_s
    end
  end
end
