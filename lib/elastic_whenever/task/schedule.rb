module ElasticWhenever
  class Task
    class Schedule
      attr_reader :option
      attr_reader :group_name
      attr_reader :name
      attr_reader :expression
      attr_reader :expression_timezone
      attr_reader :description
      attr_reader :client

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
          fetch(option, names: names, next_token: response.next_token)
        end
      end

      # TODO: Rate Limit にかからないように検討する必要あり
      def self.fetch(option, names:)
        client = option.scheduler_client
        group_name = option.identifier

        names.map do |name|
          response = client.get_schedule(
            group_name: group_name,
            name: schedule_summary.name
          )

          self.new(
            option,
            group_name: group_name,
            name: schedules.name,
            expression: schedules.schedule_expression,
            expression_timezone: schedules.schedule_expression_timezone,
            description: schedules.description,
            client: client
          )
        end
      end

      def self.fetch_all(option)
        fetch(option, names: fetch_names(option))
      end

      def self.convert(option, expression, expression_timezone, command)
        self.new(
          option,
          name: schedule_name(option, expression, expression_timezone, command),
          expression: expression,
          description: schedule_description(option.identifier, expression, expression_timezone, command)
        )
      end

      def initialize(option, group_name:, name:, expression:, expression_timezone:, description:, client: nil)
        @option = option
        @group_name = group_name
        @name = name
        @expression = expression
        @expression_timezone = expression_timezone
        @description = description
        if client != nil
          @client = client
        else
          @client = option.scheduler_client
        end
      end

      def create
        # See https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/Scheduler/Client.html#create_schedule-instance_method
        Logger.instance.message("Creating Schedule: #{group_name}/#{name} #{expression}")

        # FIXME: create_schedule_group をどこで実施するか？

        # NOTE: このメソッドがよばれるときは schedule_group が存在する前提
        client.create_schedule(
          group_name: group_name,
          name: name,
          schedule_expression: expression,
          schedule_expression_timezone: expression_timezone,
          description: truncate(description, 512),
          state: option.rule_state,
          target: nil # FIXME: どうにかして Target Hash を作成する必要がある
        )
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
