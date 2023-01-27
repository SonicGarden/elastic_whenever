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
          fetch_names(option, names: names, next_token: response.next_token)
        end
      end

      # TODO: Rate Limit にかからないように検討する必要あり
      def self.fetch(option, names:)
        client = option.scheduler_client
        group_name = option.identifier

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
          flexible_time_window: { maximum_window_in_minutes: 1, mode: 'OFF' },
          input: nil, # required
          role_arn: nil, # required
          target: nil # FIXME: どうにかして Target Hash を作成する必要がある,
        )
      end

      # AWSから考えるオプション
      # フレックスタイムウィンドウ => オフでいい
      # タイムゾーン => 基本は 'Asia/Tokyo'
      # 開始日時、終了日時 = start_date, end_date => 指定なしでいい
      # ターゲット: Amazon ECS RunTask
      # ECSクラスター => arn (arn:aws:ecs .. cluster/[appname]-production...
      # ECSタスク => ex. [appname]-production-rails
      # リビジョン => 最新(latest) にしたい
      # タスクカウント => 1 基本は1でしょう
      # コンピューティングオプション => 起動タイプ FARGATE, プラットフォームなし
      # subnets (public subnets)
      # security-groups
      # auto public-IP => YES
      # commands:
      # {
      #   "containerOverrides": [{
      #     "name": "rails",
      #     "command": ["bundle", "exec", "rake", "execution-rake-task"]
      #   }]
      # }
      # => POST
      # {
      #   description: '...', # 指定する
      #   flexible_time_window: { maximum_window_in_minutes: 1, mode: 'OFF' }, # required / OFF固定でいい
      #   group_name: '...', # identifier (application name "[appname]-[production]-rails") を指定する
      #   name: '...', # required / identifier + 各種パラメータのダイジェスト
      #   schedule_expression: '...', # required
      #   schedule_expression_timezone: 'Asia/Tokyo', # option だが初期値を Tokyo にしておく
      #   state: 'ENABLED', # option にある
      #   target: (SEE: lib/elastic_whenever/task/target.rb),
      #   input: '???', # input_json, { containerOverrides: [{ name: '$task-name', command: commands }]
      #   role_arn: '' # 指定されたやつ or 作ったやつ
      # }
      #

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
