#====================================================
#
#    Copyright 2008-2010 iAnywhere Solutions, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.
#
# While not a requirement of the license, if you do modify this file, we
# would appreciate hearing about it.   Please email sqlany_interfaces@sybase.com
#
#
#====================================================

require 'active_record/connection_adapters/abstract_adapter'
require "active_record/connection_adapters/sqlanywhere/column"
require 'active_record/connection_adapters/sqlanywhere/quoting'
require 'arel/visitors/sqlanywhere.rb'

# Singleton class to hold a valid instance of the SQLAnywhereInterface across all connections
class SA
  include Singleton
  def api
    if @pid != Process.pid
      reset_api
    end
    @api
  end

  def initialize
    @api = nil
    @pid = nil
    require 'sqlanywhere' unless defined? SQLAnywhere
    reset_api
  end

  private
  def reset_api
    @pid = Process.pid
    if @api != nil
      @api.sqlany_fini()
      SQLAnywhere::API.sqlany_finalize_interface( @api )
    end
    @api = SQLAnywhere::SQLAnywhereInterface.new()
    raise LoadError, "Could not load SQLAnywhere DBCAPI library" if SQLAnywhere::API.sqlany_initialize_interface(@api) == 0
    raise LoadError, "Could not initialize SQLAnywhere DBCAPI library" if @api.sqlany_init() == 0
  end
end

