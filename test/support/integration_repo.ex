defmodule EctoRedshift.IntegrationRepo do
  use Ecto.Repo,
    otp_app: :ecto_redshift,
    adapter: Ecto.Adapters.Redshift
end
