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

  @metrics [
    {"Churn", "churn"},
    {"Author count", "author_count"},
    {"Recency-weighted churn", "recency_churn"}
  ]
  # Sort keys for the Top hotspots list. A superset of the size metrics: last-changed
  # is a timestamp, meaningful as a list order but not as a circle size.
  @sorts [
    {"Churn", "churn"},
    {"Author count", "author_count"},
    {"Recency-weighted churn", "recency_churn"},
    {"Last changed", "last_changed"}
  ]
  @top_limit 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hotspot.PubSub, Storage.topic())
      Phoenix.PubSub.subscribe(Hotspot.PubSub, HotspotRunner.Job.topic())
    end

    available = Analysis.removed_filter_available?()
    root = repo_root()

    {:ok,
     assign(socket,
       metric: "churn",
       path_filter: "",
       # Default to excluding removed files when the db can, else include all.
       include_removed: not available,
       removed_filter_available: available,
       show_labels: false,
       metrics: @metrics,
       sorts: @sorts,
       hotspots_scope: "files",
       hotspots_sort: "churn",
       hotspots: [],
       prefs_open: true,
       hotspots_open: true,
       dbs: Storage.list(),
       current: Storage.current(),
       # Repository picker + background extraction.
       picker_root: root,
       picker_open: false,
       picker_dir: root,
       picker_entries: [],
       extraction: nil
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

  def handle_event("set_sort", %{"sort" => sort}, socket) do
    {:noreply, socket |> assign(hotspots_sort: sort) |> assign_hotspots()}
  end

  def handle_event("open_db", %{"db" => ""}, socket), do: {:noreply, socket}

  def handle_event("open_db", %{"db" => path}, socket) do
    Storage.open(path)
    {:noreply, socket}
  end

  # --- Repository picker (server-side directory browser) ---------------------
  # A native browser folder dialog can't hand the server a real filesystem path,
  # so we browse the server's filesystem here and pass the chosen absolute path
  # to the runner.

  def handle_event("open_picker", _params, socket) do
    dir = socket.assigns.picker_root
    {:noreply, assign(socket, picker_open: true, picker_dir: dir, picker_entries: list_dirs(dir))}
  end

  def handle_event("close_picker", _params, socket) do
    {:noreply, assign(socket, picker_open: false)}
  end

  def handle_event("picker_nav", %{"path" => path}, socket) do
    if within_root?(path, socket.assigns.picker_root) and File.dir?(path) do
      dir = Path.expand(path)
      {:noreply, assign(socket, picker_dir: dir, picker_entries: list_dirs(dir))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_repo", %{"path" => path}, socket) do
    path = Path.expand(path)

    cond do
      not within_root?(path, socket.assigns.picker_root) ->
        {:noreply, socket}

      not File.dir?(Path.join(path, ".git")) ->
        {:noreply, assign(socket, extraction: %{state: :error, reason: "Not a git repository"})}

      true ->
        HotspotRunner.Job.start(path, "HEAD")

        {:noreply,
         assign(socket,
           picker_open: false,
           extraction: %{state: :running, repo: path, commits: 0}
         )}
    end
  end

  def handle_event("dismiss_extraction", _params, socket) do
    {:noreply, assign(socket, extraction: nil)}
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

  # Background extraction progress. On `:done` the runner has already opened the
  # produced db, so a `:storage_changed` message refreshes the view; here we only
  # track the banner state.
  def handle_info({:extraction, :started, %{repo: repo}}, socket) do
    {:noreply, assign(socket, extraction: %{state: :running, repo: repo, commits: 0})}
  end

  def handle_info({:extraction, :progress, %{commits: n}}, socket) do
    prev = socket.assigns.extraction || %{state: :running, repo: nil}
    {:noreply, assign(socket, extraction: %{prev | state: :running, commits: n})}
  end

  def handle_info({:extraction, :done, result}, socket) do
    {:noreply,
     assign(socket,
       extraction: %{state: :done, repo: result.toplevel, commits: result.commits_written}
     )}
  end

  def handle_info({:extraction, :error, reason}, socket) do
    {:noreply, assign(socket, extraction: %{state: :error, reason: inspect(reason)})}
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
      sort: socket.assigns.hotspots_sort,
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
      <.extraction_banner :if={@extraction} extraction={@extraction} />
      <.repo_picker
        :if={@picker_open}
        dir={@picker_dir}
        root={@picker_root}
        entries={@picker_entries}
      />

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
          sort={@hotspots_sort}
          sorts={@sorts}
          hotspots={@hotspots}
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

    <button type="button" phx-click="open_picker" class="btn btn-sm btn-primary w-full">
      <.icon name="hero-folder-open" class="size-4" /> Open repository…
    </button>

    <p :if={@dbs == []} class="text-xs opacity-70">
      No databases yet. <span class="font-semibold">Open a repository</span>
      above to extract one, or point <code class="font-mono">HOTSPOT_DB_DIR</code>
      at a folder of <code class="font-mono">.db</code>
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
  attr(:sort, :string, required: true)
  attr(:sorts, :list, required: true)
  attr(:hotspots, :list, required: true)

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

      <form id="sort-form" phx-change="set_sort" class="mb-3">
        <label class="flex flex-col gap-1">
          <span class="text-sm">Sort by</span>
          <select name="sort" class="select select-bordered select-sm">
            <option :for={{label, value} <- @sorts} value={value} selected={value == @sort}>
              {label}
            </option>
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
              {sort_value(h, @sort)}
            </span>
          </button>
        </li>
      </ol>
    </div>
    """
  end

  # The value shown per row is the one being sorted on.
  defp sort_value(h, "author_count"), do: "#{h.author_count}a"
  defp sort_value(h, "recency_churn"), do: h.recency_churn
  defp sort_value(h, "last_changed"), do: relative_age(h.last_changed)
  defp sort_value(h, _churn), do: h.churn

  # Compact "time ago" label for an epoch second, e.g. "3d", "5mo", "2y".
  defp relative_age(epoch) when is_integer(epoch) and epoch > 0 do
    days = div(System.os_time(:second) - epoch, 86_400)

    cond do
      days <= 0 -> "today"
      days < 30 -> "#{days}d"
      days < 365 -> "#{div(days, 30)}mo"
      true -> "#{div(days, 365)}y"
    end
  end

  defp relative_age(_), do: "—"

  # --- Extraction banner -----------------------------------------------------

  attr(:extraction, :map, required: true)

  defp extraction_banner(assigns) do
    ~H"""
    <div class="absolute top-3 left-1/2 -translate-x-1/2 z-30 w-[28rem] max-w-[90vw]">
      <div class={[
        "alert shadow-lg flex items-center gap-3 py-2",
        @extraction.state == :error && "alert-error",
        @extraction.state == :done && "alert-success"
      ]}>
        <span :if={@extraction.state == :running} class="loading loading-spinner loading-sm" />
        <div class="text-sm grow min-w-0">
          <%= case @extraction.state do %>
            <% :running -> %>
              <span class="truncate">
                Extracting <span class="font-mono">{Path.basename(@extraction.repo || "")}</span>…
                <span :if={@extraction.commits > 0}>{@extraction.commits} commits</span>
              </span>
            <% :done -> %>
              Extracted <span class="font-mono">{Path.basename(@extraction.repo || "")}</span>
              ({@extraction.commits} commits).
            <% :error -> %>
              Extraction failed: {@extraction.reason}
          <% end %>
        </div>
        <button
          :if={@extraction.state != :running}
          type="button"
          phx-click="dismiss_extraction"
          class="btn btn-xs btn-ghost"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  # --- Repository picker (server-side directory browser) ---------------------

  attr(:dir, :string, required: true)
  attr(:root, :string, required: true)
  attr(:entries, :list, required: true)

  defp repo_picker(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40 flex items-center justify-center bg-black/40">
      <div
        class="bg-base-100 rounded-lg shadow-xl w-[34rem] max-w-[92vw] h-[32rem] max-h-[85vh] flex flex-col"
        phx-click-away="close_picker"
      >
        <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
          <span class="font-semibold">Open repository</span>
          <button type="button" phx-click="close_picker" class="btn btn-xs btn-ghost">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="px-4 py-2 border-b border-base-300 flex items-center gap-2 text-xs">
          <button
            type="button"
            phx-click="picker_nav"
            phx-value-path={Path.dirname(@dir)}
            disabled={@dir == @root}
            class="btn btn-xs btn-ghost"
            title="Up"
          >
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
          <span class="font-mono truncate opacity-70">{@dir}</span>
        </div>

        <ul class="overflow-y-auto grow p-2 space-y-0.5">
          <li :if={@entries == []} class="text-sm opacity-60 px-2 py-1">No subdirectories.</li>
          <li :for={e <- @entries}>
            <div class="flex items-center gap-1">
              <button
                type="button"
                phx-click="picker_nav"
                phx-value-path={e.path}
                class="grow text-left flex items-center gap-2 px-2 py-1 rounded hover:bg-base-200 min-w-0"
              >
                <.icon
                  name={if e.is_repo, do: "hero-folder-open", else: "hero-folder"}
                  class={["size-4 shrink-0", e.is_repo && "text-primary"]}
                />
                <span class="font-mono text-sm truncate">{e.name}</span>
              </button>
              <button
                :if={e.is_repo}
                type="button"
                phx-click="pick_repo"
                phx-value-path={e.path}
                class="btn btn-xs btn-primary shrink-0"
              >
                Extract
              </button>
            </div>
          </li>
        </ul>

        <div class="px-4 py-2 border-t border-base-300 text-xs opacity-60">
          Folders with a <code class="font-mono">.git</code>
          are marked; click <span class="font-semibold">Extract</span>
          to analyze.
        </div>
      </div>
    </div>
    """
  end

  # --- Directory-picker helpers ----------------------------------------------

  # Root the picker is confined to (no navigating above it). Defaults to $HOME.
  defp repo_root do
    Application.get_env(:hotspot_web, :repo_root) || System.user_home!()
  end

  defp within_root?(path, root) do
    path = Path.expand(path)
    path == root or String.starts_with?(path <> "/", root <> "/")
  end

  # Immediate subdirectories of `dir` (skipping hidden ones), each flagged for
  # whether it is itself a git repo.
  defp list_dirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()
        |> Enum.map(fn p ->
          %{name: Path.basename(p), path: p, is_repo: File.dir?(Path.join(p, ".git"))}
        end)

      {:error, _} ->
        []
    end
  end
end
