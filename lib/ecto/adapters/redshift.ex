defmodule Ecto.Adapters.Redshift do
  @moduledoc """
  Ecto SQL adapter for [Amazon Redshift](https://aws.amazon.com/redshift/),
  built on [Postgrex](https://hex.pm/packages/postgrex).

  Redshift is treated as a Redshift-first OLAP engine with PostgreSQL
  ancestry, **not** as a drop-in PostgreSQL clone. Features that Redshift
  does not support are rejected with a clear error instead of silently
  producing broken SQL.

  ## Usage

      # lib/my_app/repo.ex
      defmodule MyApp.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: Ecto.Adapters.Redshift
      end

      # config/runtime.exs
      config :my_app, MyApp.Repo,
        url: System.fetch_env!("REDSHIFT_URL"),
        pool_size: 10,
        ssl: true

  The adapter defaults the Redshift port to `5439` and uses unnamed prepared
  statements, matching Redshift's preferred driver behavior.

  For schemas, prefer application-generated binary IDs via
  `EctoRedshift.Schema` to sidestep Redshift's lack of `RETURNING`:

      defmodule MyApp.Analytics.Event do
        use EctoRedshift.Schema

        schema "events" do
          field :payload, :map
          belongs_to :account, MyApp.Accounts.Account
          timestamps()
        end
      end

  ## Redshift-specific behavior

  This adapter implements the following Ecto adapter behaviours:

    * `Ecto.Adapter`, `Ecto.Adapter.Queryable`, `Ecto.Adapter.Schema`
    * `Ecto.Adapter.Storage` — `storage_up/1`, `storage_down/1`,
      `storage_status/1`
    * `Ecto.Adapter.Structure` — currently returns an explicit error;
      portable structure dump/load is not implemented yet
    * Migration and transaction callbacks

  Notable divergences from `Ecto.Adapters.Postgres`:

    * `supports_ddl_transaction?/0` returns `false` — Redshift has no
      transactional DDL.
    * `lock_for_migrations/3` uses `LOCK TABLE` instead of advisory locks.
    * `autogenerate(:id)` returns `nil` and `Repo.insert/2` will raise if
      `:read_after_writes` is requested for an `:id` primary key, because
      Redshift has no `RETURNING`. Use `:binary_id` primary keys instead.
    * `on_conflict` upserts, outer-join `update_all`/`delete_all`,
      `CREATE INDEX`, and `CHECK`/`EXCLUDE` constraints all raise.

  See `EctoRedshift.unsupported_features/0` and `docs/compatibility.md` for
  the authoritative list.
  """

  use Ecto.Adapters.SQL, driver: :postgrex

  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  @default_maintenance_database "dev"
  @default_prepare_opt :unnamed

  @doc """
  Ecto-specific Postgrex extensions.
  """
  @spec extensions() :: []
  def extensions do
    []
  end

  @impl true
  def autogenerate(:id), do: nil

  def autogenerate(:embed_id), do: Ecto.UUID.generate()

  def autogenerate(:binary_id), do: Ecto.UUID.generate()

  @impl true
  def loaders({:map, _} = type, _loader) do
    [&json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
  end

  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders(:binary_id, type), do: [type, Ecto.UUID]
  def loaders(:uuid, type), do: [type, Ecto.UUID]
  def loaders(_, type), do: [type]

  @impl true
  def dumpers({:map, _} = type, _dumper) do
    [&Ecto.Type.embedded_dump(type, &1, :json), &json_encode/1]
  end

  def dumpers(:map, type), do: [type, &json_encode/1]
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(:uuid, type), do: [type, Ecto.UUID]
  def dumpers(_, type), do: [type]

  @impl true
  def insert(adapter_meta, schema_meta, params, on_conflict, returning, opts) do
    validate_insert_support!(schema_meta, on_conflict, returning)

    %{source: source, prefix: prefix} = schema_meta
    {kind, conflict_params, _} = on_conflict
    {fields, values} = :lists.unzip(params)
    sql = @conn.insert(prefix, source, fields, [fields], on_conflict, returning, [])

    Ecto.Adapters.SQL.struct(
      adapter_meta,
      @conn,
      sql,
      :insert,
      source,
      [],
      values ++ conflict_params,
      kind,
      returning,
      opts
    )
  end

  @impl true
  def update(adapter_meta, schema_meta, fields, params, returning, opts) do
    validate_schema_returning!(:update, schema_meta, returning)

    %{source: source, prefix: prefix} = schema_meta
    {fields, field_values} = :lists.unzip(fields)
    filter_values = Keyword.values(params)
    sql = @conn.update(prefix, source, fields, params, returning)

    Ecto.Adapters.SQL.struct(
      adapter_meta,
      @conn,
      sql,
      :update,
      source,
      params,
      field_values ++ filter_values,
      :raise,
      returning,
      opts
    )
  end

  @impl true
  def delete(adapter_meta, schema_meta, params, returning, opts) do
    validate_schema_returning!(:delete, schema_meta, returning)

    %{source: source, prefix: prefix} = schema_meta
    filter_values = Keyword.values(params)
    sql = @conn.delete(prefix, source, params, returning)

    Ecto.Adapters.SQL.struct(
      adapter_meta,
      @conn,
      sql,
      :delete,
      source,
      params,
      filter_values,
      :raise,
      returning,
      opts
    )
  end

  @impl Ecto.Adapter.Queryable
  def execute(adapter_meta, query_meta, query, params, opts) do
    prepare = Keyword.get(opts, :prepare, @default_prepare_opt)

    unless prepare in [:named, :unnamed] do
      raise ArgumentError,
            "expected option :prepare to be either :named or :unnamed, got: #{inspect(prepare)}"
    end

    Ecto.Adapters.SQL.execute(prepare, adapter_meta, query_meta, query, params, opts)
  end

  @impl true
  def storage_up(opts) do
    database = Keyword.fetch!(opts, :database)
    validate_database_identifier!(database)
    maintenance_database = Keyword.get(opts, :maintenance_database, @default_maintenance_database)
    opts = Keyword.put(opts, :database, maintenance_database)

    check_existence_command =
      "SELECT FROM pg_database WHERE datname = '#{escape_sql_literal(database)}'"

    case run_query(check_existence_command, opts) do
      {:ok, %{num_rows: 1}} ->
        {:error, :already_up}

      _ ->
        case run_query(~s(CREATE DATABASE "#{database}"), opts) do
          {:ok, _} ->
            :ok

          {:error, %{postgres: %{code: :duplicate_database}}} ->
            {:error, :already_up}

          {:error, error} ->
            {:error, Exception.message(error)}
        end
    end
  end

  @impl true
  def storage_down(opts) do
    database = Keyword.fetch!(opts, :database)
    validate_database_identifier!(database)
    maintenance_database = Keyword.get(opts, :maintenance_database, @default_maintenance_database)

    opts =
      opts
      |> Keyword.put(:database, maintenance_database)
      |> Keyword.delete(:force_drop)

    case run_query(~s(DROP DATABASE "#{database}"), opts) do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{code: :invalid_catalog_name}}} ->
        {:error, :already_down}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts) do
    database = Keyword.fetch!(opts, :database)
    validate_database_identifier!(database)
    maintenance_database = Keyword.get(opts, :maintenance_database, @default_maintenance_database)
    opts = Keyword.put(opts, :database, maintenance_database)

    check_database_query =
      "SELECT datname FROM pg_catalog.pg_database WHERE datname = '#{escape_sql_literal(database)}'"

    case run_query(check_database_query, opts) do
      {:ok, %{num_rows: 0}} -> :down
      {:ok, %{num_rows: _}} -> :up
      other -> {:error, other}
    end
  end

  @impl true
  def supports_ddl_transaction? do
    false
  end

  @impl true
  def lock_for_migrations(meta, opts, fun) do
    %{opts: adapter_opts} = meta

    if Keyword.fetch(adapter_opts, :pool_size) == {:ok, 1} do
      Ecto.Adapters.SQL.raise_migration_pool_size_error()
    end

    opts = Keyword.merge(opts, timeout: :infinity, telemetry_options: [schema_migration: true])

    {:ok, result} =
      transaction(meta, opts, fn ->
        source = Keyword.get(opts, :migration_source, "schema_migrations")
        table = if prefix = opts[:prefix], do: ~s("#{prefix}"."#{source}"), else: ~s("#{source}")
        {:ok, _} = Ecto.Adapters.SQL.query(meta, "LOCK TABLE #{table}", [], opts)
        fun.()
      end)

    result
  end

  @impl true
  def structure_dump(_default, _config) do
    {:error,
     "structure dumping is not implemented yet for Redshift; use migrations or raw SQL exports for now"}
  end

  @impl true
  def structure_load(_default, _config) do
    {:error,
     "structure loading is not implemented yet for Redshift; use migrations or raw SQL imports for now"}
  end

  @impl true
  def dump_cmd(_args, _opts \\ [], _config) do
    raise ArgumentError,
          "portable structure dump tooling is not implemented yet for Ecto.Adapters.Redshift"
  end

  # Redshift identifiers (including database names) must not contain double
  # quotes. We reject them up front so both the quoted identifier form
  # (`CREATE DATABASE "..."`) and the string-literal lookups in pg_database
  # cannot be broken by a pathological config value.
  defp validate_database_identifier!(database) when is_binary(database) do
    cond do
      database == "" ->
        raise ArgumentError, "Ecto.Adapters.Redshift: :database must not be empty"

      String.contains?(database, "\"") ->
        raise ArgumentError,
              "Ecto.Adapters.Redshift: :database must not contain double quotes, got: #{inspect(database)}"

      String.contains?(database, <<0>>) ->
        raise ArgumentError,
              "Ecto.Adapters.Redshift: :database must not contain null bytes, got: #{inspect(database)}"

      true ->
        :ok
    end
  end

  defp validate_database_identifier!(database) do
    raise ArgumentError,
          "Ecto.Adapters.Redshift: :database must be a string, got: #{inspect(database)}"
  end

  # SQL-standard single quote escaping for string literals.
  defp escape_sql_literal(value) when is_binary(value) do
    :binary.replace(value, "'", "''", [:global])
  end

  defp json_decode(value) when is_binary(value) do
    {:ok, json_library().decode!(value)}
  end

  defp json_decode(value), do: {:ok, value}

  defp json_encode(value) when is_map(value) or is_list(value) do
    {:ok, json_library().encode!(value)}
  end

  defp json_encode(value), do: {:ok, value}

  defp json_library do
    Application.get_env(:postgrex, :json_library, Jason)
  end

  defp validate_insert_support!(schema_meta, on_conflict, returning) do
    validate_on_conflict!(on_conflict)
    validate_schema_returning!(:insert, schema_meta, returning)
  end

  defp validate_on_conflict!({:raise, _, []}), do: :ok

  defp validate_on_conflict!(_on_conflict) do
    raise ArgumentError,
          "Ecto.Adapters.Redshift does not support :on_conflict upserts yet; use :raise or implement a Redshift MERGE workflow explicitly"
  end

  defp validate_schema_returning!(_operation, _schema_meta, []), do: :ok

  defp validate_schema_returning!(
         :insert,
         %{autogenerate_id: {_field, source, :id}},
         returning
       ) do
    if Enum.member?(returning, source) do
      raise ArgumentError,
            "Ecto.Adapters.Redshift cannot read back autogenerated :id primary keys because Amazon Redshift does not support RETURNING. Use an application-generated :binary_id primary key, for example via EctoRedshift.Schema, or set the primary key explicitly before insert."
    end

    validate_generic_returning!(:insert, returning)
  end

  defp validate_schema_returning!(operation, _schema_meta, returning) do
    validate_generic_returning!(operation, returning)
  end

  defp validate_generic_returning!(operation, returning) do
    raise ArgumentError,
          "Ecto.Adapters.Redshift does not support RETURNING for #{operation}. Remove :read_after_writes, avoid Repo #{operation} returning fields #{inspect(returning)}, or reload the record in a separate query."
  end

  defp run_query(sql, opts) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    opts =
      opts
      |> Keyword.drop([:name, :log, :pool, :pool_size])
      |> Keyword.put(:backoff_type, :stop)
      |> Keyword.put(:max_restarts, 0)

    task =
      Task.Supervisor.async_nolink(Ecto.Adapters.SQL.StorageSupervisor, fn ->
        {:ok, conn} = Postgrex.start_link(opts)

        value = Postgrex.query(conn, sql, [], opts)
        GenServer.stop(conn)
        value
      end)

    timeout = Keyword.get(opts, :timeout, 15_000)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, error}} ->
        {:error, error}

      {:exit, {%{__struct__: struct} = error, _}}
      when struct in [Postgrex.Error, DBConnection.Error] ->
        {:error, error}

      {:exit, reason} ->
        {:error, RuntimeError.exception(Exception.format_exit(reason))}

      nil ->
        {:error, RuntimeError.exception("command timed out")}
    end
  end
end
