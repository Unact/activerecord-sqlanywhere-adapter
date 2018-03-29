require "tempfile"

# https://github.com/rails/rails/blob/5-1-stable/activerecord/lib/active_record/tasks/postgresql_database_tasks.rb
module ActiveRecord
  module Tasks # :nodoc:
    class SQLAnywhereDatabaseTasks # :nodoc:
      include ActiveRecord::Tasks::AdminUtils
      STRUCTURE_FILE_NAME_WITH_PATH = "db/structure.sql"
      UNLOAD_DATA_DIR = "test/raw_data"
      DEFAULT_AUTH = {
        "username" => "DBA",
        "password" => "sql"
      }

      delegate :connection, :establish_connection, :clear_active_connections!, to: ActiveRecord::Base
      delegate :db_dir, to: ActiveRecord::Tasks::DatabaseTasks

      def initialize(configuration)
        @configuration = configuration
      end

      def create
        raise DatabaseAlreadyExists if File.exist?(dbf)

        options = []
        options << "-z \"#{configuration["collation"]}\"" if configuration["collation"]
        options << "-zn \"#{configuration["ncollation"]}\"" if configuration["ncollation"]
        options << "-p #{configuration["page_size"]}" if configuration["page_size"]
        options << "-i" unless configuration["jconnect"]
        options << "-s" if configuration["checksum"]
        options << "-pd" unless configuration["system_proc_as_definer"]
        options << "-b" if configuration["blank_padding"]

        # Можно, конечно, было сделать через CREATE DATABASE, но если БД лежит в папке db
        # (которая в рельсах по дефолту) то CREATE DATABASE падает с ошибкой
        dbinit options, dbf

        establish_utility_db_connection configuration
        connection.start_database dbf, configuration["database"]
        connection.disconnect!

        # Можно создавать сразу бд с админом (DBA) из настроек (username/password), но это приведет к последующей
        # Невозможности накатить дамп, потому что юзер с идентификатором 1 не обязательно будет тот же юзер, что и в
        # configuration["username"]
        establish_connection_as_dba configuration
        connection.create_admin_user configuration["username"], configuration["password"], configuration["user_id"]
        connection.disconnect!

        establish_connection configuration
        connection
      end

      def drop
        establish_utility_db_connection configuration
        connection.stop_database configuration["database"]
        connection.drop_database dbf
      end

      def purge
        drop
        create
      end

      def collation
        connection.collation
      end

      def charset
        connection.charset
      end

      def structure_dump file_name=STRUCTURE_FILE_NAME_WITH_PATH, flags=[]
        dbunload(%W(
          -y
          #{['-r', file_name].join(' ')}
          -n
        ))
      end

      def structure_load file_name=STRUCTURE_FILE_NAME_WITH_PATH, flags=[]
        dbisql([
          "-onerror exit"
        ], file_name)
      end

      def unload_table table_name
        dbunload(%W(
          -d
          -y
          -xi
          -ss
          #{['-t', table_name].join(' ')}
          #{['-r', unloaded_sql_file_name(table_name)].join(' ')}),
          UNLOAD_DATA_DIR
        )
      end

      def table_structure_dump table_name, file_name
        dbunload(%W(
          -n
          #{['-t', table_name].join(' ')}
          #{['-r', file_name].join(' ')}
        ))
      end

      def load_table table_name
        dbisql([
          "-onerror exit"
        ], unloaded_sql_file_name(table_name))
      end


      protected
        def unloaded_sql_file_name table_name
          "#{UNLOAD_DATA_DIR}/#{table_name}.sql"
        end

      private
        def configuration
          @configuration
        end

        def establish_connection_as_dba configuration
          establish_connection configuration.merge(DEFAULT_AUTH)
        end

        def establish_utility_db_connection configuration
          config = configuration.merge(DEFAULT_AUTH.merge "database" => "utility_db")

          # При коннекте к utility_db параметры берутся из ключей server и database.
          # значение в dbf при этом должно игнорироваться.
          # Но если dbf задан, то при подключении он приоритетней. Поэтому, удалить его
          config.delete("dbf")
          establish_connection config
        end
    end
  end
end

ActiveRecord::Tasks::DatabaseTasks.register_task(/sqlanywhere/, ActiveRecord::Tasks::SQLAnywhereDatabaseTasks)
