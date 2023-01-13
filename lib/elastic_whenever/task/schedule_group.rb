module ElasticWhenever
  class Task
    class ScheduleGroup
      attr_reader :option
      attr_reader :name
      attr_reader :state
      attr_reader :client

      def self.fetch(option)
        client = option.scheduler_client
        response = client.get_schedule_group(name: option.identifier)

        # FIXME: 存在しない場合はどうなる？
        if response
          self.new(option, name: response.name, client: client)
        end
      end

      def self.convert(option)
        self.new(option, name: option.identifier)
      end

      def initialize(option, name:, client: nil)
        @option = option
        @name = name
        if client != nil
          @client = client
        else
          @client = option.scheduler_client
        end
      end

      # See https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/Scheduler/Client.html#create_schedule_group-instance_method
      def create
        # FIXME: 作成に失敗したらどうなる？
        client.create_schedule_group(name: name)
      end

      # FIXME: delete メソッドは必要になるかわからないため実装を保留
    end
  end
end
