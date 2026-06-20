defmodule Hotspot.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DNSCluster, query: Application.get_env(:hotspot, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hotspot.PubSub},
      # No db is opened at boot. `Hotspot.Storage` discovers the runner-produced
      # `.db` files and starts the `Hotspot.Repo` pool under this DynamicSupervisor
      # only once the user picks one at runtime.
      {DynamicSupervisor, name: Hotspot.RepoSupervisor, strategy: :one_for_one},
      Hotspot.Storage
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Hotspot.Supervisor)
  end
end
