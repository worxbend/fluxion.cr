module Fluxion::Executor
  # Host settings, read back through the same tools that set them.
  #
  # Each setting is compared by value, so a machine already on the profile's
  # timezone skips the item and one on another zone does not. Nothing here
  # needs privileges: the `show` side of timedatectl, hostnamectl and localectl
  # is readable by any user.
  class SystemSettingProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.system_setting?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      step = item.step.as?(SystemSettingStep)
      return InstallationStatus::Unknown.new(item.key, "no system-setting step to compare with") unless step

      case key = item.key
      when "ntp"
        step.ntp?.try { |wanted| compare_flag(item, runner, "NTP", wanted) } || unset(item)
      when "localRtc"
        step.local_rtc?.try { |wanted| compare_flag(item, runner, "LocalRTC", wanted) } || unset(item)
      when "timezone"
        step.timezone.try { |wanted| compare(item, wanted, read(item, runner, "timedatectl", ["show", "-p", "Timezone", "--value"])) } || unset(item)
      when "hostname"
        step.hostname.try { |wanted| compare(item, wanted, read(item, runner, "hostnamectl", ["--static"])) } || unset(item)
      else
        name = key.lchop?("locale:")
        wanted = name.try { |variable| step.locale[variable]? }
        return unset(item) unless name && wanted
        compare_locale(item, runner, name, wanted)
      end
    end

    # timedatectl prints its booleans as "yes" and "no". Anything else is the
    # runner's merged stderr — "System has not been booted with systemd" in a
    # container — and is no answer at all.
    private def compare_flag(item : StepItem, runner : ShellRunner, property : String,
                             wanted : Bool) : InstallationStatus
      answer = read(item, runner, "timedatectl", ["show", "-p", property, "--value"])
      return answer if answer.is_a?(InstallationStatus)
      return unanswered(item, "timedatectl", answer, 0) unless answer.in?("yes", "no")

      compare(item, wanted ? "yes" : "no", answer)
    end

    # `localectl status` lists one VAR=value per line under "System Locale:",
    # and the headings of the lines that follow contain ": ", which no locale
    # assignment does.
    private def compare_locale(item : StepItem, runner : ShellRunner, name : String,
                               wanted : String) : InstallationStatus
      answer = read(item, runner, "localectl", ["status"], whole: true)
      return answer if answer.is_a?(InstallationStatus)

      current = nil
      answer.each_line do |raw|
        line = raw.strip.lchop("System Locale:").strip
        next if line.includes?(": ")
        variable, equals, value = line.partition('=')
        current = value if equals == "=" && variable == name
      end

      current ? compare(item, wanted, current) : InstallationStatus::NotInstalled.new(item.key)
    end

    # The tool's answer, trimmed to its first line unless `whole` is set, or
    # the status that says why there is none.
    private def read(item : StepItem, runner : ShellRunner, tool : String, arguments : Array(String),
                     whole : Bool = false) : String | InstallationStatus
      return InstallationStatus::Unknown.new(item.key, "#{tool} is not on PATH") unless runner.command_exists?(tool)

      result = runner.run(Command.new([tool] + arguments, timeout: PROBE_TIMEOUT))
      output = whole ? result.stdout : (result.stdout.lines.first?.try(&.strip) || "")
      return output if result.success? && !output.strip.empty?
      unanswered(item, tool, output, result.exit_code)
    end

    private def compare(item : StepItem, wanted : String, current : String | InstallationStatus) : InstallationStatus
      return current if current.is_a?(InstallationStatus)
      return InstallationStatus::InstalledByProbe.new(item.key, current) if current == wanted
      InstallationStatus::NotInstalled.new(item.key)
    end

    private def unanswered(item : StepItem, tool : String, said : String, exit_code : Int32) : InstallationStatus
      InstallationStatus::Unknown.new(item.key,
        "#{tool} said #{said.strip.lines.first?.inspect} (exit #{exit_code})")
    end

    # An item key the step does not set: not something this probe was asked.
    private def unset(item : StepItem) : InstallationStatus
      InstallationStatus::Unknown.new(item.key, "#{item.key} is not set by this step")
    end
  end
end
