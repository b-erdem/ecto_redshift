defmodule Ecto.Adapters.Redshift.ConnectionTest do
  use ExUnit.Case, async: true

  test "defaults Postgrex connections to the Redshift port" do
    %{start: {_module, :start_link, [{_protocol, opts}]}} =
      Ecto.Adapters.Redshift.Connection.child_spec([])

    assert Keyword.get(opts, :port) == 5439
  end

  test "disables constraint translation for informational Redshift constraints" do
    assert Ecto.Adapters.Redshift.Connection.to_constraints(%RuntimeError{}, []) == []
  end

  test "raises for returning clauses" do
    assert_raise ArgumentError, ~r/RETURNING/, fn ->
      Ecto.Adapters.Redshift.Connection.insert(
        nil,
        "events",
        [:id],
        [[1]],
        {:raise, [], []},
        [:id],
        []
      )
    end
  end
end
