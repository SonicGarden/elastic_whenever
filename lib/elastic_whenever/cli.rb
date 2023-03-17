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

        # with_concurrent_modification_handling do
        #   update_tasks(dry_run: false)
        # end
        update_tasks(dry_run: false)

        Logger.instance.log("write", "scheduled tasks updated")
      when Option::CLEAR_MODE
        # with_concurrent_modification_handling do
        #   clear_tasks
        # end
        clear_tasks

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
            command: command
          )
        end
      end.flatten

      if dry_run
        print_task(event_bridge_schedules)
      else
        create_missing_schedules(event_bridge_schedules)
        delete_unused_schedules(event_bridge_schedules)
      end
    end

    def remote_schedule_names
      @remote_schedule_names ||= Task::Schedule.fetch_names(option)
    end

    # Creates a rule but only persists the rule remotely if it does not exist
    def create_missing_schedules(schedules)
      schedules.each do |schedule|
        exists = remote_schedule_names.any? do |remote_schedule_name|
          schedule.name == remote_schedule_names
        end

        unless exists
          schedule.create
        end
      end
    end

    def delete_unused_schedules(schedules)
      remote_schedule_names.any? do |remote_schedule_name|
        schedule_exists = schedules.any? do |schedule|
          schedule.rule.name == remote_schedule_name
        end

        unless schedule_exists
          Task::Schedule.delete(option, name: remote_schedule_name)
        end
      end
    end

    def clear_tasks
      remote_schedule_names.each do |remote_schedule_name|
        Task::Schedule.delete(option, name: remote_schedule_name)
      end
    end

    def list_tasks
      print_task(Task::Schedule.fetch(option))
    end

    def print_version
      puts "Elastic Whenever v#{ElasticWhenever::VERSION}"
    end

    def print_task(schedules)
      schedules.each do |schedule|
        puts "#{schedule.expression} #{schedule.cluster.name} #{schedule.definition.name} #{schedule.container} #{schedule.command.join(" ")}"
        puts
      end
    end

    # FIXME: Aws::Scheduler でのリトライを検討する必要がある
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
