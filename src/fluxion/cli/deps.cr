module Fluxion::CLI
  # The collaborators a command needs to reach the outside world.
  #
  # Built once in `App` and threaded through `Command` exactly the way
  # `@output` already is. Before this, eight commands called
  # `SystemShellRunner.new` or `State::Store.new` inline, so
  # `docs/architecture.md` could call `FakeShellRunner` "the backbone" of
  # testing while no CLI command could be handed one — and the suite showed it:
  # `spec/cli/commands_spec.cr` covered only the five commands that never touch
  # a runner, and `apply`, `status`, `doctor`, `tools` and `generate` had no
  # spec file at all.
  #
  # A record of lazily-built defaults rather than eagerly constructed values:
  # `fluxion --help` should not create a state directory on the way to printing
  # usage.
  struct Deps
    def initialize(
      @runner : Executor::ShellRunner? = nil,
      @store : State::Store? = nil,
      @host_facts : HostFacts? = nil,
    )
    end

    # How processes are run. The one seam every executor already depends on.
    def runner : Executor::ShellRunner
      @runner || Executor::SystemShellRunner.new
    end

    # Where previous runs recorded what they did.
    def store : State::Store
      @store || State::Store.new
    end

    # What machine this is. Memoised by `Host` in production; overridable here
    # so a spec can describe a host it is not running on.
    def host_facts : HostFacts
      @host_facts || Host.facts
    end

    def tool_broker : Executor::ToolBroker
      Executor::ToolBroker.new(runner)
    end

    def git : Registry::Git
      Registry::Git.new(runner)
    end
  end
end
