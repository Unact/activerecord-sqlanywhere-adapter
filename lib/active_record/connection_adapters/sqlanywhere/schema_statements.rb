module ActiveRecord
  module ConnectionAdapters
    module SQLAnywhere
      module SchemaStatements
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
              SYS.SYSTABLE.creator NOT IN (
                SELECT SYSUSER.user_id FROM SYS.SYSUSER WHERE SYS.SYSUSER.user_name in ('SYS','rs_systabgroup')
              ) AND
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
              SYS.SYSTAB.creator NOT IN (
                SELECT SYSUSER.user_id FROM SYS.SYSUSER WHERE SYS.SYSUSER.user_name in ('SYS','rs_systabgroup')
              ) AND
              SYS.SYSTAB.server_type = 1
          SQL
          exec_query(sql, 'SCHEMA').map { |row| row["table_name"] }
        end

        def new_column_from_field table_name, field
          type_metadata = fetch_type_metadata(field['domain'])

          # numerics and string literals are default
          if  /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/.match?(field['default']) ||
              /^'.*'$/.match?(field['default']) ||
              field['default'].nil?
          then
            default, default_function = field['default'], nil
          else
            default, default_function = nil, field['default'].upcase
          end

          SQLAnywhereColumn.new(
            field['name'],
            default,
            type_metadata,
            (field['nulls'] == 1),
            table_name,
            default_function
          )
        end

        def indexes(table_name, name = nil) #:nodoc:
          owner, name = extract_owner_qualified_name(table_name)

          sql = <<-SQL
            SELECT DISTINCT index_name, \"unique\"
            FROM SYS.SYSTABLE
            INNER JOIN SYS.SYSIDXCOL ON SYS.SYSTABLE.table_id = SYS.SYSIDXCOL.table_id
            INNER JOIN SYS.SYSIDX ON SYS.SYSTABLE.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id
            WHERE
              SYS.SYSTABLE.table_name = '#{name}' AND
              index_category > 2 AND
              SYS.SYSTABLE.creator = (
                SELECT user_id FROM SYS.SYSUSER WHERE SYS.SYSUSER.user_name = '#{owner}'
              )
          SQL

          exec_query(sql, name).map do |row|
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

            IndexDefinition.new(
              table_name,
              row['index_name'],
              row['unique'] == 1,
              exec_query(sql, name).map { |col| col['column_name'] }
            )
          end
        end

        def primary_key(table_name) #:nodoc:
          owner, name = extract_owner_qualified_name(table_name)
          sql = <<-SQL
            select cname
            from SYS.SYSCOLUMNS
            where tname = '#{name}'
              and creator = '#{owner}'
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
          owner, name = extract_owner_qualified_name(table_name)
          # SQL to get primary keys for a table
          sql = "SELECT list(c.column_name order by ixc.sequence) as pk_columns
            from SYSIDX ix, SYSTABLE t, SYSIDXCOL ixc, SYSCOLUMN c
            where ix.table_id = t.table_id
              and ixc.table_id = t.table_id
              and ixc.index_id = ix.index_id
              and ixc.table_id = c.table_id
              and ixc.column_id = c.column_id
              and ix.index_category in (1,2)
              and t.table_name = '#{name}'
              and t.creator = (SELECT user_id FROM SYS.SYSUSER WHERE SYS.SYSUSER.user_name = '#{owner}')
            group by ix.index_name, ix.index_id, ix.index_category
            order by ix.index_id"
          pks = exec_query(sql, "SCHEMA").to_hash.first
          if pks['pk_columns']
            pks['pk_columns'].split(',')
          else
            nil
          end
        end

        def foreign_keys(table_name)
          owner, name = extract_owner_qualified_name(table_name)

          # Don't support compound fk
          fk_info = exec_query(<<~SQL, "SCHEMA")
             select
                '"' + user_name(systab_p.creator) + '"."' + systab_p.table_name + '"' to_table,
                systabcol_p.column_name primary_key,
                systabcol_f.column_name column,
                sysidx.index_name name,
                isnull(systrigger_c.referential_action, 'R') on_update,
                isnull(systrigger_d.referential_action, 'R') on_delete
            from
                sys.sysfkey
                    join sys.sysidxcol sysidxcol_f on sysidxcol_f.table_id = sysfkey.foreign_table_id
                                               and sysidxcol_f.index_id = sysfkey.foreign_index_id
                    join sys.sysidxcol sysidxcol_p on sysidxcol_p.table_id = sysfkey.primary_table_id
                                               and sysidxcol_p.index_id = sysfkey.primary_index_id
                    join sys.systable systab_f on systab_f.table_id = sysidxcol_f.table_id
                    join sys.systable systab_p on systab_p.table_id = sysidxcol_p.table_id
                    join sys.systabcol systabcol_f on  systabcol_f.table_id  = sysidxcol_f.table_id
                                               and systabcol_f.column_id = sysidxcol_f.column_id
                    join sys.systabcol systabcol_p on  systabcol_p.table_id  = sysidxcol_p.table_id
                                               and systabcol_p.column_id = sysidxcol_p.column_id
                    join sys.sysidx on  sysidx.table_id = sysfkey.foreign_table_id
                                and sysidx.index_id = sysfkey.foreign_index_id
                    left outer join sys.systrigger systrigger_c  on  systrigger_c.table_id = sysfkey.primary_table_id
                                                             and systrigger_c.foreign_table_id = sysfkey.foreign_table_id
                                                             and systrigger_c.foreign_key_id = sysfkey.foreign_index_id
                                                             and systrigger_c.event = 'C'
                    left outer join sys.systrigger systrigger_d  on  systrigger_d.table_id = sysfkey.primary_table_id
                                                             and systrigger_d.foreign_table_id = sysfkey.foreign_table_id
                                                             and systrigger_d.foreign_key_id = sysfkey.foreign_index_id
                                                             and systrigger_d.event = 'D'
            where
                        sysidxcol_f.primary_column_id = sysidxcol_p.column_id
                    and systab_f.table_name = '#{name}'
                    and systab_f.creator = (select user_id from sys.sysuser where sys.sysuser.user_name = '#{owner}')
                    and (select count(*) from sysidxcol where sysidxcol.table_id = sysfkey.foreign_table_id and sysidxcol.index_id = sysfkey.foreign_index_id) = 1
          SQL

          fk_info.map do |row|
            options = {
              column: row["column"],
              name: row["name"],
              primary_key: row["primary_key"]
            }

            options[:on_update] = extract_foreign_key_action(row["on_update"])
            options[:on_delete] = extract_foreign_key_action(row["on_delete"])

            ForeignKeyDefinition.new(table_name, row["to_table"], options)
          end
        end

        def create_schema_dumper(options) # :nodoc:
          SQLAnywhere::SchemaDumper.create(self, options)
        end

        private

          # http://dcx.sap.com/index.html#sa160/en/dbreference/systrigger-system-view.html
          def extract_foreign_key_action(specifier)
            case specifier
            when "C"; :cascade
            when "D"; :default
            when "N"; :nullify
            when "R"; :restrict
            end
          end

          def schema_creation
            SQLAnywhere::SchemaCreation.new(self)
          end
      end
    end
  end
end
