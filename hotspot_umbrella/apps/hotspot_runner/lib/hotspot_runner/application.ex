defmodule HotspotRunner.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Background extraction jobs run as supervised tasks; the web app starts
      # them via `HotspotRunner.Job.start/2`.
      {Task.Supervisor, name: HotspotRunner.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: HotspotRunner.Supervisor)
  end
end
