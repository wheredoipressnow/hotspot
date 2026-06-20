defmodule HotspotWeb.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HotspotWeb.Telemetry,
      # Start a worker by calling: HotspotWeb.Worker.start_link(arg)
      # {HotspotWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      HotspotWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HotspotWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HotspotWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
