# Changelog

All notable changes to `ecto_redshift` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-15

Initial public release.

### Added

- `Ecto.Adapters.Redshift` — an Ecto SQL adapter built on Postgrex that
  targets Amazon Redshift with explicit Redshift-first semantics instead of
  silent PostgreSQL emulation.
- Redshift-native SQL generation for DDL and bulk DML (in
  `lib/ecto/adapters/redshift/connection.ex`), delegating connection
  plumbing to the Postgres adapter.
- `EctoRedshift.Schema` — schema helper that defaults to application-generated
  `binary_id` primary and foreign keys, sidestepping Redshift's lack of
  `RETURNING`.
- **Migrations**: `CREATE` / `ALTER` / `DROP TABLE`, table and column renames,
  column add/modify/remove.
- **Redshift DDL options**: `DISTSTYLE` (`:auto | :even | :all | :key`),
  `DISTKEY`, `SORTKEY` (including `{:compound, [...]}` and
  `{:interleaved, [...]}`), `BACKUP`, table-level `ENCODE AUTO`, column-level
  compression encodings (`:az64`, `:bytedict`, `:delta`, `:delta32k`, `:lzo`,
  `:mostly8/16/32`, `:raw`, `:runlength`, `:text255`, `:text32k`, `:zstd`),
  `IDENTITY(seed, step)`, and opt-in `:super` columns.
- **Bulk DML**: `update_all` / `delete_all` with Redshift `FROM` / `USING`
  inner-join syntax, `insert_all` placeholders, and `INSERT INTO ... SELECT`.
- **Storage**: `storage_up`, `storage_down`, and `storage_status` callbacks
  with identifier validation and SQL-literal escaping.
- **Migration locking** via `LOCK TABLE` (Redshift has no advisory locks).
- **Type mapping**: `:binary_id` / `:uuid` → `CHAR(36)`, `:map` →
  `VARCHAR(MAX)` with JSON round-tripping, `:super`, `:varbyte`, temporal
  types with `:precision`.
- **Explicit failure surfaces** (instead of silently broken SQL) for:
  `RETURNING`, `ON CONFLICT` upserts, savepoints, outer-join mutations,
  indexes, `CHECK` / `EXCLUDE` constraints, array columns, `:id` PKs with
  `RETURNING`-based readback, and `ON DELETE` / `ON UPDATE` foreign-key
  actions.
- **Test tiers**: unit tests asserting generated SQL, `mix test.smoke` against
  a local PostgreSQL in Docker, and `mix test.integration` against a real
  Redshift cluster (gated on `ECTO_REDSHIFT_TEST_URL`).

### Known limitations

Documented in [`docs/compatibility.md`](docs/compatibility.md) and the README
feature matrix. The highest-priority roadmap items are:

- First-class `COPY` / `UNLOAD` helpers for S3 data loads and exports.
- Redshift-native `MERGE` to support `Repo.insert(on_conflict: ...)`.
- `SUPER` path navigation / PartiQL DSL.
- Materialized views in migrations.
- `structure_dump` / `structure_load`.

[0.1.0]: https://github.com/b-erdem/ecto_redshift/releases/tag/v0.1.0
