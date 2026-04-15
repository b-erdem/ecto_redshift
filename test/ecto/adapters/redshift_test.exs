defmodule Ecto.Adapters.RedshiftTest do
  use ExUnit.Case, async: true

  test "defaults ddl transactions to disabled until proven by integration tests" do
    refute Ecto.Adapters.Redshift.supports_ddl_transaction?()
  end

  test "structure dump is explicitly unsupported in the alpha scaffold" do
    assert {:error, message} = Ecto.Adapters.Redshift.structure_dump("tmp", [])
    assert message =~ "not implemented yet"
  end

  test "structure load is explicitly unsupported in the alpha scaffold" do
    assert {:error, message} = Ecto.Adapters.Redshift.structure_load("tmp", [])
    assert message =~ "not implemented yet"
  end
end
