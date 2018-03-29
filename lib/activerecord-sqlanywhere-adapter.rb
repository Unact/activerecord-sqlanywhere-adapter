# https://github.com/rsim/oracle-enhanced/blob/master/lib/activerecord-oracle_enhanced-adapter.rb
require 'active_record/connection_adapters/sqlanywhere_adapter'
require "active_record/tasks/admin_utils"

if defined?(Rails)
  module ActiveRecord
    module ConnectionAdapters
      class SqlanywhereRailtie < ::Rails::Railtie
        rake_tasks do
          load "active_record/tasks/sqlanywhere_database_tasks.rb"
          load "tasks/sqlanywhere.rake"
        end
      end
    end
  end
end
