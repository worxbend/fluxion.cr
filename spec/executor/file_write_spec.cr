require "../spec_helper"

# `file-writes` puts content the profile declares at a path on the host, and
# `execute` had no coverage at all — not the inline path, not the copy-from-
# source path, not the mode it lands with, and not the missing-source failure.
# Every one of those decides what ends up on disk.
private def with_directory(& : String ->) : Nil
  directory = File.tempname("fluxion-file-write-spec")
  Dir.mkdir_p(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory) rescue nil
  end
end

private def write_step(*files : Fluxion::FileWriteItem) : Fluxion::FileWriteStep
  Fluxion::FileWriteStep.new("files", files.to_a)
end

private def execute(step : Fluxion::FileWriteStep,
                    runner = Fluxion::Executor::FakeShellRunner.new) : Fluxion::StepResult
  executor = Fluxion::Executor::FileWriteExecutor.new
  executor.execute(step, executor.items(step).first, runner) { }
end

describe Fluxion::Executor::FileWriteExecutor do
  it "writes inline content at the declared mode" do
    with_directory do |directory|
      destination = File.join(directory, "motd")
      step = write_step(Fluxion::FileWriteItem.new(
        name: "motd", destination: destination, content: "hello\n", mode: "0640"))

      execute(step).should be_a(Fluxion::StepResult::Success)

      File.read(destination).should eq("hello\n")
      (File.info(destination).permissions.value & 0o777).should eq(0o640)
    end
  end

  it "defaults to 0644 when the item names no mode" do
    with_directory do |directory|
      destination = File.join(directory, "motd")
      step = write_step(Fluxion::FileWriteItem.new(
        name: "motd", destination: destination, content: "hello\n"))

      execute(step)

      (File.info(destination).permissions.value & 0o777).should eq(0o644)
    end
  end

  it "copies the contents of a source file when one is named instead" do
    with_directory do |directory|
      source = File.join(directory, "template")
      destination = File.join(directory, "copied")
      File.write(source, "from a file\n")

      execute(write_step(Fluxion::FileWriteItem.new(
        name: "copied", destination: destination, source: source)))

      File.read(destination).should eq("from a file\n")
    end
  end

  it "replaces an existing file rather than appending to it" do
    with_directory do |directory|
      destination = File.join(directory, "motd")
      File.write(destination, "old content that must not survive\n")

      execute(write_step(Fluxion::FileWriteItem.new(
        name: "motd", destination: destination, content: "new\n")))

      File.read(destination).should eq("new\n")
    end
  end

  it "fails without writing anything when the source file is missing" do
    with_directory do |directory|
      destination = File.join(directory, "copied")
      step = write_step(Fluxion::FileWriteItem.new(
        name: "copied", destination: destination,
        source: File.join(directory, "absent")))

      result = execute(step)

      result.should be_a(Fluxion::StepResult::Failure)
      result.as(Fluxion::StepResult::Failure).error_message.should contain("source file not found")
      File.exists?(destination).should be_false
    end
  end

  it "fails rather than creating the parent directory it was pointed into" do
    with_directory do |directory|
      # Silently creating the parent would let a typo in a destination path
      # scatter files somewhere nobody meant them to go.
      step = write_step(Fluxion::FileWriteItem.new(
        name: "nested", destination: File.join(directory, "absent", "file"),
        content: "hello\n"))

      execute(step).should be_a(Fluxion::StepResult::Failure)
    end
  end

  it "fails without writing anything when the source is a directory" do
    with_directory do |directory|
      # `File.exists?` answers true for a directory, and `File.read` on one
      # raises `IO::Error` — an error outside Fluxion's own set, so it used to
      # escape the per-item boundary and abort the whole run instead of failing
      # this one file.
      source = File.join(directory, "tree")
      Dir.mkdir_p(source)
      destination = File.join(directory, "copied")

      result = execute(write_step(Fluxion::FileWriteItem.new(
        name: "copied", destination: destination, source: source)))

      result.should be_a(Fluxion::StepResult::Failure)
      result.as(Fluxion::StepResult::Failure)
        .error_message.should contain("source is not a regular file")
      File.exists?(destination).should be_false
    end
  end

  it "still copies through a symlink that points at a regular file" do
    with_directory do |directory|
      # The file-type check has to follow symlinks the way `File.read` does,
      # otherwise refusing "not a regular file" would break a perfectly ordinary
      # dotfiles layout where the named source is a link.
      target = File.join(directory, "template")
      link = File.join(directory, "link")
      destination = File.join(directory, "copied")
      File.write(target, "from a link\n")
      File.symlink(target, link)

      execute(write_step(Fluxion::FileWriteItem.new(
        name: "copied", destination: destination, source: link)))

      File.read(destination).should eq("from a link\n")
    end
  end
end
