defmodule Ecto.Adapters.Redshift.DMLTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  defp sql(iodata) do
    IO.iodata_to_binary(iodata)
  end

  defp plan(queryable, operation) do
    {query, _cast_params, _dump_params} =
      Ecto.Adapter.Queryable.plan_query(operation, Ecto.Adapters.Redshift, queryable)

    query
  end

  test "generates update_all for inner-join-safe Redshift queries" do
    query =
      from(e in "events",
        join: a in "accounts",
        on: a.id == e.account_id,
        where: a.active == ^true,
        update: [set: [status: ^"processed"]]
      )

    assert query
           |> plan(:update_all)
           |> Ecto.Adapters.Redshift.Connection.update_all()
           |> sql() ==
             ~s|UPDATE "events" AS e0 SET "status" = $1 FROM "accounts" AS a1 WHERE (a1."id" = e0."account_id") AND (a1."active" = $2)|
  end

  test "rejects update_all returning clauses" do
    query =
      from(e in "events",
        where: e.id == ^1,
        update: [set: [status: "processed"]],
        select: e.id
      )

    assert_raise Ecto.QueryError, ~r/does not support RETURNING clauses in update_all/, fn ->
      query
      |> plan(:update_all)
      |> Ecto.Adapters.Redshift.Connection.update_all()
    end
  end

  test "rejects non-inner joins in update_all" do
    query =
      from(e in "events",
        left_join: a in "accounts",
        on: a.id == e.account_id,
        update: [set: [status: "processed"]]
      )

    assert_raise Ecto.QueryError, ~r/supports only inner joins in update_all/, fn ->
      query
      |> plan(:update_all)
      |> Ecto.Adapters.Redshift.Connection.update_all()
    end
  end

  test "generates delete_all using Redshift USING syntax" do
    query =
      from(e in "events",
        join: a in "accounts",
        on: a.id == e.account_id,
        where: a.active == ^true
      )

    assert query
           |> plan(:delete_all)
           |> Ecto.Adapters.Redshift.Connection.delete_all()
           |> sql() ==
             ~s|DELETE FROM "events" AS e0 USING "accounts" AS a1 WHERE (a1."id" = e0."account_id") AND (a1."active" = $1)|
  end

  test "rejects delete_all returning clauses" do
    query =
      from(e in "events",
        where: e.id == ^1,
        select: e.id
      )

    assert_raise Ecto.QueryError, ~r/does not support RETURNING clauses in delete_all/, fn ->
      query
      |> plan(:delete_all)
      |> Ecto.Adapters.Redshift.Connection.delete_all()
    end
  end

  test "generates insert into select queries" do
    query =
      from(s in "staging_events",
        where: s.kind == ^"click",
        select: %{id: s.id, payload: s.payload}
      )

    assert query
           |> plan(:insert_all)
           |> then(fn planned_query ->
             Ecto.Adapters.Redshift.Connection.insert(
               nil,
               "events",
               [:id, :payload],
               planned_query,
               {:raise, [], []},
               [],
               []
             )
           end)
           |> sql() ==
             ~s|INSERT INTO "events" ("id","payload") (SELECT s0."id", s0."payload" FROM "staging_events" AS s0 WHERE (s0."kind" = $1))|
  end

  test "update quotes schema prefix on the target table" do
    assert Ecto.Adapters.Redshift.Connection.update(
             "analytics",
             "events",
             [:status, :processed_at],
             [id: 1],
             []
           )
           |> sql() ==
             ~s|UPDATE "analytics"."events" SET "status" = $1, "processed_at" = $2 WHERE "id" = $3|
  end

  test "delete quotes schema prefix on the target table" do
    assert Ecto.Adapters.Redshift.Connection.delete(
             "analytics",
             "events",
             [id: 1, tenant_id: 42],
             []
           )
           |> sql() ==
             ~s|DELETE FROM "analytics"."events" WHERE "id" = $1 AND "tenant_id" = $2|
  end

  test "update threads parameter counters past single digits" do
    fields = for n <- 1..10, do: :"field_#{n}"
    filters = for n <- 1..3, do: {:"filter_#{n}", n}

    generated =
      Ecto.Adapters.Redshift.Connection.update(nil, "events", fields, filters, [])
      |> sql()

    expected_sets =
      fields
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {field, idx} -> ~s("#{field}" = $#{idx}) end)

    expected_where =
      filters
      |> Enum.with_index(length(fields) + 1)
      |> Enum.map_join(" AND ", fn {{field, _}, idx} -> ~s("#{field}" = $#{idx}) end)

    assert generated ==
             ~s|UPDATE "events" SET #{expected_sets} WHERE #{expected_where}|

    # sanity: the highest placeholder is $13, not $1$3 or similar
    assert generated =~ "$13"
    refute generated =~ "$14"
  end

  test "update emits IS NULL for nil filter values without consuming a placeholder" do
    assert Ecto.Adapters.Redshift.Connection.update(
             nil,
             "events",
             [:status],
             [tenant_id: nil, id: 1],
             []
           )
           |> sql() ==
             ~s|UPDATE "events" SET "status" = $1 WHERE "tenant_id" IS NULL AND "id" = $2|
  end

  test "supports insert placeholders" do
    assert Ecto.Adapters.Redshift.Connection.insert(
             nil,
             "events",
             [:id, :payload],
             [[{:placeholder, "1"}, "alpha"], [2, {:placeholder, "1"}]],
             {:raise, [], []},
             [],
             [:shared_payload]
           )
           |> sql() ==
             ~s|INSERT INTO "events" ("id","payload") VALUES ($1,$2),($3,$1)|
  end
end
