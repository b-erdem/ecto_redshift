defmodule Ecto.Adapters.Redshift.PostgresSmokeTest do
  use ExUnit.Case, async: false

  alias EctoRedshift.PostgresSmokeRepo

  @moduletag skip:
               if(System.get_env("ECTO_REDSHIFT_SMOKE_URL") in [nil, ""],
                 do: "set ECTO_REDSHIFT_SMOKE_URL to run local PostgreSQL smoke tests",
                 else: false
               )

  setup_all do
    repo_config = [
      url: System.fetch_env!("ECTO_REDSHIFT_SMOKE_URL"),
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      prepare: :unnamed,
      show_sensitive_data_on_connection_error: true
    ]

    Application.put_env(:ecto_redshift, PostgresSmokeRepo, repo_config)
    start_supervised!({PostgresSmokeRepo, repo_config})

    :ok
  end

  test "connects and runs a trivial query through the adapter" do
    assert {:ok, %{rows: [[1]], num_rows: 1}} = PostgresSmokeRepo.query("SELECT 1", [])
  end

  test "supports basic unnamed-statement execution against PostgreSQL" do
    table_name = "ecto_redshift_pg_smoke_events"

    on_exit(fn ->
      PostgresSmokeRepo.query(~s|DROP TABLE IF EXISTS "#{table_name}"|, [])
    end)

    assert {:ok, _} =
             PostgresSmokeRepo.query(
               ~s|CREATE TABLE "#{table_name}" ("id" char(36) PRIMARY KEY, "payload" text NOT NULL)|,
               []
             )

    event_id = Ecto.UUID.generate()

    assert {:ok, %{num_rows: 1}} =
             PostgresSmokeRepo.query(
               ~s|INSERT INTO "#{table_name}" ("id", "payload") VALUES ($1, $2)|,
               [event_id, ~s|{"kind":"click"}|]
             )

    assert {:ok, %{rows: [[^event_id]], num_rows: 1}} =
             PostgresSmokeRepo.query(
               ~s|SELECT "id" FROM "#{table_name}" WHERE "payload" = $1|,
               [~s|{"kind":"click"}|]
             )
  end

  test "can execute a transaction on the PostgreSQL smoke target" do
    assert {:ok, 1} =
             PostgresSmokeRepo.transaction(fn ->
               assert {:ok, %{rows: [[1]], num_rows: 1}} =
                        PostgresSmokeRepo.query("SELECT 1", [])

               1
             end)
  end
end
