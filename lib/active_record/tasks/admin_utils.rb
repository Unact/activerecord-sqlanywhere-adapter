module ActiveRecord
  module Tasks
    module AdminUtils
      def dbinit options = [], new_database_file
        opt = options_with_quite_mode(options)
        opt << new_database_file

        Kernel.system("dbinit #{opt.join(' ')}")
      end

      def dbunload options = [], directory = nil
        opt = options_with_connection_string(options)
        opt = options_with_quite_mode(opt)
        opt << directory if directory

        Kernel.system("dbunload #{opt.join(' ')}")
      end

      def dbisql options, file_name
        opt = options_with_connection_string(options)
        opt << file_name

        Kernel.system("dbisql #{opt.join(' ')}")
      end

      def dbeng16 options
        database_file = File.exist?(dbf) ? " #{dbf}" : ""
        Kernel.system("dbeng16 #{options.join(' ')}#{database_file}")
      end

      def dbf
        File.join(Rails.root, configuration["dbf"])
      end

      private
        def options_with_quite_mode options
          options.clone.concat(["-q"])
        end

        def options_with_connection_string options
          options.clone.concat(["-c \"#{connection.connection_string}\""])
        end
    end
  end
end
