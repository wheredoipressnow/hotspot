defmodule HotspotWeb.HotspotLive do
  @moduledoc """
  Circle-packing view of repo hotspots. Owns the visualization parameters (metric,
  path filter, include-removed, labels) and pushes the nested tree to the
  `CirclePack` JS hook. Reads only through `Hotspot.Analysis`, never the Repo.

  Layout is a full-height row: a docked **Controls** panel (db selection + options)
  on the left, the chart filling the middle, and a docked **Top hotspots** panel on
  the right. Each panel collapses to a thin rail so the chart can reclaim the width;
  the chart reflows live because its SVG scales to its container.

  No db is loaded at boot: until one is selected the chart area shows a hint and the
  Controls panel lists the available databases (`Hotspot.Storage`).
  """
  use HotspotWeb, :live_view

  alias Hotspot.{Analysis, Storage}

  @metrics [{"Churn", "churn"}, {"Author count", "author_count"}]
  @top_limit 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Hotspot.PubSub, Storage.topic())

    available = Analysis.removed_filter_available?()

    {:ok,
     assign(socket,
       metric: "churn",
       path_filter: "",
       # Default to excluding removed files when the db can, else include all.
       include_removed: not available,
       removed_filter_available: available,
       show_labels: false,
       metrics: @metrics,
       hotspots_scope: "files",
       hotspots: [],
       prefs_open: true,
       hotspots_open: true,
       dbs: Storage.list(),
       current: Storage.current()
     )}
  end

  @impl true
  # The hook asks for data once it has mounted on the client.
  def handle_event("hotspot:ready", _params, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_event("update", params, socket) do
    # The removed-files toggle only has effect when the db supports it; on a db that
    # lacks the snapshot the control is disabled and we force include-all regardless
    # of the submitted value.
    include_removed =
      if socket.assigns.removed_filter_available,
        do: params["include_removed"] == "true",
        else: true

    socket
    |> assign(
      metric: params["metric"] || socket.assigns.metric,
      path_filter: params["path_filter"] || socket.assigns.path_filter,
      include_removed: include_removed,
      show_labels: params["show_labels"] == "true"
    )
    |> refresh()
    |> then(&{:noreply, &1})
  end

  def handle_event("set_scope", %{"scope" => scope}, socket) do
    {:noreply, socket |> assign(hotspots_scope: scope) |> assign_hotspots()}
  end

  def handle_event("open_db", %{"db" => ""}, socket), do: {:noreply, socket}

  def handle_event("open_db", %{"db" => path}, socket) do
    Storage.open(path)
    {:noreply, socket}
  end

  def handle_event("toggle_prefs", _params, socket) do
    {:noreply, update(socket, :prefs_open, &(!&1))}
  end

  def handle_event("toggle_hotspots", _params, socket) do
    {:noreply, update(socket, :hotspots_open, &(!&1))}
  end

  def handle_event("zoom_to", %{"path" => path}, socket) do
    {:noreply, push_event(socket, "hotspot:zoom", %{path: path})}
  end

  @impl true
  def handle_info({:storage_changed, current}, socket) do
    # Path filter is repo-specific, so clear it on a db switch; other prefs persist.
    # Removed-filter availability is per-db, so recompute it and its default.
    available = Analysis.removed_filter_available?()

    socket =
      assign(socket,
        current: current,
        dbs: Storage.list(),
        path_filter: "",
        removed_filter_available: available,
        include_removed: not available
      )

    {:noreply, if(current, do: refresh(socket), else: assign(socket, hotspots: []))}
  end

  # Recompute both views: push the tree to the hook and assign the ranked list.
  defp refresh(%{assigns: %{current: nil}} = socket), do: socket

  defp refresh(socket) do
    socket
    |> push_tree()
    |> assign_hotspots()
  end

  defp push_tree(socket) do
    params = %{
      path_filter: socket.assigns.path_filter,
      include_removed: socket.assigns.include_removed
    }

    case Analysis.tree_for_visualization(params) do
      {:error, :no_database} ->
        socket

      tree ->
        push_event(socket, "hotspot:tree", %{
          tree: tree,
          metric: socket.assigns.metric,
          labels: socket.assigns.show_labels
        })
    end
  end

  defp assign_hotspots(%{assigns: %{current: nil}} = socket), do: assign(socket, hotspots: [])

  defp assign_hotspots(socket) do
    params = %{
      metric: socket.assigns.metric,
      scope: socket.assigns.hotspots_scope,
      include_removed: socket.assigns.include_removed,
      path_filter: socket.assigns.path_filter,
      limit: @top_limit
    }

    hotspots =
      case Analysis.top_hotspots(params) do
        {:error, :no_database} -> []
        rows -> rows
      end

    assign(socket, hotspots: hotspots)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex overflow-hidden">
      <.panel open={@prefs_open} side="left" title="Controls" toggle="toggle_prefs">
        <.controls
          dbs={@dbs}
          current={@current}
          metric={@metric}
          metrics={@metrics}
          path_filter={@path_filter}
          include_removed={@include_removed}
          removed_filter_available={@removed_filter_available}
          show_labels={@show_labels}
        />
      </.panel>

      <div class="flex-1 relative min-w-0 bg-base-100">
        <div
          :if={@current}
          id="hotspot-chart"
          phx-hook="CirclePack"
          phx-update="ignore"
          class="w-full h-full"
        >
        </div>
        <div :if={is_nil(@current)} class="h-full flex items-center justify-center px-6">
          <p class="text-sm opacity-60 text-center">
            ← Open a database in the <span class="font-semibold">Controls</span>
            panel to see hotspots.
          </p>
        </div>
      </div>

      <.panel open={@hotspots_open} side="right" title="Top hotspots" toggle="toggle_hotspots">
        <.top_hotspots
          current={@current}
          scope={@hotspots_scope}
          hotspots={@hotspots}
          metric={@metric}
        />
      </.panel>
    </div>
    """
  end

  # --- Reusable docked panel -------------------------------------------------

  attr(:open, :boolean, required: true)
  attr(:title, :string, required: true)
  attr(:side, :string, default: "left", values: ~w(left right))
  attr(:toggle, :string, required: true, doc: "phx-click event that flips `open`")
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <div class={[
      "shrink-0 h-full flex flex-col bg-base-200 border-base-300 transition-[width] duration-200",
      @side == "left" && "border-r",
      @side == "right" && "border-l",
      @open && "w-72",
      !@open && "w-10"
    ]}>
      <div :if={@open} class="flex items-center justify-between px-3 py-2 border-b border-base-300">
        <span class="text-sm font-semibold">{@title}</span>
        <button type="button" phx-click={@toggle} class="btn btn-xs btn-ghost" title="Minimize">
          <.icon name={chevron(@side, :collapse)} class="size-4" />
        </button>
      </div>

      <div :if={@open} class="overflow-y-auto grow p-3 space-y-4">
        {render_slot(@inner_block)}
      </div>

      <button
        :if={!@open}
        type="button"
        phx-click={@toggle}
        class="h-full w-full flex flex-col items-center gap-3 py-3 hover:bg-base-300"
        title={"Expand #{@title}"}
      >
        <.icon name={chevron(@side, :expand)} class="size-4 opacity-70" />
        <span class="text-xs opacity-70 [writing-mode:vertical-rl]">{@title}</span>
      </button>
    </div>
    """
  end

  # Collapse points "into" the panel; expand points "out" toward the chart.
  defp chevron("left", :collapse), do: "hero-chevron-double-left"
  defp chevron("left", :expand), do: "hero-chevron-double-right"
  defp chevron("right", :collapse), do: "hero-chevron-double-right"
  defp chevron("right", :expand), do: "hero-chevron-double-left"

  # --- Controls panel body ---------------------------------------------------

  attr(:dbs, :list, required: true)
  attr(:current, :string, default: nil)
  attr(:metric, :string, required: true)
  attr(:metrics, :list, required: true)
  attr(:path_filter, :string, required: true)
  attr(:include_removed, :boolean, required: true)
  attr(:removed_filter_available, :boolean, required: true)
  attr(:show_labels, :boolean, required: true)

  defp controls(assigns) do
    ~H"""
    <form id="db-form" phx-change="open_db">
      <label class="flex flex-col gap-1">
        <span class="text-sm">Database</span>
        <select name="db" class="select select-bordered select-sm">
          <option value="" disabled selected={is_nil(@current)}>Choose…</option>
          <option :for={db <- @dbs} value={db.path} selected={@current == db.path}>
            {db.name}
          </option>
        </select>
      </label>
    </form>

    <p :if={@dbs == []} class="text-xs opacity-70">
      No databases found. Point <code class="font-mono">HOTSPOT_DB_DIR</code>
      at a folder of runner-produced <code class="font-mono">.db</code>
      files.
    </p>

    <form id="options-form" phx-change="update" class="space-y-3">
      <label class="flex flex-col gap-1">
        <span class="text-sm">Metric (size)</span>
        <select name="metric" class="select select-bordered select-sm">
          <option :for={{label, value} <- @metrics} value={value} selected={value == @metric}>
            {label}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span class="text-sm">Path filter</span>
        <input
          type="text"
          name="path_filter"
          value={@path_filter}
          phx-debounce="300"
          placeholder="e.g. lib/"
          class="input input-bordered input-sm"
        />
      </label>

      <label
        class={["flex items-center gap-2", @removed_filter_available && "cursor-pointer"]}
        title={
          !@removed_filter_available &&
            "Needs runner support (tracked_file snapshot); re-extract with the updated runner."
        }
      >
        <input type="hidden" name="include_removed" value="false" />
        <input
          type="checkbox"
          name="include_removed"
          value="true"
          checked={@include_removed}
          disabled={!@removed_filter_available}
          class="checkbox checkbox-sm"
        />
        <span class={["text-sm", !@removed_filter_available && "opacity-50"]}>
          Include removed / renamed files
        </span>
      </label>

      <label class="flex items-center gap-2 cursor-pointer">
        <input type="hidden" name="show_labels" value="false" />
        <input
          type="checkbox"
          name="show_labels"
          value="true"
          checked={@show_labels}
          class="checkbox checkbox-sm"
        />
        <span class="text-sm">Show labels</span>
      </label>
    </form>

    <div class="pt-2 border-t border-base-300 flex items-center justify-between">
      <span class="text-sm">Theme</span>
      <Layouts.theme_toggle />
    </div>
    """
  end

  # --- Top hotspots panel body -----------------------------------------------

  attr(:current, :string, default: nil)
  attr(:scope, :string, required: true)
  attr(:hotspots, :list, required: true)
  attr(:metric, :string, required: true)

  defp top_hotspots(assigns) do
    ~H"""
    <p :if={is_nil(@current)} class="text-sm opacity-60">Open a database first.</p>

    <div :if={@current}>
      <form id="scope-form" phx-change="set_scope" class="mb-3">
        <label class="flex flex-col gap-1">
          <span class="text-sm">Scope</span>
          <select name="scope" class="select select-bordered select-sm">
            <option value="files" selected={@scope == "files"}>Files</option>
            <option value="folders" selected={@scope == "folders"}>Folders</option>
          </select>
        </label>
      </form>

      <p :if={@hotspots == []} class="text-sm opacity-60">No data.</p>

      <ol class="space-y-1">
        <li :for={{h, i} <- Enum.with_index(@hotspots, 1)}>
          <button
            type="button"
            phx-click="zoom_to"
            phx-value-path={h.path}
            class="w-full text-left flex items-center gap-2 px-2 py-1 rounded hover:bg-base-300"
            title={h.path}
          >
            <span class="text-xs opacity-50 w-5 shrink-0">{i}</span>
            <span class="font-mono text-xs truncate grow">{h.path}</span>
            <span class="text-xs opacity-70 shrink-0">
              {metric_value(h, @metric)}
            </span>
          </button>
        </li>
      </ol>
    </div>
    """
  end

  defp metric_value(h, "author_count"), do: "#{h.author_count}a"
  defp metric_value(h, _churn), do: h.churn
end
