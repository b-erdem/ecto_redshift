if Code.ensure_loaded?(Postgrex) do
  defmodule Ecto.Adapters.Redshift.Connection do
    @moduledoc false

    @behaviour Ecto.Adapters.SQL.Connection

    alias Ecto.Adapters.Postgres.Connection, as: Postgres
    alias Ecto.Migration.{Constraint, Index, Reference, Table}
    alias Ecto.Query.JoinExpr

    @creates [:create, :create_if_not_exists]
    @drops [:drop, :drop_if_exists]
    @default_port 5439

    @compression_encodings [
      :az64,
      :bytedict,
      :delta,
      :delta32k,
      :lzo,
      :mostly8,
      :mostly16,
      :mostly32,
      :raw,
      :runlength,
      :text255,
      :text32k,
      :zstd
    ]

    @table_diststyles [:auto, :even, :all, :key]

    @impl true
    def child_spec(opts) do
      opts
      |> Keyword.put_new(:port, @default_port)
      |> Keyword.put_new(:prepare, :unnamed)
      |> Postgrex.child_spec()
    end

    @impl true
    def to_constraints(_exception, _opts) do
      []
    end

    @impl true
    def prepare_execute(conn, name, sql, params, opts) do
      Postgres.prepare_execute(conn, name, sql, params, opts)
    end

    @impl true
    def query(conn, sql, params, opts) do
      Postgres.query(conn, sql, params, opts)
    end

    @impl true
    def query_many(conn, sql, params, opts) do
      Postgres.query_many(conn, sql, params, opts)
    end

    @impl true
    def execute(conn, query, params, opts) do
      Postgres.execute(conn, query, params, opts)
    end

    @impl true
    def stream(conn, sql, params, opts) do
      Postgres.stream(conn, sql, params, opts)
    end

    @impl true
    def all(query) do
      Postgres.all(query, [])
    end

    @impl true
    def update_all(query) do
      validate_mutation_query!(query, :update_all)
      Postgres.update_all(query)
    end

    @impl true
    def delete_all(query) do
      validate_mutation_query!(query, :delete_all)
      Postgres.delete_all(query)
    end

    @impl true
    def insert(_prefix, _table, _header, _rows, _on_conflict, returning, _placeholders)
        when returning != [] do
      raise ArgumentError, "Amazon Redshift does not support RETURNING clauses"
    end

    def insert(_prefix, _table, _header, _rows, on_conflict, _returning, _placeholders)
        when on_conflict != {:raise, [], []} do
      raise ArgumentError,
            "Amazon Redshift upserts are not implemented yet for Ecto.Adapters.Redshift"
    end

    def insert(prefix, table, header, rows, {:raise, _, []}, [], placeholders) do
      Postgres.insert(prefix, table, header, rows, {:raise, [], []}, [], placeholders)
    end

    @impl true
    def update(_prefix, _table, _fields, _filters, returning) when returning != [] do
      raise ArgumentError, "Amazon Redshift does not support RETURNING clauses"
    end

    def update(prefix, table, fields, filters, []) do
      {fields, count} =
        intersperse_reduce(fields, ", ", 1, fn field, acc ->
          {[quote_name(field), " = $" | Integer.to_string(acc)], acc + 1}
        end)

      {filters, _count} =
        intersperse_reduce(filters, " AND ", count, fn
          {field, nil}, acc ->
            {[quote_name(field), " IS NULL"], acc}

          {field, _value}, acc ->
            {[quote_name(field), " = $" | Integer.to_string(acc)], acc + 1}
        end)

      ["UPDATE ", quote_name(prefix, table), " SET ", fields, " WHERE ", filters]
    end

    @impl true
    def delete(_prefix, _table, _filters, returning) when returning != [] do
      raise ArgumentError, "Amazon Redshift does not support RETURNING clauses"
    end

    def delete(prefix, table, filters, []) do
      {filters, _count} =
        intersperse_reduce(filters, " AND ", 1, fn
          {field, nil}, acc ->
            {[quote_name(field), " IS NULL"], acc}

          {field, _value}, acc ->
            {[quote_name(field), " = $" | Integer.to_string(acc)], acc + 1}
        end)

      ["DELETE FROM ", quote_name(prefix, table), " WHERE ", filters]
    end

    @impl true
    def explain_query(conn, query, params, opts) do
      Postgres.explain_query(conn, query, params, opts)
    end

    @impl true
    def execute_ddl({command, %Table{} = table, columns}) when command in @creates do
      table_name = quote_name(table.prefix, table.name)

      query = [
        "CREATE TABLE ",
        if_do(command == :create_if_not_exists, "IF NOT EXISTS "),
        table_name,
        ?\s,
        ?(,
        column_definitions(table, columns),
        pk_definition(columns, ", "),
        ?),
        table_options_expr(table.options)
      ]

      [query] ++
        comments_on("TABLE", table_name, table.comment) ++
        comments_for_columns(table_name, columns)
    end

    def execute_ddl({command, %Table{} = table, mode}) when command in @drops do
      [
        [
          "DROP TABLE ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_name(table.prefix, table.name),
          drop_mode(mode)
        ]
      ]
    end

    def execute_ddl({:alter, %Table{} = table, changes}) do
      table_name = quote_name(table.prefix, table.name)

      change_queries =
        Enum.flat_map(changes, fn change ->
          Enum.map(column_change_queries(table, change), fn clause ->
            ["ALTER TABLE ", table_name, ?\s, clause]
          end)
        end)

      change_queries ++
        comments_on("TABLE", table_name, table.comment) ++
        comments_for_columns(table_name, changes)
    end

    def execute_ddl({command, %Index{}, _mode}) when command in @drops do
      error!(nil, "Amazon Redshift does not support indexes")
    end

    def execute_ddl({command, %Index{}}) when command in @creates do
      error!(nil, "Amazon Redshift does not support indexes")
    end

    def execute_ddl({:rename, %Index{}, _new_name}) do
      error!(nil, "Amazon Redshift does not support indexes")
    end

    def execute_ddl({:rename, %Table{} = current_table, %Table{} = new_table}) do
      [
        [
          "ALTER TABLE ",
          quote_name(current_table.prefix, current_table.name),
          " RENAME TO ",
          quote_name(new_table.name)
        ]
      ]
    end

    def execute_ddl({:rename, %Table{} = table, current_column, new_column}) do
      [
        [
          "ALTER TABLE ",
          quote_name(table.prefix, table.name),
          " RENAME COLUMN ",
          quote_name(current_column),
          " TO ",
          quote_name(new_column)
        ]
      ]
    end

    def execute_ddl({:create, %Constraint{}}) do
      error!(nil, "CHECK and EXCLUDE constraints are not supported by Amazon Redshift")
    end

    def execute_ddl({command, %Constraint{} = constraint, mode}) when command in @drops do
      [
        [
          "ALTER TABLE ",
          quote_name(constraint.prefix, constraint.table),
          " DROP CONSTRAINT ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_name(constraint.name),
          drop_mode(mode)
        ]
      ]
    end

    def execute_ddl(string) when is_binary(string), do: [string]

    def execute_ddl(keyword) when is_list(keyword) do
      error!(nil, "Redshift adapter does not support keyword lists in execute")
    end

    @impl true
    def ddl_logs(result) do
      Postgres.ddl_logs(result)
    end

    @impl true
    def table_exists_query(table) do
      Postgres.table_exists_query(table)
    end

    defp pk_definition(columns, prefix) do
      pks =
        for {action, name, _, opts} <- columns,
            action != :remove,
            opts[:primary_key],
            do: name

      case pks do
        [] -> []
        _ -> [prefix, "PRIMARY KEY (", quote_names(pks), ")"]
      end
    end

    defp comments_on(_object, _name, nil), do: []

    defp comments_on(object, name, comment) do
      [["COMMENT ON ", object, ?\s, name, " IS ", single_quote(comment)]]
    end

    defp comments_for_columns(table_name, columns) do
      Enum.flat_map(columns, fn
        {:remove, _column_name} ->
          []

        {:remove, _column_name, _column_type, _opts} ->
          []

        {:remove_if_exists, _column_name} ->
          []

        {:remove_if_exists, _column_name, _column_type} ->
          []

        {_operation, column_name, _column_type, opts} ->
          column_name = [table_name, ?. | quote_name(column_name)]
          comments_on("COLUMN", column_name, opts[:comment])

        _ ->
          []
      end)
    end

    defp column_definitions(table, columns) do
      Enum.map_intersperse(columns, ", ", &column_definition(table, &1))
    end

    defp column_definition(table, {:add, name, %Reference{} = ref, opts}) do
      [
        quote_name(name),
        ?\s,
        reference_column_type(ref.type, opts, :create),
        column_options(ref.type, opts, :create),
        ", ",
        reference_expr(ref, table, name)
      ]
    end

    defp column_definition(_table, {:add, name, type, opts}) do
      [
        quote_name(name),
        ?\s,
        column_type(type, opts, :create),
        column_options(type, opts, :create)
      ]
    end

    defp column_change_queries(_table, {:add, _name, %Reference{}, _opts}) do
      error!(nil, "ALTER TABLE ADD COLUMN with references is not supported by Amazon Redshift")
    end

    defp column_change_queries(_table, {:add, name, type, opts}) do
      validate_alter_add!(type, opts)

      [
        [
          "ADD COLUMN ",
          quote_name(name),
          ?\s,
          column_type(type, opts, :alter_add),
          alter_add_options(type, opts)
        ]
      ]
    end

    defp column_change_queries(_table, {:add_if_not_exists, _name, %Reference{}, _opts}) do
      error!(nil, "ALTER TABLE ADD COLUMN with references is not supported by Amazon Redshift")
    end

    defp column_change_queries(_table, {:add_if_not_exists, name, type, opts}) do
      validate_alter_add!(type, opts)

      [
        [
          "ADD COLUMN IF NOT EXISTS ",
          quote_name(name),
          ?\s,
          column_type(type, opts, :alter_add),
          alter_add_options(type, opts)
        ]
      ]
    end

    defp column_change_queries(_table, {:modify, _name, %Reference{}, _opts}) do
      error!(nil, "ALTER TABLE MODIFY for references is not supported by Amazon Redshift")
    end

    defp column_change_queries(_table, {:modify, name, type, opts}) do
      validate_modify!(type, opts)

      queries =
        []
        |> maybe_add_type_change(name, type, opts)
        |> maybe_add_encode_change(name, opts)

      if queries == [] do
        error!(nil, "Redshift supports only limited ALTER COLUMN operations")
      else
        queries
      end
    end

    defp column_change_queries(_table, {:remove, name}) do
      [["DROP COLUMN ", quote_name(name)]]
    end

    defp column_change_queries(_table, {:remove, name, _type, _opts}) do
      [["DROP COLUMN ", quote_name(name)]]
    end

    defp column_change_queries(_table, {:remove_if_exists, name}) do
      [["DROP COLUMN IF EXISTS ", quote_name(name)]]
    end

    defp column_change_queries(_table, {:remove_if_exists, name, _type}) do
      [["DROP COLUMN IF EXISTS ", quote_name(name)]]
    end

    defp maybe_add_type_change(queries, name, type, opts) do
      if alterable_varchar_type?(type, opts) do
        queries ++ [["ALTER COLUMN ", quote_name(name), " TYPE ", column_type_name(type, opts)]]
      else
        queries
      end
    end

    defp maybe_add_encode_change(queries, name, opts) do
      case Keyword.get(opts, :encode) do
        nil ->
          queries

        encoding ->
          queries ++ [["ALTER COLUMN ", quote_name(name), " ENCODE ", encoding_name(encoding)]]
      end
    end

    defp validate_alter_add!(type, opts) do
      forbidden =
        opts
        |> Keyword.drop([:default, :null, :encode, :comment, :collation])
        |> Enum.reject(fn
          {_key, nil} -> true
          {_key, false} -> true
          _ -> false
        end)

      cond do
        type == :identity ->
          error!(
            nil,
            "ALTER TABLE ADD COLUMN does not support identity columns in Amazon Redshift"
          )

        forbidden != [] ->
          keys = forbidden |> Keyword.keys() |> Enum.sort()
          error!(nil, "unsupported ALTER TABLE ADD COLUMN options for Redshift: #{inspect(keys)}")

        true ->
          :ok
      end
    end

    defp validate_modify!(type, opts) do
      allowed_keys = [:size, :encode, :comment, :from]

      unsupported =
        opts
        |> Keyword.drop(allowed_keys)
        |> Enum.reject(fn
          {_key, nil} -> true
          {_key, false} -> true
          _ -> false
        end)

      if unsupported != [] do
        keys = unsupported |> Keyword.keys() |> Enum.sort()
        error!(nil, "unsupported ALTER COLUMN options for Redshift: #{inspect(keys)}")
      end

      if Keyword.has_key?(opts, :size) and not alterable_varchar_type?(type, opts) do
        error!(nil, "Redshift ALTER COLUMN TYPE only supports VARCHAR size changes")
      end

      :ok
    end

    defp alterable_varchar_type?(type, opts) do
      Keyword.has_key?(opts, :size) and type in [:string, :varchar, :"character varying"]
    end

    defp alter_add_options(type, opts) do
      [
        default_expr(Keyword.fetch(opts, :default), type),
        encode_expr(Keyword.get(opts, :encode)),
        collation_expr(Keyword.get(opts, :collation)),
        null_expr(Keyword.get(opts, :null))
      ]
    end

    defp column_options(type, opts, :create) do
      [
        default_expr(Keyword.fetch(opts, :default), type),
        encode_expr(Keyword.get(opts, :encode)),
        distkey_expr(Keyword.get(opts, :distkey)),
        sortkey_expr(Keyword.get(opts, :sortkey)),
        collation_expr(Keyword.get(opts, :collation)),
        null_expr(Keyword.get(opts, :null)),
        unique_expr(Keyword.get(opts, :unique))
      ]
    end

    defp column_type(type, opts, :create) do
      type_name = column_type_name(type, opts)

      cond do
        type == :identity ->
          generated_identity_expr(type_name, opts)

        identity = Keyword.get(opts, :identity) ->
          [type_name, identity_expr(identity)]

        generated = Keyword.get(opts, :generated) ->
          [type_name, " GENERATED ", generated]

        true ->
          type_name
      end
    end

    defp column_type(type, opts, :alter_add) do
      type_name = column_type_name(type, opts)

      if generated = Keyword.get(opts, :generated) do
        [type_name, " GENERATED ", generated]
      else
        type_name
      end
    end

    defp reference_expr(%Reference{} = ref, table, name) do
      validate_reference_options!(ref)
      {current_columns, reference_columns} = Enum.unzip([{name, ref.column} | ref.with])

      [
        "CONSTRAINT ",
        reference_name(ref, table, name),
        ?\s,
        "FOREIGN KEY (",
        quote_names(current_columns),
        ") REFERENCES ",
        quote_name(Keyword.get(ref.options, :prefix, table.prefix), ref.table),
        ?(,
        quote_names(reference_columns),
        ?)
      ]
    end

    defp validate_reference_options!(%Reference{on_delete: :nothing, on_update: :nothing}),
      do: :ok

    defp validate_reference_options!(%Reference{on_delete: :nothing}) do
      error!(nil, "ON UPDATE actions are not supported by Amazon Redshift references")
    end

    defp validate_reference_options!(%Reference{}) do
      error!(nil, "ON DELETE actions are not supported by Amazon Redshift references")
    end

    defp reference_name(%Reference{name: nil}, table, column) do
      quote_name("#{table.name}_#{column}_fkey")
    end

    defp reference_name(%Reference{name: name}, _table, _column) do
      quote_name(name)
    end

    defp reference_column_type(type, opts, context) do
      column_type(type, opts, context)
    end

    defp generated_identity_expr(type_name, opts) do
      start_value = Keyword.get(opts, :start_value)
      increment = Keyword.get(opts, :increment)

      sequence =
        []
        |> maybe_add_identity_part("START", start_value)
        |> maybe_add_identity_part("INCREMENT", increment)

      case sequence do
        [] ->
          [type_name, " GENERATED BY DEFAULT AS IDENTITY"]

        _ ->
          [type_name, " GENERATED BY DEFAULT AS IDENTITY(", Enum.join(sequence, " "), ")"]
      end
    end

    defp maybe_add_identity_part(parts, _prefix, nil), do: parts
    defp maybe_add_identity_part(parts, prefix, value), do: parts ++ ["#{prefix} #{value}"]

    defp validate_mutation_query!(query, kind) do
      validate_no_mutation_returning!(query, kind)
      validate_mutation_joins!(query, kind)
    end

    defp validate_no_mutation_returning!(%{select: nil}, _kind), do: :ok

    defp validate_no_mutation_returning!(query, kind) do
      error!(query, "Amazon Redshift does not support RETURNING clauses in #{kind}")
    end

    defp validate_mutation_joins!(%{joins: joins} = query, kind) do
      Enum.each(joins, fn
        %JoinExpr{qual: :inner} ->
          :ok

        %JoinExpr{qual: qual} ->
          error!(query, "Amazon Redshift supports only inner joins in #{kind}, got: `#{qual}`")
      end)
    end

    defp identity_expr({seed, step}) when is_integer(seed) and is_integer(step) do
      [" IDENTITY(", to_string(seed), ",", to_string(step), ")"]
    end

    defp identity_expr(other) do
      error!(nil, "expected :identity to be a {seed, step} tuple, got: #{inspect(other)}")
    end

    defp table_options_expr(nil), do: []

    defp table_options_expr(options) when is_binary(options) do
      [?\s, options]
    end

    defp table_options_expr(options) when is_list(options) do
      validate_table_options!(options)

      backup = backup_expr(Keyword.get(options, :backup))
      diststyle = diststyle_expr(Keyword.get(options, :diststyle))
      distkey = table_distkey_expr(Keyword.get(options, :distkey))
      sortkey = table_sortkey_expr(Keyword.get(options, :sortkey))
      encode = table_encode_expr(options)

      [backup, diststyle, distkey, sortkey, encode]
    end

    defp validate_table_options!(options) do
      supported = [:backup, :diststyle, :distkey, :sortkey, :encode, :encode_auto]

      unsupported =
        options
        |> Keyword.keys()
        |> Enum.uniq()
        |> Enum.reject(&(&1 in supported))

      if unsupported != [] do
        error!(nil, "unsupported Redshift table options: #{inspect(Enum.sort(unsupported))}")
      end
    end

    defp backup_expr(nil), do: []
    defp backup_expr(true), do: " BACKUP YES"
    defp backup_expr(false), do: " BACKUP NO"
    defp backup_expr(:yes), do: " BACKUP YES"
    defp backup_expr(:no), do: " BACKUP NO"

    defp backup_expr(other) do
      error!(nil, "unsupported Redshift table backup option: #{inspect(other)}")
    end

    defp diststyle_expr(nil), do: []

    defp diststyle_expr(style) when style in @table_diststyles do
      [" DISTSTYLE ", Atom.to_string(style) |> String.upcase()]
    end

    defp diststyle_expr(other) do
      error!(nil, "unsupported Redshift DISTSTYLE: #{inspect(other)}")
    end

    defp table_distkey_expr(nil), do: []

    defp table_distkey_expr(key) when is_atom(key) or is_binary(key) do
      [" DISTKEY(", quote_name(key), ?)]
    end

    defp table_distkey_expr(other) do
      error!(nil, "unsupported Redshift DISTKEY: #{inspect(other)}")
    end

    defp table_sortkey_expr(nil), do: []
    defp table_sortkey_expr(:auto), do: " SORTKEY AUTO"

    defp table_sortkey_expr({style, keys}) when style in [:compound, :interleaved] do
      [" ", Atom.to_string(style) |> String.upcase(), table_sortkey_expr(keys)]
    end

    defp table_sortkey_expr(key) when is_atom(key) or is_binary(key) do
      [" SORTKEY(", quote_name(key), ?)]
    end

    defp table_sortkey_expr(keys) when is_list(keys) do
      [" SORTKEY(", quote_names(keys), ?)]
    end

    defp table_sortkey_expr(other) do
      error!(nil, "unsupported Redshift SORTKEY: #{inspect(other)}")
    end

    defp table_encode_expr(options) do
      case {Keyword.get(options, :encode), Keyword.get(options, :encode_auto)} do
        {nil, nil} -> []
        {:auto, _} -> " ENCODE AUTO"
        {nil, true} -> " ENCODE AUTO"
        {other, _} -> error!(nil, "unsupported Redshift table ENCODE option: #{inspect(other)}")
      end
    end

    defp default_expr({:ok, nil}, _type), do: " DEFAULT NULL"
    defp default_expr({:ok, literal}, type), do: [" DEFAULT ", default_type(literal, type)]
    defp default_expr(:error, _type), do: []

    defp default_type(%{} = map, type) when type in [:map, :super, {:map, :any}] do
      encoded = encode_json(map)

      case type do
        :super -> ["JSON_PARSE(", single_quote(encoded), ")"]
        _ -> single_quote(encoded)
      end
    end

    defp default_type(list, :super) when is_list(list) do
      ["JSON_PARSE(", single_quote(encode_json(list)), ")"]
    end

    defp default_type(literal, :super)
         when is_binary(literal) or is_number(literal) or is_boolean(literal) do
      ["JSON_PARSE(", single_quote(encode_json(literal)), ")"]
    end

    defp default_type({:fragment, expr}, _type), do: [expr]

    defp default_type(literal, _type) when is_binary(literal) do
      single_quote(literal)
    end

    defp default_type(literal, _type)
         when is_integer(literal) or is_float(literal) or is_boolean(literal) do
      to_string(literal)
    end

    defp default_type(other, type) do
      raise ArgumentError,
            "unknown default #{inspect(other)} for Redshift type #{inspect(type)}"
    end

    defp encode_json(value) do
      Application.get_env(:postgrex, :json_library, Jason).encode!(value)
    end

    defp encode_expr(nil), do: []

    defp encode_expr(encoding) do
      [" ENCODE ", encoding_name(encoding)]
    end

    defp encoding_name(encoding) when encoding in @compression_encodings do
      Atom.to_string(encoding) |> String.upcase()
    end

    defp encoding_name(:auto) do
      error!(nil, "ENCODE AUTO is a table-level option in Amazon Redshift")
    end

    defp encoding_name(other) do
      error!(nil, "unsupported Redshift compression encoding: #{inspect(other)}")
    end

    defp distkey_expr(nil), do: []
    defp distkey_expr(false), do: []
    defp distkey_expr(true), do: " DISTKEY"

    defp distkey_expr(other) do
      error!(nil, "expected column :distkey to be true or false, got: #{inspect(other)}")
    end

    defp sortkey_expr(nil), do: []
    defp sortkey_expr(false), do: []
    defp sortkey_expr(true), do: " SORTKEY"

    defp sortkey_expr(other) do
      error!(nil, "expected column :sortkey to be true or false, got: #{inspect(other)}")
    end

    defp collation_expr(nil), do: []
    defp collation_expr(:case_sensitive), do: " COLLATE CASE_SENSITIVE"
    defp collation_expr(:cs), do: " COLLATE CS"
    defp collation_expr(:case_insensitive), do: " COLLATE CASE_INSENSITIVE"
    defp collation_expr(:ci), do: " COLLATE CI"

    defp collation_expr(value) when is_binary(value) do
      [" COLLATE ", value]
    end

    defp collation_expr(other) do
      error!(nil, "unsupported Redshift collation: #{inspect(other)}")
    end

    defp null_expr(false), do: " NOT NULL"
    defp null_expr(true), do: " NULL"
    defp null_expr(nil), do: []

    defp unique_expr(true), do: " UNIQUE"
    defp unique_expr(false), do: []
    defp unique_expr(nil), do: []

    defp unique_expr(other) do
      error!(nil, "expected column :unique to be true or false, got: #{inspect(other)}")
    end

    defp column_type_name(:time, _opts), do: "time"
    defp column_type_name(:time_usec, opts), do: temporal_type("time", opts)
    defp column_type_name(:utc_datetime, _opts), do: "timestamp"
    defp column_type_name(:utc_datetime_usec, opts), do: temporal_type("timestamp", opts)
    defp column_type_name(:naive_datetime, _opts), do: "timestamp"
    defp column_type_name(:naive_datetime_usec, opts), do: temporal_type("timestamp", opts)
    defp column_type_name(:duration, _opts), do: "interval"
    defp column_type_name(:id, _opts), do: "bigint"
    defp column_type_name(:identity, _opts), do: "bigint"
    defp column_type_name(:serial, _opts), do: "integer"
    defp column_type_name(:bigserial, _opts), do: "bigint"
    defp column_type_name(:binary_id, _opts), do: "char(36)"
    defp column_type_name(:uuid, _opts), do: "char(36)"
    defp column_type_name(:string, opts), do: sized_type("varchar", Keyword.get(opts, :size, 255))
    defp column_type_name(:map, _opts), do: "varchar(max)"
    defp column_type_name({:map, _}, _opts), do: "varchar(max)"
    defp column_type_name(:super, _opts), do: "super"
    defp column_type_name(:varbyte, opts), do: sized_type("varbyte", Keyword.get(opts, :size))

    defp column_type_name({:array, _type}, _opts) do
      error!(nil, "Amazon Redshift does not support array column types")
    end

    defp column_type_name(:binary, _opts) do
      error!(
        nil,
        "Amazon Redshift binary columns are not wired yet; use :varbyte explicitly if needed"
      )
    end

    defp column_type_name(type, opts) do
      size = Keyword.get(opts, :size)
      precision = Keyword.get(opts, :precision)
      scale = Keyword.get(opts, :scale)
      type_name = atom_or_string_type(type)

      cond do
        size ->
          sized_type(type_name, size)

        precision ->
          [type_name, ?(, to_string(precision), ?,, to_string(scale || 0), ?)]

        true ->
          type_name
      end
    end

    defp temporal_type(base, opts) do
      case Keyword.get(opts, :precision) do
        nil -> base
        precision -> [base, ?(, to_string(precision), ?)]
      end
    end

    defp sized_type(base, :max), do: [base, "(MAX)"]
    defp sized_type(base, "max"), do: [base, "(MAX)"]
    defp sized_type(base, size), do: [base, ?(, to_string(size), ?)]

    defp atom_or_string_type(type) when is_atom(type), do: Atom.to_string(type)
    defp atom_or_string_type(type) when is_binary(type), do: type

    defp drop_mode(:cascade), do: " CASCADE"
    defp drop_mode(:restrict), do: []

    defp quote_names(names) do
      Enum.map_intersperse(names, ",", &quote_name/1)
    end

    defp quote_name(nil, name), do: quote_name(name)
    defp quote_name(prefix, name), do: [quote_name(prefix), ?., quote_name(name)]

    defp quote_name(name) when is_atom(name) do
      quote_name(Atom.to_string(name))
    end

    defp quote_name(name) when is_binary(name) do
      if String.contains?(name, "\"") do
        error!(nil, "bad identifier #{inspect(name)}")
      end

      [?", name, ?"]
    end

    defp single_quote(value) when is_binary(value) do
      [?', escape_string(value), ?']
    end

    defp if_do(true, value), do: value
    defp if_do(false, _value), do: []

    defp escape_string(value) when is_binary(value) do
      :binary.replace(value, "'", "''", [:global])
    end

    defp intersperse_reduce(list, separator, user_acc, reducer, acc \\ [])

    defp intersperse_reduce([], _separator, user_acc, _reducer, acc) do
      {acc, user_acc}
    end

    defp intersperse_reduce([elem], _separator, user_acc, reducer, acc) do
      {elem, next_acc} = reducer.(elem, user_acc)
      {[acc | elem], next_acc}
    end

    defp intersperse_reduce([elem | rest], separator, user_acc, reducer, acc) do
      {elem, next_acc} = reducer.(elem, user_acc)
      intersperse_reduce(rest, separator, next_acc, reducer, [acc, elem, separator])
    end

    defp error!(nil, message) do
      raise ArgumentError, message
    end

    defp error!(query, message) do
      raise Ecto.QueryError, query: query, message: message
    end
  end
end
