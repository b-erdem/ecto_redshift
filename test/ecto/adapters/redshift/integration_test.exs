defmodule Ecto.Adapters.Redshift.IntegrationTest do
  use ExUnit.Case, async: false

  alias EctoRedshift.IntegrationRepo

  @moduletag skip:
               if(System.get_env("ECTO_REDSHIFT_TEST_URL") in [nil, ""],
                 do: "set ECTO_REDSHIFT_TEST_URL to run live Redshift integration tests",
                 else: false
               )

  setup_all do
    repo_config = [
      url: System.fetch_env!("ECTO_REDSHIFT_TEST_URL"),
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      prepare: :unnamed,
      show_sensitive_data_on_connection_error: true
    ]

    Application.put_env(:ecto_redshift, IntegrationRepo, repo_config)
    start_supervised!({IntegrationRepo, repo_config})

    :ok
  end

  test "connects and can run a trivial query" do
    assert {:ok, %{rows: [[1]], num_rows: 1}} = IntegrationRepo.query("SELECT 1", [])
  end

  test "supports Redshift-flavored DDL round-trips" do
    table_name = "ecto_redshift_integration_events"

    on_exit(fn ->
      IntegrationRepo.query(~s|DROP TABLE IF EXISTS "#{table_name}"|, [])
    end)

    assert {:ok, _} =
             IntegrationRepo.query(
               ~s|CREATE TABLE "#{table_name}" ("id" char(36) NOT NULL, "payload" super) DISTSTYLE AUTO SORTKEY AUTO|,
               []
             )

    assert {:ok, %{num_rows: 1}} =
             IntegrationRepo.query(
               ~s|INSERT INTO "#{table_name}" ("id", "payload") VALUES ($1, JSON_PARSE($2))|,
               [Ecto.UUID.generate(), ~s|{"kind":"click"}|]
             )

    assert {:ok, %{rows: [[1]], num_rows: 1}} =
             IntegrationRepo.query(~s|SELECT COUNT(*) FROM "#{table_name}"|, [])
  end
end
