module ElasticWhenever
  class CLI # rubocop:disable Metrics
    SUCCESS_EXIT_CODE = 0
    ERROR_EXIT_CODE = 1

    attr_reader :args, :option

    def initialize(args)
      @args = args
      @option = Option.new(args)
    end

    def run # rubocop:disable Metrics
      case option.mode
      when Option::DRYRUN_MODE
        option.validate!
        update_tasks(dry_run: true)
        Logger.instance.message("Above is your schedule file converted to scheduled tasks; your scheduled tasks was not updated.")
        Logger.instance.message("Run `elastic_whenever --help' for more options.")
      when Option::UPDATE_MODE
        option.validate!
        with_concurrent_modification_handling do
          update_tasks(dry_run: false)
        end
        Logger.instance.log("write", "scheduled tasks updated")
      when Option::CLEAR_MODE
        with_concurrent_modification_handling do
          clear_tasks
        end
        Logger.instance.log("write", "scheduled tasks cleared")
      when Option::LIST_MODE
        list_tasks
        Logger.instance.message("Above is your scheduled tasks.")
        Logger.instance.message("Run `elastic_whenever --help` for more options.")
      when Option::PRINT_VERSION_MODE
        print_version
      end

      SUCCESS_EXIT_CODE
    rescue Aws::Errors::MissingRegionError
      Logger.instance.fail("missing region error occurred; please use `--region` option or export `AWS_REGION` environment variable.")
      ERROR_EXIT_CODE
    rescue Aws::Errors::MissingCredentialsError => e
      Logger.instance.fail("missing credential error occurred; please specify it with arguments, use shared credentials, or export `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variable")
      ERROR_EXIT_CODE
    rescue OptionParser::MissingArgument,
      Option::InvalidOptionException,
      Task::Schedule::InvalidContainerException => exn

      Logger.instance.fail(exn.message)
      ERROR_EXIT_CODE
    end

    private

    def update_tasks(dry_run:) # rubocop:disable Metrics
      schedule = Schedule.new(option.schedule_file, option.verbose, option.variables)

      cluster = Task::Cluster.new(option, option.cluster)
      definition = Task::Definition.new(option, option.task_definition)
      role = Task::Role.new(option)
      if !role.exists? && !dry_run
        role.create
      end

      event_bridge_schedules = schedule.tasks.map do |task|
        task.commands.map do |command|
          Task::Schedule.new(
            option,
            cluster: cluster,
            definition: definition,
            role: role,
            expression: task.expression,
            commands: command
          )
        end
      end.flatten

      if dry_run
        print_task(event_bridge_schedules)
      else
        create_missing_rules_from_targets(targets)
        delete_unused_rules_from_targets(targets)
      end
    end

    def remote_schedules
      schedule_names = Task::Schedule.fetch_names(option)
      Task::Schedule.fetch(option, names: schedule_names)
    end

    # Creates a rule but only persists the rule remotely if it does not exist
    def create_missing_rules_from_targets(targets)
      # FIXME: Rule -> Schedule
      cached_remote_rules = remote_schedules
      targets.each do |target|
        exists = cached_remote_rules.any? do |remote_rule|
          target.rule.name == remote_rule.name
        end

        unless exists
          # FIXME: schedule.create
          # target.rule.create
          # target.create
        end
      end
    end

    def delete_unused_rules_from_targets(targets)
      remote_rules.each do |remote_rule|
        rule_exists_in_schedule = targets.any? do |target|
          target.rule.name == remote_rule.name
        end

        remote_rule.delete unless rule_exists_in_schedule
      end
    end

    def clear_tasks
      Task::Rule.fetch(option).each(&:delete)
    end

    # FIXME: メソッドを修正する必要あり
    def list_tasks
      Task::Rule.fetch(option).each do |rule|
        targets = Task::Target.fetch(option, rule)
        print_task(targets)
      end
    end

    def print_version
      puts "Elastic Whenever v#{ElasticWhenever::VERSION}"
    end

    def print_task(schedules)
      schedules.each do |schedule|
        puts "#{schedule.expression} #{schedule.cluster.name} #{schedule.definition.name} #{schedule.container} #{schedule.commands.join(" ")}"
        puts
      end
    end

    def with_concurrent_modification_handling
      Retryable.retryable(
        tries: 5,
        on: Aws::CloudWatchEvents::Errors::ConcurrentModificationException,
        sleep: lambda { |_n| rand(1..10) },
      ) do |retries, exn|
        if retries > 0
          Logger.instance.warn("concurrent modification detected; Retrying...")
        end
        yield
      end
    end
  end
end
