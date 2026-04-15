defmodule EctoRedshiftTest do
  use ExUnit.Case

  test "exposes the adapter module" do
    assert EctoRedshift.adapter_module() == Ecto.Adapters.Redshift
  end

  test "features/0 returns a non-empty list of strings" do
    features = EctoRedshift.features()

    assert is_list(features)
    assert features != []
    assert Enum.all?(features, &is_binary/1)
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
