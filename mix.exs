defmodule EctoRedshift.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/b-erdem/ecto_redshift"
  @description """
  A modern, Redshift-first Ecto SQL adapter for Amazon Redshift. Built on \
  Postgrex, with explicit handling of Redshift's divergence from PostgreSQL \
  (no RETURNING, no savepoints, DISTKEY/SORTKEY/SUPER, etc.) instead of silent \
  PostgreSQL emulation.\
  """

  def project do
    [
      app: :ecto_redshift,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: @description,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: preferred_cli_env(),
      docs: docs(),
      package: package(),
      name: "EctoRedshift",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.22"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/architecture.md",
        "docs/compatibility.md",
        "docs/testing.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ["docs/architecture.md", "docs/compatibility.md", "docs/testing.md"]
      ],
      groups_for_modules: [
        Adapter: [Ecto.Adapters.Redshift],
        Schema: [EctoRedshift.Schema]
      ]
    ]
  end

  defp aliases do
    [
      "test.smoke": ["test test/ecto/adapters/redshift/postgres_smoke_test.exs"],
      "test.integration": ["test test/ecto/adapters/redshift/integration_test.exs"]
    ]
  end

  defp preferred_cli_env do
    [
      "test.smoke": :test,
      "test.integration": :test
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Baris Erdem"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Issues" => "#{@source_url}/issues"
      },
      files: ~w(
        lib
        docs
        .formatter.exs
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
      )
    ]
  end
end
