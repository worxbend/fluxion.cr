require "../spec_helper"

private def item(key : String) : Fluxion::ModuleItem
  Fluxion::ModuleItem.new("tools", key, Fluxion::ItemType::Package,
    package_manager: Fluxion::PackageManager::Pacman)
end

private def items(count : Int32) : Array(Fluxion::ModuleItem)
  (1..count).map { |index| item("package-#{index}") }
end

# Answers after yielding, so every fiber is in flight before any of them
# finishes. A sweep that ran serially would still pass the ordering
# assertions; this is what makes the concurrency itself observable.
private class SlowProbe < Fluxion::Executor::Probe
  getter concurrent : Int32 = 0
  getter peak : Int32 = 0

  def supports?(item : Fluxion::ModuleItem) : Bool
    true
  end

  def probe(item : Fluxion::ModuleItem, runner : Fluxion::Executor::ShellRunner) : Fluxion::InstallationStatus
    @concurrent += 1
    @peak = Math.max(@peak, @concurrent)
    Fiber.yield
    @concurrent -= 1
    Fluxion::InstallationStatus::InstalledByProbe.new(item.key, item.key.split('-').last)
  end
end

private class ExplodingProbe < Fluxion::Executor::Probe
  def supports?(item : Fluxion::ModuleItem) : Bool
    true
  end

  def probe(item : Fluxion::ModuleItem, runner : Fluxion::Executor::ShellRunner) : Fluxion::InstallationStatus
    raise "probe blew up for #{item.key}"
  end
end

private def sweep(items : Array(Fluxion::ModuleItem), probe : Fluxion::Executor::Probe)
  registry = Fluxion::Executor::ProbeRegistry.new([probe] of Fluxion::Executor::Probe)
  Fluxion::Executor::ProbeSweep.probe_all(items, registry, Fluxion::Executor::FakeShellRunner.new)
end

describe Fluxion::Executor::ProbeSweep do
  it "returns one status per item, in the order the items were given" do
    subjects = items(25)
    statuses = sweep(subjects, SlowProbe.new)

    statuses.size.should eq(subjects.size)
    # The keys must line up index for index: callers zip the result against
    # their own list, so a reordering here would mislabel every row.
    statuses.map(&.item).should eq(subjects.map(&.key))
  end

  it "runs probes concurrently, up to the cap" do
    probe = SlowProbe.new
    sweep(items(25), probe)

    probe.peak.should be > 1
    probe.peak.should be <= Fluxion::Executor::ProbeSweep::MAX_CONCURRENT_PROBES
  end

  it "does not exceed the cap when there are fewer items than workers" do
    probe = SlowProbe.new
    sweep(items(3), probe)

    probe.peak.should be <= 3
  end

  it "reports a probe that raises as unknown rather than losing the item" do
    subjects = items(5)
    statuses = sweep(subjects, ExplodingProbe.new)

    statuses.size.should eq(subjects.size)
    statuses.each do |status|
      status.should be_a(Fluxion::InstallationStatus::Unknown)
    end
  end

  it "keeps probing the remaining items after one raises" do
    # A raising probe must not take its fiber down with it, which would leave
    # every item that fiber had not yet reached with no status at all.
    subjects = items(20)
    statuses = sweep(subjects, ExplodingProbe.new)

    statuses.map(&.item).should eq(subjects.map(&.key))
  end

  it "handles an empty item list" do
    sweep([] of Fluxion::ModuleItem, SlowProbe.new).should be_empty
  end
end
