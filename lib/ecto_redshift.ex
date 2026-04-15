defmodule EctoRedshift do
  @moduledoc """
  `ecto_redshift` is a modern Ecto SQL adapter for
  [Amazon Redshift](https://aws.amazon.com/redshift/), built on
  [Postgrex](https://hex.pm/packages/postgrex).

  The public adapter module is `Ecto.Adapters.Redshift`. A schema helper that
  defaults to application-generated binary IDs lives at `EctoRedshift.Schema`.

  ## Philosophy

  This adapter treats Redshift as a Redshift-first OLAP engine with PostgreSQL
  ancestry, **not** as a drop-in PostgreSQL clone. Redshift diverges from
  PostgreSQL in many load-bearing places — there is no `RETURNING`, no
  savepoints, no enforced unique / foreign key / check constraints, no
  indexes, a different upsert story, and a rich surface of Redshift-only DDL
  (`DISTKEY`, `SORTKEY`, `SUPER`, identity columns, compression encodings).

  Where Redshift diverges from PostgreSQL, `ecto_redshift` either implements
  the Redshift-native form or fails loudly with a clear explanation — never
  silently pretending compatibility that does not exist.

  ## Quick reference

  - `features/0` — a high-level list of supported capabilities.
  - `unsupported_features/0` — capabilities that intentionally raise today.
  - `adapter_module/0` — the adapter module to pass to `use Ecto.Repo`.

  See the [README](readme.html) and [compatibility guide](compatibility.html)
  for the full feature matrix.
  """

  @doc """
  Returns a high-level list of capabilities currently supported by the
  adapter.

  This list is a human-readable summary and is kept in sync with
  `docs/compatibility.md`. For the authoritative surface, see the adapter
  tests and the compatibility guide.
  """
  @spec features() :: [String.t()]
  def features do
    [
      "Postgrex-backed connection defaults for Amazon Redshift (port 5439, unnamed prepared statements)",
      "Database storage callbacks for create, drop, and status checks",
      "Redshift-native CREATE TABLE, ALTER TABLE, DROP TABLE, and rename DDL generation",
      "Redshift table options: DISTSTYLE, DISTKEY, SORTKEY (compound/interleaved), BACKUP, ENCODE AUTO",
      "Per-column compression encodings, distkey/sortkey flags, and IDENTITY(seed, step)",
      "Explicit :super migration type alongside conservative :map handling via VARCHAR(MAX) + JSON",
      "EctoRedshift.Schema: Redshift-friendly binary_id defaults for primary and foreign keys",
      "Bulk update_all, delete_all, insert placeholders, and INSERT INTO ... SELECT within a Redshift-safe subset",
      "Migration locking via LOCK TABLE (no advisory locks, no DDL transactions)",
      "Separate unit, local smoke, and real Redshift integration test workflows",
      "Explicit unsupported-feature guardrails instead of silent PostgreSQL emulation"
    ]
  end

  @doc """
  Returns the list of features that intentionally raise a clear error today
  rather than silently producing broken SQL.

  This list is kept in sync with `docs/compatibility.md`.
  """
  @spec unsupported_features() :: [String.t()]
  def unsupported_features do
    [
      "RETURNING clauses (Redshift has none)",
      "PostgreSQL-style ON CONFLICT upserts (use MERGE via raw SQL until the DSL lands)",
      "Savepoint-based sandbox behavior (Redshift has no savepoints)",
      "Outer-join update_all / delete_all queries",
      "CREATE INDEX and DROP INDEX (Redshift has no indexes — use sortkeys)",
      "CHECK and EXCLUDE constraints",
      "Array column types",
      "Database-generated :id primary keys with RETURNING-based readback",
      "ON DELETE / ON UPDATE actions on foreign key references",
      "Portable structure_dump and structure_load tooling",
      "Constraint violation translation (Redshift never raises them)"
    ]
  end

  @doc """
  Returns the adapter module exposed by this package.

  ## Example

      defmodule MyApp.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: EctoRedshift.adapter_module()
      end

  In practice you will usually write the module name directly:

      adapter: Ecto.Adapters.Redshift
  """
  @spec adapter_module() :: module()
  def adapter_module do
    Ecto.Adapters.Redshift
  end
end
