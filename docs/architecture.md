# Architecture

`ecto_redshift` follows the broad shape of `ecto_sql`'s maintained adapters
while staying explicit about Redshift-specific behavior. The guiding
principle is: **reuse Postgres where Redshift genuinely matches Postgres,
and reimplement where it does not.**

## Module layout

| Module | File | Responsibility |
|---|---|---|
| `Ecto.Adapters.Redshift` | `lib/ecto/adapters/redshift.ex` | Top-level adapter. Implements `Ecto.Adapter`, `Ecto.Adapter.Queryable`, `Ecto.Adapter.Schema`, `Ecto.Adapter.Storage`, `Ecto.Adapter.Structure`, and the migration / transaction callbacks. Owns storage lifecycle, loaders / dumpers, `insert` / `update` / `delete` dispatch, and the guardrails against `RETURNING` and upserts. |
| _Ecto.Adapters.Redshift.Connection_ | `lib/ecto/adapters/redshift/connection.ex` | Implements `Ecto.Adapters.SQL.Connection`. Owns SQL-string generation for DDL and bulk DML plus the Redshift-specific type map. Delegates connection plumbing (`execute`, `query`, `stream`, `prepare_execute`) to Postgres's connection module. Kept `@moduledoc false` because it is an implementation detail. |
| `EctoRedshift.Schema` | `lib/ecto_redshift/schema.ex` | Tiny macro that wraps `use Ecto.Schema` and defaults schemas to application-generated `binary_id` primary and foreign keys. |
| `EctoRedshift` | `lib/ecto_redshift.ex` | Project-level helpers: `features/0`, `unsupported_features/0`, `adapter_module/0`. |

## The delegation boundary

The connection module delegates to `Ecto.Adapters.Postgres` only for
behavior where Redshift is genuinely compatible:

- **Connection plumbing** — `execute/4`, `query/4`, `query_many/4`,
  `prepare_execute/5`, `stream/4`, `explain_query/4`, `ddl_logs/1`,
  `table_exists_query/1`.
- **`SELECT` generation** — `all/1` delegates fully. Redshift's `SELECT`
  surface is close enough to Postgres that reimplementing it would be
  wasteful.
- **`update_all` and `delete_all`** — delegates to Postgres *after* a
  validation pass (`validate_mutation_query!/2`) that rejects outer joins
  and `RETURNING` clauses. Postgres emits `FROM`/`USING` syntax that
  Redshift also accepts for these operations.
- **`insert` for the happy path** — delegates to Postgres when
  `on_conflict == {:raise, [], []}` and `returning == []`. Anything else
  raises at the adapter layer.

Everything else is reimplemented in the connection module:

- **`update/5` and `delete/4`** (single-row) — Redshift-specific implementations
  that thread `$N` placeholder counters through the SET and WHERE clauses
  and handle `IS NULL` filters without consuming a placeholder.
- **`execute_ddl/1`** — full Redshift-native DDL generation for `CREATE`,
  `ALTER`, `DROP`, `RENAME`, plus explicit rejection of indexes and
  `CHECK`/`EXCLUDE` constraints.
- **Type mapping** (`column_type_name/2`) — Redshift-first type map
  including `:binary_id` → `CHAR(36)`, `:map` → `VARCHAR(MAX)`, `:super`,
  `:varbyte`, and explicit errors for `:binary` and `{:array, _}`.

## Storage lifecycle

`storage_up/1`, `storage_down/1`, and `storage_status/1` connect to the
configured `:maintenance_database` (default `"dev"`) and issue
`CREATE DATABASE` / `DROP DATABASE` / `pg_database` lookups.

Database identifiers are validated up front (`validate_database_identifier!/1`)
to reject empty strings, embedded double quotes, and null bytes. String
literals in the `pg_database` lookups go through SQL-standard single-quote
escaping (`escape_sql_literal/1`), so both the quoted-identifier form and
the string-literal form are safe even with adversarial config values.

## Migrations

- `supports_ddl_transaction?/0` returns `false`. Redshift has no
  transactional DDL — each statement is its own transaction.
- `lock_for_migrations/3` takes a `LOCK TABLE` on the migrations table
  inside a flat transaction. Redshift has no advisory locks.
- The adapter refuses to run migrations with `pool_size: 1`, because a
  single-connection pool deadlocks on migration locking.

## Transactions

Flat transactions only. Redshift has no savepoints, so nested transactions
and `Ecto.Adapters.SQL.Sandbox` are not supported. Applications that need a
sandbox-like test workflow should either (a) truncate tables between tests
against a real Redshift cluster, or (b) run their business logic tests
against PostgreSQL locally and reserve `mix test.integration` for Redshift
semantic validation.

## Design principles

1. **Redshift-first, not Postgres-shaped.** The adapter refuses to silently
   translate Postgres idioms that Redshift does not implement. Every
   unsupported feature either works natively or raises with a message that
   tells the user exactly what happened and what to do instead.
2. **Reuse where honest, reimplement where not.** Delegation to the
   Postgres adapter's connection module is deliberate and narrow. Anything
   with Redshift-specific semantics is reimplemented in this repo.
3. **Evidence over claims.** A feature is considered "supported" only after
   it has unit tests asserting the generated SQL and — for anything
   runtime-visible — an integration test against a real Redshift cluster.

## Roadmap

The public surface is stable enough to release at `0.1.0`. Planned work:

1. First-class `COPY` / `UNLOAD` helpers for S3 data loads and exports.
2. Redshift-native `MERGE` to support `Repo.insert(on_conflict: ...)`.
3. `SUPER` path navigation / PartiQL DSL helpers.
4. Materialized views in migrations.
5. Portable `structure_dump` / `structure_load`.
