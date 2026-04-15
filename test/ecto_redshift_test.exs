defmodule EctoRedshiftTest do
  use ExUnit.Case

  test "exposes the adapter module" do
    assert EctoRedshift.adapter_module() == Ecto.Adapters.Redshift
  end

  test "features/0 mentions the load-bearing Redshift surface" do
    joined = EctoRedshift.features() |> Enum.join("\n")

    assert joined =~ ~r/Postgrex/i
    assert joined =~ ~r/DISTSTYLE|DISTKEY|SORTKEY/
    assert joined =~ ~r/binary_id/
  end

  test "unsupported_features/0 documents RETURNING and on_conflict" do
    unsupported = EctoRedshift.unsupported_features()

    assert is_list(unsupported)
    assert Enum.all?(unsupported, &is_binary/1)

    joined = Enum.join(unsupported, "\n")
    assert joined =~ "RETURNING"
    assert joined =~ ~r/ON CONFLICT|upsert/i
    assert joined =~ ~r/savepoint/i
  end
end
