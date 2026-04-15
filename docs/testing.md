# Testing

`ecto_redshift` uses a three-tier testing strategy. Each tier answers a
different question and has different infrastructure requirements.

## Tier 1: unit tests — `mix test`

- **Infrastructure**: none. No database, no Docker, no network.
- **What they cover**: generated SQL strings, guardrails against unsupported
  features, schema helper behavior, parameter counter threading.
- **What they do not cover**: anything that Redshift has to accept at
  runtime. They verify "the adapter emits the SQL we think it emits," not
  "Redshift accepts this SQL."

```shell
mix test
```

This is the suite that CI runs by default. It is fast (sub-second) and
should stay green on every commit.

## Tier 2: local smoke tests — `mix test.smoke`

- **Infrastructure**: a local PostgreSQL instance (the bundled
  `docker-compose.yml` starts one on `localhost:55432`).
- **What they cover**: driver-level plumbing — connection boot, unnamed
  prepared statement execution, raw SQL round-trips, basic transaction
  plumbing. The suite proves that the Postgrex integration is wired
  correctly end-to-end.
- **What they do not cover**: Redshift engine semantics. PostgreSQL will
  happily accept SQL that Redshift rejects, and vice versa. Do not use
  smoke tests to claim Redshift compatibility for anything.

```shell
docker compose up -d postgres

export ECTO_REDSHIFT_SMOKE_URL='ecto://postgres:postgres@localhost:55432/ecto_redshift_smoke'
mix test.smoke
```

Without `ECTO_REDSHIFT_SMOKE_URL` set, the smoke suite is skipped.

## Tier 3: Redshift integration tests — `mix test.integration`

- **Infrastructure**: a real Amazon Redshift cluster or Redshift Serverless
  workgroup you can point at.
- **What they cover**: Redshift SQL semantics, migration behavior,
  `SUPER`, transaction quirks, and any runtime behavior that depends on
  Redshift actually being Redshift.
- **What they do not cover**: anything that is not exercised. Because
  provisioning Redshift is expensive and slow, this suite is intentionally
  small and focused on the most semantically load-bearing paths. Feature
  coverage here is the gate for adding new "supported" claims to
  `docs/compatibility.md`.

```shell
export ECTO_REDSHIFT_TEST_URL='ecto://USER:PASSWORD@HOST:5439/DATABASE'
mix test.integration
```

Without `ECTO_REDSHIFT_TEST_URL` set, the integration suite is skipped.
CI does not run integration tests automatically; they are intended to be
run by maintainers against a dedicated test cluster before releases.

## When to run what

| Situation | Run |
|---|---|
| Every commit | `mix test` |
| Editing connection / driver-facing code | `mix test.smoke` |
| Claiming Redshift compatibility for a feature | `mix test.integration` |
| Before a release | all three |

## Writing new tests

- **Adding a feature**: start with a unit test that asserts the generated
  SQL string in `test/ecto/adapters/redshift/`. Be specific — prefer
  `==` against an exact string over `=~` pattern matching.
- **If the feature touches runtime behavior**: add an integration test in
  `test/ecto/adapters/redshift/integration_test.exs` that exercises it
  against a real cluster.
- **Update `docs/compatibility.md`** and the README feature matrix in the
  same PR. Compatibility claims and test coverage should move together.
