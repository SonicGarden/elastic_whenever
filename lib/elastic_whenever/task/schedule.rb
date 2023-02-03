module ElasticWhenever
  class Task
    class Schedule # rubocop:disable Metrics
      attr_reader :option
      attr_reader :group_name
      attr_reader :name
      attr_reader :expression
      attr_reader :expression_timezone
      attr_reader :description
      attr_reader :client

      attr_reader :cluster
      attr_reader :definition
      attr_reader :role
      attr_reader :command

      attr_reader :container

      class InvalidContainerException < StandardError; end
      class UnsupportedOptionException < StandardError; end

      def self.fetch_names(option, names: [], next_token: nil)
        client = option.scheduler_client
        prefix = option.identifier
        group_name = option.identifier

        response = client.list_schedules(group_name: group_name, name_prefix: prefix, next_token: next_token)

        response.schedules.each do |schedule_summary|
          names << schedule_summary.name
        end

        if response.next_token.nil?
          names
        else
          fetch_names(option, names: names, next_token: response.next_token)
        end
      end

      # TODO: Rate Limit にかからないように検討する必要あり
      def self.fetch(option, names: nil)
        client = option.scheduler_client
        group_name = option.identifier

        names ||= fetch_names(option)
        names.map do |name|
          response = client.get_schedule(group_name: group_name, name: name)

          self.new(
            option,
            group_name: group_name,
            name: response.name,
            expression: response.schedule_expression,
            expression_timezone: response.schedule_expression_timezone,
            description: response.description,
            client: client
          )
        end
      end

      def self.fetch_all(option)
        fetch(option, names: fetch_names(option))
      end

      def self.convert(option, expression, expression_timezone, command)
        group_name = option.identifier

        self.new(
          option,
          group_name: group_name,
          name: schedule_name(option, expression, expression_timezone, command),
          expression: expression,
          expression_timezone: expression_timezone,
          description: schedule_description(option.identifier, expression, expression_timezone, command)
        )
      end

      # FIXME: 引数を見直す必要あり
      def initialize(option, cluster:, definition:, role:, command:, expression:, client: nil)
        container = option.container
        unless definition.containers.include?(container)
          raise InvalidContainerException.new("#{container} is invalid container. valid=#{definition.containers.join(",")}")
        end

        @option = option

        @cluster = cluster
        @definition = definition
        @role = role
        @command = command

        @group_name = option.identifier
        @expression = expression
        @expression_timezone = 'Asia/Tokyo'
        @name = self.class.schedule_name(option, expression, expression_timezone, command)
        @description = self.class.schedule_description(option.identifier, expression, expression_timezone, command)

        @container = container

        if client != nil
          @client = client
        else
          @client = option.scheduler_client
        end
      end

      def create # rubocop:disable Metrics
        # See https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/Scheduler/Client.html#create_schedule-instance_method
        Logger.instance.message("Creating Schedule: #{group_name}/#{name} #{expression}")

        # FIXME: create_schedule_group をどこで実施するか？

        # NOTE: このメソッドがよばれるときは schedule_group が存在する前提
        client.create_schedule(create_options)
      end

      def create_options
        {
          group_name: group_name,
          name: name,
          schedule_expression: expression,
          schedule_expression_timezone: expression_timezone,
          description: truncate(description, 512),
          state: option.rule_state,
          flexible_time_window: { maximum_window_in_minutes: 1, mode: 'OFF' },
          input: input_json,
          role_arn: role.arn,
          target: target_hash
        }
      end

      def input_json
        {
          containerOverrides: [
            {
              name: option.container,
              command: command
            }
          ]
        }.to_json
      end

      def target_hash # rubocop:disable Metrics
        {
          arn: cluster.arn, # required / ECS Cluster の ARN
          ecs_parameters: {
            launch_type: 'FARGATE', # => OR option.launch_type
            network_configuration: {
              awsvpc_configuration: {
                assign_public_ip: 'ENABLED', # => OR option.assign_public_ip
                security_groups: option.security_groups,
                subnets: option.subnets
              }
            },
            platform_version: 'LATEST', # OR option.platform_version
            task_count: 1,
            task_definition_arn: definition.arn
          }
        }
      end

      def delete
        # FIXME: EventBridge では target を rule とは別管理しているようだが Scheduler ではそうならない？
        # targets = client.list_targets_by_rule(rule: name).targets
        # client.remove_targets(rule: name, ids: targets.map(&:id)) unless targets.empty?

        Logger.instance.message("Removing Schedule: #{group_name}/#{name}")

        client.delete_schedule(
          group_name: group_name,
          name: name
        )
      end

      private

      def self.schedule_name(option, expression, expression_timezone, command)
        "#{option.identifier}_#{Digest::SHA1.hexdigest([option.key, expression, expression_timezone, command.join("-")].join("-"))}"
      end

      def self.schedule_description(identifier, expression, expression_timezone, command)
        "#{identifier} - #{expression} (#{expression_timezone}) - #{command.join(" ")}"
      end

      def truncate(string, max)
        string.length > max ? string[0...max] : string
      end
    end
  end
end
