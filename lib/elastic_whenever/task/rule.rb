module ElasticWhenever
  class Task
    # FIXME: Rule -> Schedule にクラス名を変えたほうがよさそう
    class Rule
      attr_reader :option
      attr_reader :name
      attr_reader :expression
      attr_reader :description

      class UnsupportedOptionException < StandardError; end

      def self.fetch(option, rules: [], next_token: nil)
        client = option.scheduler_client
        prefix = option.identifier

        # TODO: group_name を指定して app & env ごとの schedule group を利用できるようにする
        response = client.list_schedules(name_prefix: prefix, next_token: next_token)

        response.schedules.each do |schedule|
          # FIXME: 実機でレスポンスに以下が含まれているかを確認し、spec のモックを修正する
          rules << self.new(
            option,
            name: schedule.name,
            expression: schedule.schedule_expression,
            expression_timezone: schedule.schedule_expression_timezone,
            description: schedule.description,
            client: client
          )
        end
        if response.next_token.nil?
          rules
        else
          fetch(option, rules: rules, next_token: response.next_token)
        end
      end

      def self.convert(option, expression, command)
        self.new(
          option,
          name: rule_name(option, expression, command),
          expression: expression,
          description: rule_description(option.identifier, expression, command)
        )
      end

      def initialize(option, name:, expression:, description:, client: nil)
        @option = option
        @name = name
        @expression = expression
        @description = description
        if client != nil
          @client = client
        else
          @client = option.cloudwatch_events_client
        end
      end

      # FIXME: create_schedule (with time_zone)
      def create
        # See https://docs.aws.amazon.com/eventbridge/latest/APIReference/API_PutRule.html#API_PutRule_RequestSyntax
        Logger.instance.message("Creating Rule: #{name} #{expression}")
        client.put_rule(
          name: name,
          schedule_expression: expression,
          description: truncate(description, 512),
          state: option.rule_state,
        )
      end

      # FIXME: delete_schedule
      def delete
        targets = client.list_targets_by_rule(rule: name).targets
        client.remove_targets(rule: name, ids: targets.map(&:id)) unless targets.empty?
        Logger.instance.message("Removing Rule: #{name}")
        client.delete_rule(name: name)
      end

      private

      # FIXME: schedule_name
      def self.rule_name(option, expression, command)
        "#{option.identifier}_#{Digest::SHA1.hexdigest([option.key, expression, command.join("-")].join("-"))}"
      end

      # FIXME: schedule_description
      def self.rule_description(identifier, expression, command)
        "#{identifier} - #{expression} - #{command.join(" ")}"
      end

      def truncate(string, max)
        string.length > max ? string[0...max] : string
      end

      attr_reader :client
    end
  end
end
