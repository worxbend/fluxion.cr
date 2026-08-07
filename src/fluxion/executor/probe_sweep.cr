module Fluxion::Executor
  # Runs a whole profile's probes, several at a time.
  #
  # A probe is a subprocess that spends nearly all of its life waiting on a
  # package manager rather than on Fluxion, so running them one after another
  # makes `status` cost the number of items multiplied by however long the
  # slowest query takes. Fibers overlap that waiting: the work is the same, but
  # the idle time is shared instead of serialised.
  #
  # Only read-only sweeps use this. Execution stays strictly sequential,
  # because a step may depend on what an earlier one installed and the order
  # items are reported in is part of what makes a run followable.
  module ProbeSweep
    extend self

    # Enough to hide the latency of any realistic profile, low enough that a
    # large one does not fork hundreds of package-manager queries at once and
    # make the machine unusable while it answers them.
    MAX_CONCURRENT_PROBES = 8

    # Probes every item, returning one status per item **in the order given**.
    #
    # Callers zip the result against their own item list, so completion order
    # must never leak into it — otherwise a report would reshuffle itself
    # between runs for no reason the reader could see.
    def probe_all(items : Array(ModuleItem), probes : ProbeRegistry,
                  runner : ShellRunner) : Array(InstallationStatus)
      results = Array(InstallationStatus?).new(items.size, nil)
      return [] of InstallationStatus if items.empty?

      cursor = Atomic(Int32).new(0)
      workers = Math.min(MAX_CONCURRENT_PROBES, items.size)
      done = Channel(Nil).new

      workers.times do
        spawn do
          loop do
            # `add` returns the previous value, so each fiber claims a distinct
            # index and they collectively cover the list exactly once.
            index = cursor.add(1)
            break if index >= items.size
            results[index] = probe_one(items[index], probes, runner)
          end
        ensure
          done.send(nil)
        end
      end

      workers.times { done.receive }

      # Every slot is filled: the loop above only exits once the cursor is past
      # the end, and `probe_one` answers for every item it is handed.
      results.map { |status| status || unanswered }
    end

    # A probe that raises is reported as unanswerable rather than allowed to
    # kill its fiber, which would leave that item with no status at all and
    # every later item on that fiber unprobed.
    private def probe_one(item : ModuleItem, probes : ProbeRegistry,
                          runner : ShellRunner) : InstallationStatus
      probes.probe(item, runner)
    rescue error
      InstallationStatus::Unknown.new(item.key, "probe could not be executed: #{error.message}")
    end

    private def unanswered : InstallationStatus
      InstallationStatus::Unknown.new("", "probe did not run")
    end
  end
end
