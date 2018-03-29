namespace :asa do
  desc "run test server"
  task :run_server do |task, args|
    adapter_name = ActiveRecord::ConnectionAdapters::SQLAnywhereAdapter::ADAPTER_NAME.downcase
    test_config = Rails.application.config.database_configuration["test"]

    raise "test adapter must be #{adapter_name}" unless adapter_name == test_config["adapter"].downcase

    server = test_config["server"]
    page_size = test_config["page_size"]

    utils = Struct.new(:configuration)
    utils.send :include, ActiveRecord::Tasks::AdminUtils

    utils.new(test_config).dbeng16(["-x tcpip", "-gp #{page_size}", "-n #{server}"])
  end
end
