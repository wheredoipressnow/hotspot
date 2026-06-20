defmodule HotspotWeb.HotspotLive do
  @moduledoc """
  Circle-packing view of repo hotspots. Owns the visualization parameters (metric,
  path filter) and pushes the nested tree to the `CirclePack` JS hook. Reads only
  through `Hotspot.Analysis` — never the Repo (HANDOFF §2).

  No db is loaded at boot: when none is open it renders a picker of the available
  databases (`Hotspot.Storage`); selecting one opens it and reveals the chart.
  """
  use HotspotWeb, :live_view

  alias Hotspot.{Analysis, Storage}

  @metrics [{"Churn", "churn"}, {"Author count", "author_count"}]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Hotspot.PubSub, Storage.topic())

    {:ok,
     assign(socket,
       metric: "churn",
       path_filter: "",
       metrics: @metrics,
       dbs: Storage.list(),
       current: Storage.current()
     )}
  end

  @impl true
  # The hook asks for data once it has mounted on the client.
  def handle_event("hotspot:ready", _params, socket) do
    {:noreply, push_tree(socket)}
  end

  def handle_event("update", params, socket) do
    socket
    |> assign(
      metric: params["metric"] || socket.assigns.metric,
      path_filter: params["path_filter"] || socket.assigns.path_filter
    )
    |> push_tree()
    |> then(&{:noreply, &1})
  end

  def handle_event("open_db", %{"db" => path}, socket) do
    Storage.open(path)
    {:noreply, socket}
  end

  def handle_event("close_db", _params, socket) do
    Storage.close()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:storage_changed, current}, socket) do
    socket = assign(socket, current: current, dbs: Storage.list())
    {:noreply, if(current, do: push_tree(socket), else: socket)}
  end

  defp push_tree(%{assigns: %{current: nil}} = socket), do: socket

  defp push_tree(socket) do
    case Analysis.tree_for_visualization(%{path_filter: socket.assigns.path_filter}) do
      {:error, :no_database} ->
        socket

      tree ->
        push_event(socket, "hotspot:tree", %{tree: tree, metric: socket.assigns.metric})
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <h1 class="text-xl font-semibold">Hotspots</h1>

      <.db_picker :if={is_nil(@current)} dbs={@dbs} />

      <div :if={@current}>
        <div class="flex items-center gap-2 text-sm mb-2">
          <span class="opacity-70">Database:</span>
          <span class="font-mono">{Path.basename(@current)}</span>
          <button type="button" phx-click="close_db" class="btn btn-xs btn-ghost">change</button>
        </div>

        <form phx-change="update" class="flex flex-wrap gap-4 items-end">
          <label class="flex flex-col gap-1">
            <span class="text-sm">Metric (size)</span>
            <select name="metric" class="select select-bordered">
              <option :for={{label, value} <- @metrics} value={value} selected={value == @metric}>
                {label}
              </option>
            </select>
          </label>

          <label class="flex flex-col gap-1 flex-1 min-w-60">
            <span class="text-sm">Path filter</span>
            <input
              type="text"
              name="path_filter"
              value={@path_filter}
              phx-debounce="300"
              placeholder="e.g. lib/"
              class="input input-bordered"
            />
          </label>
        </form>

        <p class="text-sm opacity-70 mt-2">
          Bubble size = selected metric, color = distinct authors. Click a directory to zoom,
          click the background to zoom out.
        </p>

        <div
          id="hotspot-chart"
          phx-hook="CirclePack"
          phx-update="ignore"
          class="w-full rounded-box border border-base-300 mt-2"
          style="height: 75vh;"
        >
        </div>
      </div>
    </div>
    """
  end

  defp db_picker(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm opacity-70">Open a database to analyze.</p>

      <p :if={@dbs == []} class="text-sm opacity-70">
        No databases found. Point <code class="font-mono">HOTSPOT_DB_DIR</code>
        at a folder of runner-produced <code class="font-mono">.db</code> files.
      </p>

      <ul class="menu bg-base-200 rounded-box w-full max-w-xl">
        <li :for={db <- @dbs}>
          <button type="button" phx-click="open_db" phx-value-db={db.path} class="flex justify-between">
            <span class="font-mono">{db.name}</span>
            <span class="opacity-60 text-xs">{format_size(db.size)}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp format_size(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_size(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{bytes} B"
end
