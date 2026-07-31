module Fluxion::Config
  # The stable `profile` / `os` / `jobs` frontend.
  #
  # `phases` is accepted as an alias for `jobs`, and `modules` as an alias for
  # `steps` inside a job, so profiles written against the older vocabulary keep
  # working. A flat top-level `modules` list is used only when neither `jobs`
  # nor `phases` is present.
  module JobsSchema
    extend self

    SUPPORTED_SCHEMA_VERSION = 1

    def parse(context : Context, root : Node) : Profile
      version = root["schemaVersion"]
      if version.present? && version.int? != SUPPORTED_SCHEMA_VERSION
        context.error(version.path, "unsupported schemaVersion: #{version.string?}")
      end

      name = context.require_string(root["profile"], "profile")
      if !name.empty? && name.includes?(' ')
        context.error(root["profile"].path, "must not contain spaces")
      end

      target = parse_target(context, root["os"])
      jobs = parse_jobs(context, root)
      validate_graph(context, jobs, root)
      validate_unique_step_names(context, jobs, root)
      validate_package_managers(context, jobs, target)

      Profile.new(
        name.empty? ? "profile" : name,
        target,
        jobs,
        base_dir: context.base_dir,
      )
    end

    private def parse_target(context : Context, node : Node) : TargetOs
      unless node.present?
        context.error(node.path, "os is required")
        return TargetOs.new(Distribution::Fedora)
      end

      type_node = node["type"]
      distribution = Distribution.from_config?(type_node.string?)
      unless distribution
        raw = type_node.string?
        if raw.nil? || raw.strip.empty?
          context.error(type_node.path, "os.type is required")
        else
          context.error(type_node.path, "unsupported OS type: #{raw.strip}",
            "one of fedora, arch, opensuse, debian")
        end
        distribution = Distribution::Fedora
      end

      TargetOs.new(distribution, context.optional_string(node["release"]))
    end

    private def parse_jobs(context : Context, root : Node) : Array(Job)
      jobs_node = root["jobs"]
      jobs_node = root["phases"] unless jobs_node.present?

      if jobs_node.present? && !jobs_node.items.empty?
        return jobs_node.items.compact_map { |entry| parse_job(context, entry) }
      end

      # Legacy flat form: a bare `modules` list with no job structure becomes a
      # single implicit job, so the rest of the pipeline only ever sees jobs.
      modules_node = root["modules"]
      if modules_node.present? && !modules_node.items.empty?
        steps = modules_node.items.compact_map { |entry| StepParser.parse(context, entry) }
        return [Job.new("default", steps, description: "Default job")]
      end

      context.error(root.path.empty? ? "jobs" : root.path, "at least one job, phase, or module is required")
      [] of Job
    end

    private def parse_job(context : Context, node : Node) : Job?
      name = context.require_string(node["name"], "job name")
      return if name.empty?

      steps_node = node["steps"]
      steps_node = node["modules"] unless steps_node.present?
      steps = steps_node.items.compact_map { |entry| StepParser.parse(context, entry) }

      Job.new(
        name,
        steps,
        depends_on: node["dependsOn"].string_list,
        restart_policy: parse_restart_policy(context, node["restartPolicy"]),
        continue_on_step_error: context.bool(node["continueOnModuleError", "continueOnStepError"], true),
        description: context.optional_string(node["description"]) || "",
      )
    end

    private def parse_restart_policy(context : Context, node : Node) : RestartPolicy
      return RestartPolicy::None.new unless node.present?

      type_node = node["type"]
      case type_node.string?.try(&.strip.downcase)
      when "none", nil
        RestartPolicy::None.new
      when "prompt-logout"
        RestartPolicy::PromptLogout.new(
          context.optional_string(node["message"]) || RestartPolicy::PromptLogout::DEFAULT_MESSAGE)
      when "requires-new-shell"
        shell = ShellKind.from_config?(node["shell"].string?)
        if node["shell"].present? && shell.nil?
          context.error(node["shell"].path, "unsupported shell", "one of zsh, bash, sh")
        end
        RestartPolicy::RequiresNewShell.new(shell || ShellKind::Zsh)
      else
        context.error(type_node.path,
          "unsupported restart policy '#{type_node.string?}'",
          "one of #{RestartPolicy::TYPES.join(", ")}")
        RestartPolicy::None.new
      end
    end

    # Job names must be unique and every dependency must exist, otherwise the
    # execution order is undefined rather than merely surprising.
    private def validate_graph(context : Context, jobs : Array(Job), root : Node) : Nil
      path = root["jobs"].path
      names = Set(String).new
      jobs.each do |job|
        context.error(path, "duplicate job name: #{job.name}") unless names.add?(job.name)
      end

      jobs.each do |job|
        job.depends_on.each do |dependency|
          next if names.includes?(dependency)
          context.error(path,
            "job '#{job.name}' declares dependency on unknown job '#{dependency}'")
        end
      end

      return if context.diagnostics.errors?

      begin
        Profile.new("graph-check", TargetOs.new(Distribution::Fedora), jobs).ordered_jobs
      rescue error : ConfigError
        context.error(path, error.message || "cycle in job dependency graph")
      end
    end

    # Step names are the handle for `state forget`, `explain --item`, and the
    # TUI selector, so a duplicate would make those ambiguous.
    private def validate_unique_step_names(context : Context, jobs : Array(Job), root : Node) : Nil
      names = Set(String).new
      jobs.each do |job|
        job.steps.each do |step|
          next if names.add?(step.name)
          context.error(root["jobs"].path, "duplicate step name: #{step.name}")
        end
      end
    end

    # A profile that targets Fedora but installs with apt fails late and
    # confusingly. Catching it at parse time costs nothing.
    private def validate_package_managers(context : Context, jobs : Array(Job), target : TargetOs) : Nil
      expected = target.distribution.package_managers

      jobs.each_with_index do |job, job_index|
        job.steps.each_with_index do |step, step_index|
          manager = case step
                    when PackagesStep     then step.package_manager
                    when SystemUpdateStep then step.package_manager
                    end
          next unless manager
          next if expected.includes?(manager)

          context.error(
            "jobs[#{job_index}].steps[#{step_index}].packageManager",
            "package manager #{manager} is not valid for target #{target.distribution}",
            "expected #{expected.join(" or ")}",
          )
        end
      end
    end
  end
end
