defmodule HotspotRunner.Job do
  @moduledoc """
  Background extraction for the web app: runs `HotspotRunner.Extractor.extract/2`
  as a supervised task, broadcasting progress on `Hotspot.PubSub` topic
  `"extraction"`. On success it opens the produced db via `Hotspot.Storage` so it
  becomes available to the UI automatically.

  Messages broadcast on the topic:

    * `{:extraction, :started, %{repo: path}}`
    * `{:extraction, :progress, %{commits: n}}`
    * `{:extraction, :done, result}` (the `Extractor.extract/2` result map)
    * `{:extraction, :error, reason}`
  """

  require Logger

  @topic "extraction"

  @doc "PubSub topic carrying extraction lifecycle messages."
  def topic, do: @topic

  @doc "Start a background extraction of `repo_path` at `ref`."
  @spec start(String.t(), String.t()) :: DynamicSupervisor.on_start_child()
  def start(repo_path, ref \\ "HEAD") do
    Task.Supervisor.start_child(HotspotRunner.TaskSupervisor, fn -> run(repo_path, ref) end)
  end

  defp run(repo_path, ref) do
    broadcast({:extraction, :started, %{repo: repo_path}})
    on_progress = fn n -> broadcast({:extraction, :progress, %{commits: n}}) end

    case HotspotRunner.Extractor.extract(repo_path, ref: ref, on_progress: on_progress) do
      {:ok, result} ->
        # Make the freshly written db the active one (broadcasts :storage_changed).
        Hotspot.Storage.open(result.db_path)
        broadcast({:extraction, :done, result})

      {:error, reason} ->
        Logger.warning("extraction of #{repo_path} failed: #{inspect(reason)}")
        broadcast({:extraction, :error, reason})
    end
  rescue
    e ->
      Logger.error("extraction of #{repo_path} crashed: #{Exception.message(e)}")
      broadcast({:extraction, :error, Exception.message(e)})
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Hotspot.PubSub, @topic, msg)
end