module ActiveRecord
  class Base
    DEFAULT_CONFIG = { :username => 'dba', :password => 'sql' }
    CREATE_DB_CONFIG = %i(collation ncollation page_size jconnect checksum system_proc_as_definer blank_padding user_id)

    # Main connection function to SQL Anywhere
    # Connection Adapter takes four parameters:
    # * :database (required, no default). Corresponds to "DatabaseName=" in connection string
    # * :server (optional, defaults to :databse). Corresponds to "ServerName=" in connection string
    # * :username (optional, default to 'dba')
    # * :password (optional, deafult to 'sql')
    # * :encoding (optional, defaults to charset of OS)
    # * :commlinks (optional). Corresponds to "CommLinks=" in connection string
    # * :connection_name (optional). Corresponds to "ConnectionName=" in connection string

    def self.sqlanywhere_connection(config)

      if config[:connection_string]
        connection_string = config[:connection_string]
      else
        config = DEFAULT_CONFIG.merge(config)

        raise ArgumentError, "No database name was given. Please add a :database option." unless config.has_key?(:database)

        connection_string  = "ServerName=#{(config.delete(:server) || config.delete(:database))};"
        connection_string += "DatabaseName=#{config.delete(:database)};"
        connection_string += "UserID=#{config.delete(:username)};"
        connection_string += "Password=#{config.delete(:password)};"
        connection_string += "CommLinks=#{config.delete(:commlinks)};" unless config[:commlinks].nil?
        connection_string += "ConnectionName=#{config.delete(:connection_name)};" unless config[:connection_name].nil?
        connection_string += "CharSet=#{config.delete(:encoding)};" unless config[:encoding].nil?

        # Since we are using default ConnectionPool class
        # and SqlAnywhere uses CPOOL variable for connection
        # we have to delete pool if it is available
        config.delete(:pool)
        config.delete(:adapter)


        config.except! *CREATE_DB_CONFIG

        # Then add all other connection settings
        config.each_pair do |k, v|
          connection_string += "#{k}=#{v};"
        end
      end

      db = SA.instance.api.sqlany_new_connection()

      ConnectionAdapters::SQLAnywhereAdapter.new(db, logger, connection_string)
    end
  end

  module ConnectionAdapters
    class SQLAnywhereException < StandardError
      attr_reader :errno
      attr_reader :sql

      def initialize(message, errno, sql)
        super(message)
        @errno = errno
        @sql = sql
      end
    end

    class SQLAnywhereAdapter < AbstractAdapter
      include SQLAnywhere::Quoting
      attr_reader :connection_string

      ADAPTER_NAME = "SQLAnywhere".freeze

      def arel_visitor
        Arel::Visitors::SQLAnywhere.new self
      end

      def quote_table_name_for_assignment(table, attr)
        quote_column_name(attr)
      end

      def quote_table_name table_name
        table_name.split(".").collect{ |part| quote_column_name(part) }.join(".")
      end

      def initialize( connection, logger, connection_string = "") #:nodoc:
        super(connection, logger)
        @auto_commit = true
        @affected_rows = 0
        @connection_string = connection_string
        connect!
      end

      def current_database
        select_value "SELECT DB_PROPERTY('Name')", "SCHEMA"
      end

      def collation
        select_value "SELECT DB_EXTENDED_PROPERTY('Collation', 'Specification')", "SCHEMA"
      end

      def charset
        select_value "SELECT DB_PROPERTY('CharSet')", "SCHEMA"
      end

      def ncollation
        select_value "SELECT DB_EXTENDED_PROPERTY('NcharCollation', 'Specification')", "SCHEMA"
      end

      def ncharset
        select_value "SELECT DB_PROPERTY('CharSet')", "SCHEMA"
      end

      def explain(arel, binds = [])
        raise NotImplementedError
      end

      def truncate_table(table_name)
        execute "TRUNCATE TABLE #{quote_table_name table_name}"
      end

      def start_database dbf, dbname
        execute "START DATABASE '#{dbf}' AS #{dbname} AUTOSTOP OFF"
      end

      def stop_database database
        execute("STOP DATABASE #{database} UNCONDITIONALLY")
      rescue ActiveRecord::StatementInvalid => error # Если БД нет, то все ОК
        raise unless error.is_a? ActiveRecord::NoDatabaseError
      end

      def drop_database dbf
        execute("DROP DATABASE '#{dbf}'")
      rescue ActiveRecord::StatementInvalid => error # Если БД нет, то все ОК
        raise unless error.is_a? ActiveRecord::NoDatabaseError
      end

      # id нужен для того, что бы созадть пользователя под тем же идентификатором, под котором он заведен в продакшен
      # это позволит в дальнейшем накатить дамп
      def create_admin_user username, password, id=nil
        at_part = id.present? ? "AT #{id}" : ""
        execute "GRANT CONNECT TO \"#{username}\" #{at_part} IDENTIFIED BY '#{password}';"
        execute "GRANT ROLE \"SYS_AUTH_DBA_ROLE\" TO \"#{username}\"  WITH ADMIN OPTION WITH NO SYSTEM PRIVILEGE INHERITANCE;"
      end

      # Не работает, надо названия таблиц доработать
      def supports_migrations? #:nodoc:
        false
      end

      def requires_reloading?
        true
      end

      def active?
        # The liveness variable is used a low-cost "no-op" to test liveness
        SA.instance.api.sqlany_execute_immediate(@connection, "SET liveness = 1") == 1
      rescue
        false
      end

      def disconnect!
        SA.instance.api.sqlany_disconnect( @connection )
        super
      end

      def reconnect!
        disconnect!
        connect!
      end

      def supports_count_distinct? #:nodoc:
        true
      end

      def supports_autoincrement? #:nodoc:
        true
      end

      # Maps native ActiveRecord/Ruby types into SQLAnywhere types
      # TINYINTs are treated as the default boolean value
      # ActiveRecord allows NULLs in boolean columns, and the SQL Anywhere BIT type does not
      # As a result, TINYINT must be used. All TINYINT columns will be assumed to be boolean and
      # should not be used as single-byte integer columns. This restriction is similar to other ActiveRecord database drivers
      def native_database_types #:nodoc:
        {
          :primary_key => 'INTEGER PRIMARY KEY DEFAULT AUTOINCREMENT NOT NULL',
          :string      => { :name => "varchar", :limit => 255 },
          :text        => { :name => "long varchar" },
          :integer     => { :name => "integer", :limit => 4 },
          :float       => { :name => "float" },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "datetime" },
          :timestamp   => { :name => "datetime" },
          :time        => { :name => "time" },
          :date        => { :name => "date" },
          :binary      => { :name => "binary" },
          :boolean     => { :name => "tinyint", :limit => 1}
        }
      end

      def execute sql, name = nil
        log(sql, name) do
          _execute sql, name
        end
      end

      # The database execution function
      def _execute(sql, name)
        begin
          stmt = SA.instance.api.sqlany_prepare(@connection, sql)
          sqlanywhere_error_test(sql) if stmt==nil
          r = SA.instance.api.sqlany_execute(stmt)
          sqlanywhere_error_test(sql) if r==0
          @affected_rows = SA.instance.api.sqlany_affected_rows(stmt)
          sqlanywhere_error_test(sql) if @affected_rows==-1
        rescue StandardError => e
          @affected_rows = 0
          SA.instance.api.sqlany_rollback @connection
          raise e
        ensure
          SA.instance.api.sqlany_free_stmt(stmt)
          SA.instance.api.sqlany_commit(@connection) if @auto_commit
        end
        @affected_rows
      end

      def sqlanywhere_error_test(sql = '')
        error_code, error_message = SA.instance.api.sqlany_error(@connection)
        if error_code != 0
          sqlanywhere_error(
            error_code,
            error_message.force_encoding(ActiveRecord::Base.connection_config['encoding'] || "UTF-8"),
            sql
          )
        end
      end

      def sqlanywhere_error(code, message, sql)
        raise SQLAnywhereException.new(message, code, sql)
      end

      def translate_exception(exception, message)
        encoded_msg = message.force_encoding(ActiveRecord::Base.connection_config['encoding'] || "UTF-8")
        return super unless exception.respond_to?(:errno)
        case exception.errno
          when -143
            if exception.sql !~ /^SELECT/i then
              raise ActiveRecord::ActiveRecordError.new encoded_msg
            else
              super
            end
          when -194
            raise ActiveRecord::InvalidForeignKey.new encoded_msg
          when -196
            raise ActiveRecord::RecordNotUnique.new encoded_msg
          when -83
            raise ActiveRecord::NoDatabaseError.new encoded_msg
          when -183
            raise ArgumentError, encoded_msg
          else
            super
        end
      end

      def last_inserted_id(result)
        select('SELECT @@IDENTITY', 'SCHEMA').first["@@IDENTITY"]
      end

      def begin_db_transaction #:nodoc:
        @auto_commit = false
      end

      def commit_db_transaction #:nodoc:
        SA.instance.api.sqlany_commit(@connection)
        @auto_commit = true
      end

      def rollback_db_transaction #:nodoc:
        SA.instance.api.sqlany_rollback(@connection)
        @auto_commit = true
      end

      # SQL Anywhere does not support sizing of integers based on the sytax INTEGER(size). Integer sizes
      # must be captured when generating the SQL and replaced with the appropriate size.
      def type_to_sql(type, limit: nil, precision: nil, scale: nil, **) #:nodoc:
        type = type.to_sym
        if native_database_types[type]
          if type == :integer
            case limit
              when 1
                'tinyint'
              when 2
                'smallint'
              when 3..4
                'integer'
              when 5..8
                'bigint'
              else
                'integer'
            end
          elsif type == :string and !limit.nil?
             "varchar (#{limit})"
          elsif type == :boolean
            'tinyint'
          elsif type == :binary
            if limit
              "binary (#{limit})"
            else
              "long binary"
            end
          else
            super
          end
        else
          super
        end
      end

      # Do not return SYS-owned or RS_systabgroup-owned
      def tables(name = nil) #:nodoc:
        sql = <<-SQL
          SELECT
            (
              SELECT user_name
              FROM SYS.SYSUSER
              WHERE SYS.SYSUSER.user_id = SYS.SYSTABLE.creator
            ) + '.' + SYS.SYSTABLE.table_name table_name
          FROM SYS.SYSTABLE
          WHERE
            SYS.SYSTABLE.table_type = 'BASE' AND
            SYS.SYSTABLE.creator NOT IN (0,5) AND
            SYS.SYSTABLE.server_type = 'SA'
        SQL
        exec_query(sql, 'SCHEMA').map { |row| row["table_name"] }
      end

      # Returns an array of view names defined in the database.
      def views(name = nil) #:nodoc:
        sql = <<-SQL
          SELECT
            (
              SELECT user_name
              FROM SYS.SYSUSER
              WHERE SYS.SYSUSER.user_id = SYS.SYSTAB.creator
            ) + '.' + SYS.SYSTAB.table_name table_name
          FROM SYS.SYSTAB
          WHERE
            SYS.SYSTAB.table_type_str = 'VIEW' AND
            SYS.SYSTAB.creator NOT IN (0,5) AND
            SYS.SYSTAB.server_type = 1
        SQL
        exec_query(sql, 'SCHEMA').map { |row| row["table_name"] }
      end

      def columns(table_name, name = nil) #:nodoc:
        table_structure(table_name).map do |field|
          type_metadata = fetch_type_metadata(field['domain'])
          SQLAnywhereColumn.new(field['name'], field['default'], type_metadata, (field['nulls'] == 1), table_name)
        end
      end

      def indexes(table_name, name = nil) #:nodoc:
        table_name_parts = table_name.split(".")

        sql = <<-SQL
          SELECT DISTINCT index_name, \"unique\"
          FROM SYS.SYSTABLE
          INNER JOIN SYS.SYSIDXCOL ON SYS.SYSTABLE.table_id = SYS.SYSIDXCOL.table_id
          INNER JOIN SYS.SYSIDX ON SYS.SYSTABLE.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id
          WHERE
            SYS.SYSTABLE.table_name = '#{table_name_parts.last}' AND
            index_category > 2 AND
            SYS.SYSTABLE.creator = (
              SELECT user_id FROM SYS.SYSUSER WHERE SYS.SYSUSER.user_name = '#{table_name_parts.first}'
            )
        SQL

        exec_query(sql, name).map do |row|
          index = IndexDefinition.new(table_name, row['index_name'])
          index.unique = row['unique'] == 1
          sql = <<-SQL
            SELECT column_name
            FROM SYS.SYSIDX
            INNER JOIN SYS.SYSIDXCOL ON
              SYS.SYSIDXCOL.table_id = SYS.SYSIDX.table_id AND
              SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id
            INNER JOIN SYS.SYSCOLUMN ON
              SYS.SYSCOLUMN.table_id = SYS.SYSIDXCOL.table_id AND
              SYS.SYSCOLUMN.column_id = SYS.SYSIDXCOL.column_id
            WHERE index_name = '#{row['index_name']}'
          SQL

          index.columns = exec_query(sql, name).map { |col| col['column_name'] }
          index
        end
      end

      def primary_key(table_name) #:nodoc:
        table_name_parts = table_name.split(".")
        sql = <<-SQL
          select cname
          from SYS.SYSCOLUMNS
          where tname = '#{table_name_parts.last}'
            and creator = '#{table_name_parts.first}'
            and in_primary_key = 'Y'
        SQL

        rs = exec_query(sql, 'SCHEMA')
        if !rs.nil? and !rs.first.nil?
          rs.first['cname']
        else
          nil
        end
      end

      def remove_index(table_name, options={}) #:nodoc:
        exec_query "DROP INDEX #{quote_table_name(table_name)}.#{quote_column_name(index_name(table_name, options))}"
      end

      def rename_table(name, new_name)
        exec_query "ALTER TABLE #{quote_table_name(name)} RENAME #{quote_table_name(new_name)}"
        rename_table_indexes(name, new_name)
      end

      def change_column_default(table_name, column_name, default) #:nodoc:
        exec_query "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} DEFAULT #{quote(default)}"
      end

      def change_column_null(table_name, column_name, null, default = nil)
        unless null || default.nil?
          exec_query("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
        end
        exec_query("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? '' : 'NOT'} NULL")
      end

      def change_column(table_name, column_name, type, options = {}) #:nodoc:
        add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        add_column_options!(add_column_sql, options)
        add_column_sql << ' NULL' if options[:null]
        exec_query(add_column_sql)
      end

      def rename_column(table_name, column_name, new_column_name) #:nodoc:
        if column_name.downcase == new_column_name.downcase
          whine = "if_the_only_change_is_case_sqlanywhere_doesnt_rename_the_column"
          rename_column table_name, column_name, "#{new_column_name}#{whine}"
          rename_column table_name, "#{new_column_name}#{whine}", new_column_name
        else
          exec_query "ALTER TABLE #{quote_table_name(table_name)} RENAME #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
        end
        rename_column_indexes(table_name, column_name, new_column_name)
      end

      def remove_column(table_name, *column_names)
        raise ArgumentError, "missing column name(s) for remove_column" unless column_names.length>0
        column_names = column_names.flatten
        quoted_column_names = column_names.map {|column_name| quote_column_name(column_name) }
        column_names.zip(quoted_column_names).each do |unquoted_column_name, column_name|
          sql = <<-SQL
            SELECT "index_name" FROM SYS.SYSTAB join SYS.SYSTABCOL join SYS.SYSIDXCOL join SYS.SYSIDX
            WHERE "column_name" = '#{unquoted_column_name}' AND "table_name" = '#{table_name}'
          SQL
          select(sql, nil).each do |row|
            execute "DROP INDEX \"#{table_name}\".\"#{row['index_name']}\""
          end
          exec_query "ALTER TABLE #{quote_table_name(table_name)} DROP #{column_name}"
        end
      end

      def disable_referential_integrity(&block) #:nodoc:
        with_connection_property "wait_for_commit", "ON", &block
      end

      def with_connection_property(property_name, property_value, &block)
        old = select_value("SELECT connection_property( '#{property_name}' )", 'SCHEMA')

        begin
          update("SET TEMPORARY OPTION #{property_name} = '#{property_value}'", 'SCHEMA')
          result = yield
        ensure
          update("SET TEMPORARY OPTION #{property_name} = '#{old}'", 'SCHEMA')
          result
        end
      end

      # Adjust the order of offset & limit as SQLA requires
      # TOP & START AT to be at the start of the statement not the end
      def combine_bind_parameters(
        from_clause: [],
        join_clause: [],
        where_clause: [],
        having_clause: [],
        limit: nil,
        offset: nil
      ) # :nodoc:
        result = []
        result << limit if limit
        if offset
          # Can't see a better way of doing this, we need to add 1 to the offset value
          # as SQLA uses START AT, see active_record model query_methods.rb bound_attributes method
          offset_bind = Attribute.with_cast_value(
            "OFFSET".freeze,
            offset.value.to_i+1, # SQLA START AT = OFFSET + 1
            Type::Value.new,
          )
          result << offset_bind
        end
        result = result + from_clause + join_clause + where_clause + having_clause
        result
      end

      # SQLA requires the ORDER BY columns in the select list for distinct queries, and
      # requires that the ORDER BY include the distinct column.
      def columns_for_distinct(columns, orders) #:nodoc:
        order_columns = orders.reject(&:blank?).map{ |s|
            # Convert Arel node to string
            s = s.to_sql unless s.is_a?(String)
            # Remove any ASC/DESC modifiers
            s.gsub(/\s+(?:ASC|DESC)\b/i, '')
             .gsub(/\s+NULLS\s+(?:FIRST|LAST)\b/i, '')
          }.reject(&:blank?).map.with_index { |column, i| "#{column} AS alias_#{i}" }

        [super, *order_columns].join(', ')
      end

      def primary_keys(table_name) # :nodoc:
        table_name_parts = table_name.split(".")
        # SQL to get primary keys for a table
        sql = "SELECT list(c.column_name order by ixc.sequence) as pk_columns
          from SYSIDX ix, SYSTABLE t, SYSIDXCOL ixc, SYSCOLUMN c
          where ix.table_id = t.table_id
            and ixc.table_id = t.table_id
            and ixc.index_id = ix.index_id
            and ixc.table_id = c.table_id
            and ixc.column_id = c.column_id
            and ix.index_category in (1,2)
            and t.table_name = '#{table_name_parts.last}'
            and t.creator = (SELECT user_id FROM SYS.SYSUSER WHERE SYS.SYSUSER.user_name = '#{table_name_parts.first}')
          group by ix.index_name, ix.index_id, ix.index_category
          order by ix.index_id"
        pks = exec_query(sql, "SCHEMA").to_hash.first
        if pks['pk_columns']
          pks['pk_columns'].split(',')
        else
          nil
        end
      end

      protected

      # === Abstract Adapter (Misc Support) =========================== #

        def extract_limit(sql_type)
          case sql_type
            when /^tinyint/i
              1
            when /^smallint/i
              2
            when /^integer/i
              4
            when /^bigint/i
              8
            else super
          end
        end

        def initialize_type_map(m) # :nodoc:
          m.register_type %r(boolean)i,         Type::Boolean.new
          m.alias_type    %r(tinyint)i,         'boolean'
          m.alias_type    %r(bit)i,             'boolean'

          m.register_type %r(char)i,            Type::String.new
          m.alias_type    %r(varchar)i,         'char'
          m.alias_type    %r(xml)i,             'char'

          m.register_type %r(binary)i,            Type::Binary.new
          m.alias_type    %r(long binary)i,       'binary'
          m.alias_type    %r(uniqueidentifier)i,  'binary'

          m.register_type %r(text)i,            Type::Text.new
          m.alias_type    %r(long varchar)i,    'text'

          m.register_type %r(date)i,              Type::Date.new
          m.register_type %r(time)i,              Type::Time.new
          m.register_type %r(timestamp)i,         Type::DateTime.new
          m.register_type %r(datetime)i,          Type::DateTime.new

          m.register_type %r(int)i,               Type::Integer.new
          m.alias_type    %r(smallint)i,          'int'
          m.alias_type    %r(bigint)i,            'int'

          #register_class_with_limit m, %r(tinyint)i,          Type::Boolean
          #register_class_with_limit m, %r(bit)i,              Type::Boolean
          #register_class_with_limit m, %r(long varchar)i,     Type::Text
          #register_class_with_limit m, %r(varchar)i,          Type::String
          #register_class_with_limit m, %r(timestamp)i,        Type::DateTime
          #register_class_with_limit m, %r(smallint|bigint)i,  Type::Integer
          #register_class_with_limit m, %r(xml)i,              Type::String
          #register_class_with_limit m, %r(uniqueidentifier)i, Type::Integer
          #register_class_with_limit m, %r(long binary)i,      Type::Binary

          super
        end

        def select(sql, name = nil, binds = []) #:nodoc:
           exec_query(sql, name, binds)
        end

        # Queries the structure of a table including the columns names, defaults, type, and nullability
        # ActiveRecord uses the type to parse scale and precision information out of the types. As a result,
        # chars, varchars, binary, nchars, nvarchars must all be returned in the form <i>type</i>(<i>width</i>)
        # numeric and decimal must be returned in the form <i>type</i>(<i>width</i>, <i>scale</i>)
        # Nullability is returned as 0 (no nulls allowed) or 1 (nulls allowed)
        # Also, ActiveRecord expects an autoincrement column to have default value of NULL
        # Owner support
        def table_structure(table_name)
          table_name_parts = table_name.split(".")
          sql = <<-SQL
            SELECT
              SYS.SYSCOLUMN.column_name AS name,
              if left("default",1)='''' then
                substring("default", 2, length("default")-2)
              else
                NULLIF(SYS.SYSCOLUMN."default", 'autoincrement')
              endif AS "default",
              IF SYS.SYSCOLUMN.domain_id IN (7,8,9,11,33,34,35,3,27) THEN
                IF SYS.SYSCOLUMN.domain_id IN (3,27) THEN
                  SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ',' || SYS.SYSCOLUMN.scale || ')'
                ELSE
                  SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ')'
                ENDIF
              ELSE
                SYS.SYSDOMAIN.domain_name
              ENDIF AS domain,
              IF SYS.SYSCOLUMN.nulls = 'Y' THEN 1 ELSE 0 ENDIF AS nulls
            FROM
              SYS.SYSCOLUMN
            INNER JOIN SYS.SYSTABLE ON SYS.SYSCOLUMN.table_id = SYS.SYSTABLE.table_id
            INNER JOIN  SYS.SYSDOMAIN ON SYS.SYSCOLUMN.domain_id = SYS.SYSDOMAIN.domain_id
            WHERE
              table_name = '#{table_name_parts.last}'
            AND SYS.SYSTABLE.creator = (
              SELECT user_id FROM SYS.SYSUSER WHERE SYS.SYSUSER.user_name = '#{table_name_parts.first}'
            )
          SQL
          structure = exec_query(sql, "SCHEMA").to_hash

          structure.map do |column|
            if String === column["default"]
              # Escape the hexadecimal characters.
              # For example, a column default with a new line might look like 'foo\x0Abar'.
              # After the gsub it will look like 'foo\nbar'.
              column["default"].gsub!(/\\x(\h{2})/) {$1.hex.chr}
            end
            column
          end
          raise(ActiveRecord::StatementInvalid, "Could not find table '#{table_name}'") if structure == false
          structure
        end

      private

        def connect!
          result = SA.instance.api.sqlany_connect(@connection, @connection_string)
          if result == 1 then
            set_connection_options
          else
            error = SA.instance.api.sqlany_error(@connection)
            if error[1] == "Specified database not found"
              raise ActiveRecord::NoDatabaseError
            else
              raise ActiveRecord::ActiveRecordError.new("#{error}: Cannot Establish Connection")
            end
          end
        end

        def set_connection_options
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION non_keywords = 'LOGIN'") rescue nil
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION timestamp_format = 'YYYY-MM-DD HH:NN:SS'") rescue nil
          #SA.instance.api.sqlany_execute_immediate(@connection, "SET OPTION reserved_keywords = 'LIMIT'") rescue nil
          # The liveness variable is used a low-cost "no-op" to test liveness
          SA.instance.api.sqlany_execute_immediate(@connection, "CREATE VARIABLE liveness INT") rescue nil
        end

      def exec_query sql, name = nil, binds = [], prepare = false
        log(sql, name, binds, type_casted_binds(binds)) do
          _exec_query sql, name, binds, prepare
        end
      end

      def _exec_query(sql, name, binds, prepare)
        stmt = SA.instance.api.sqlany_prepare(@connection, sql)
        sqlanywhere_error_test(sql) if stmt==nil

        begin
          binds.each_with_index do |bind, i|
            bind_value = type_cast(bind.value_for_database)
            result, bind_param = SA.instance.api.sqlany_describe_bind_param(stmt, i)
            sqlanywhere_error_test(sql) if result==0
            bind_param.set_direction(1) # https://github.com/sqlanywhere/sqlanywhere/blob/master/ext/sacapi.h#L175
            if bind_value.nil?
              bind_param.set_value(nil)
            else
              bind_param.set_value(bind_value)
            end
            # Just could not get binary data to work as a bind parameter even when using the correct format
            # by escaping the data as per comments in quoting.rb:
            # SQL Anywhere requires that binary values be encoded as \xHH, where HH is a hexadecimal number
            # It ALWAYS treated the value as a string no matter what I tried. I added -zr all -zo reqlog.txt
            # option to my server to log exactly what SQLA was processing. I think the reason is that the set_value
            # method receives the value as a string and then sets the type as a string so SQLA then treats whatever
            # we pass in as a string.
            #
            # To fix this problem I've had to modify a fork of sqlanywhere gem working on branch ruby22. I modified
            # the code to allow me to get/set the bind param. This allowed me to override the type set by set_value
            # before I bound the param to the statement, see code below. Setting the type means we pass in the binary
            # data as is without encoding the value at all (see quoting.rb)
            #
            # The problem with this approach is that it binds this gem to a particular branch of sqlanywhere.
            #
            if bind.value_for_database.class == Type::Binary::Data
              bind_param.set_type(1)
            end
            result = SA.instance.api.sqlany_bind_param(stmt, i, bind_param)
            sqlanywhere_error_test(sql) if result==0
          end

          if SA.instance.api.sqlany_execute(stmt) == 0
            sqlanywhere_error_test(sql)
          end

          fields = []
          native_types = []

          num_cols = SA.instance.api.sqlany_num_cols(stmt)
          sqlanywhere_error_test(sql) if num_cols == -1

          for i in 0...num_cols
            result, col_num, name, ruby_type, native_type, precision, scale, max_size, nullable = SA.instance.api.sqlany_get_column_info(stmt, i)
            sqlanywhere_error_test(sql) if result==0
            fields << name
            native_types << native_type
          end
          rows = []
          while SA.instance.api.sqlany_fetch_next(stmt) == 1
            row = []
            for i in 0...num_cols
              r, value = SA.instance.api.sqlany_get_column(stmt, i)
              row << native_type_to_ruby_type(native_types[i], value)
            end
            rows << row
          end
          @affected_rows = SA.instance.api.sqlany_affected_rows(stmt)
          sqlanywhere_error_test(sql) if @affected_rows==-1
        rescue StandardError => e
          @affected_rows = 0
          SA.instance.api.sqlany_rollback @connection
          raise e
        ensure
          SA.instance.api.sqlany_free_stmt(stmt)
          SA.instance.api.sqlany_commit(@connection) if @auto_commit
        end

        ActiveRecord::Result.new(fields, rows)
      end

      def exec_delete(sql, name = 'SQL', binds = [])
        exec_query(sql, name, binds)
        @affected_rows
      end
      alias :exec_update :exec_delete

        # convert sqlany type to ruby type
        # the types are taken from here
        # http://dcx.sybase.com/1101/en/dbprogramming_en11/pg-c-api-native-type-enum.html
        def native_type_to_ruby_type(native_type, value)
          return nil if value.nil?
          case native_type
          when 484 # DT_DECIMAL (also and more importantly numeric)
            BigDecimal.new(value)
          when 448,452,456,460,640  # DT_VARCHAR, DT_FIXCHAR, DT_LONGVARCHAR, DT_STRING, DT_LONGNVARCHAR
            value.force_encoding(ActiveRecord::Base.connection_config['encoding'] || "UTF-8")
          else
            value
          end
        end
    end
  end
end
