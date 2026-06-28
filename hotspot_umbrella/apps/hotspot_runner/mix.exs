defmodule HotspotRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :hotspot_runner,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  def application do
    [
      mod: {HotspotRunner.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The runner *writes* the SQLite db (raw exqlite, it owns the schema/DDL). It
  # depends on `:hotspot` only to reach the shared PubSub and storage lifecycle
  # when run from the web app. `:hotspot` never depends back on the runner.
  defp deps do
    [
      {:exqlite, ">= 0.0.0"},
      {:hotspot, in_umbrella: true},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
