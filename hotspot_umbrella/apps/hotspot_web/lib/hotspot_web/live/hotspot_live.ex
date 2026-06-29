defmodule HotspotWeb.HotspotLive do
  @moduledoc """
  Circle-packing view of repo hotspots. Owns the visualization parameters (metric,
  color, include-removed, labels) and the shared navigation **scope**, and pushes
  the nested tree to the `CirclePack` JS hook. Reads only through `Hotspot.Analysis`,
  never the Repo.

  Scope is a single source of truth: a path (`""` is the repo root) held in
  `current_scope`. Zooming the map emits `scope_changed`; the breadcrumb and
  folder rows in the list emit `scope_to`. Both narrow the list and scatter to the
  scoped subtree without re-pushing the (full) tree, which stays loaded client-side.

  Layout is a full-height row: a docked **Controls** panel (db selection + view
  options) on the left, the chart filling the middle, and a docked **Top hotspots**
  panel on the right. Each panel collapses to a thin rail so the chart can reclaim
  the width; the chart reflows live because its SVG scales to its container.

  No db is loaded at boot: until one is selected the chart area shows a hint and the
  Controls panel lists the available databases (`Hotspot.Storage`).
  """
  use HotspotWeb, :live_view

  alias Hotspot.{Analysis, Storage}

  alias HotspotWeb.HotspotLive.{
    Chrome,
    Coupling,
    Hotspots,
    Palette,
    Picker,
    Scatter,
    TimeRange,
    XRay
  }

  @metrics [
    {"Churn", "churn"},
    {"Revisions", "revisions"},
    {"Author count", "author_count"},
    {"Recency-weighted churn", "recency_churn"}
  ]
  # Sort keys for the Top hotspots list. A superset of the size metrics: last-changed
  # is a timestamp, meaningful as a list order but not as a circle size.
  @sorts [
    {"Churn", "churn"},
    {"Revisions", "revisions"},
    {"Author count", "author_count"},
    {"Recency-weighted churn", "recency_churn"},
    {"Last changed", "last_changed"}
  ]
  # Leaf circle color encodings. "author_count" is the cool->warm ramp; "revisions" and
  # "hotspot_score" (revisions x complexity) are the heavy-tailed thermal ramps, where only
  # the top percentile heats up; "main_author" is the knowledge map (one categorical hue per
  # dominant author). The thermal ramps rank against the whole repo client-side.
  @color_modes [
    {"Author count", "author_count"},
    {"Change frequency", "revisions"},
    {"Hotspot score (change × complexity)", "hotspot_score"},
    {"Main author (knowledge map)", "main_author"}
  ]
  @top_limit 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hotspot.PubSub, storage().topic())
      Phoenix.PubSub.subscribe(Hotspot.PubSub, HotspotRunner.Job.topic())
    end

    available = Analysis.removed_filter_available?()
    complexity = Analysis.complexity_available?()
    subjects = Analysis.subjects_available?()
    root = Picker.repo_root()

    {:ok,
     assign(socket,
       metric: "churn",
       color_by: "author_count",
       color_modes: color_modes_for(complexity),
       current_scope: "",
       # Global analysis window; persists across db switches. See `TimeRange.bounds/1`.
       time_range: :all,
       # Default to excluding removed files when the db can, else include all.
       include_removed: not available,
       removed_filter_available: available,
       complexity_available: complexity,
       subjects_available: subjects,
       view_mode: "map",
       scatter: [],
       show_labels: false,
       metrics: metrics_for(complexity),
       sorts: @sorts,
       hotspots_scope: "files",
       hotspots_sort: "churn",
       hotspots: [],
       # Fuzzy finder ("go to file/folder"). `path_index` is recomputed whenever the
       # tree refreshes (db / time-range / include-removed change).
       path_index: [],
       palette_open: false,
       palette_query: "",
       palette_results: [],
       # File deep-dive overlay (nil = showing the map). Set by clicking a circle,
       # cleared by "Back to map".
       xray: nil,
       # X-Ray render preferences (sort/limits/toggles). Top-level so they persist as
       # the user drills from file to file in one session.
       xray_prefs: XRay.default_prefs(),
       # Force-directed coupling "cloud" overlay (nil = closed). Opened from the
       # X-Ray dashboard; re-rooted by clicking a node.
       coupling_graph: nil,
       # Live force-layout knobs for the coupling cloud (slider-driven). Kept at the
       # top level so tuning survives re-center, depth changes, and reopening.
       coupling_params: Coupling.default_params(),
       prefs_open: true,
       hotspots_open: true,
       dbs: storage().list(),
       current: storage().current(),
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
      color_by: params["color_by"] || socket.assigns.color_by,
      include_removed: include_removed,
      show_labels: params["show_labels"] == "true"
    )
    |> refresh()
    |> then(&{:noreply, &1})
  end

  def handle_event("set_view", %{"view" => view}, socket) when view in ["map", "scatter"] do
    # Re-push the tree when returning to the map: the CirclePack hook ignores DOM
    # updates (phx-update="ignore"), so it needs the data event to redraw.
    socket = assign(socket, view_mode: view)
    {:noreply, if(view == "map", do: push_tree(socket), else: socket)}
  end

  def handle_event("set_scope", %{"scope" => scope}, socket) do
    {:noreply, socket |> assign(hotspots_scope: scope) |> assign_hotspots()}
  end

  # A new window reshapes circle sizes, the list, and the scatter: full refresh.
  def handle_event("set_time_range", params, socket) do
    {:noreply, socket |> assign(time_range: TimeRange.parse(params)) |> refresh()}
  end

  def handle_event("set_sort", %{"sort" => sort}, socket) do
    {:noreply, socket |> assign(hotspots_sort: sort) |> assign_hotspots()}
  end

  def handle_event("open_db", %{"db" => ""}, socket), do: {:noreply, socket}

  def handle_event("open_db", %{"db" => path}, socket) do
    storage().open(path)
    {:noreply, socket}
  end

  # --- Repository picker (server-side directory browser) ---------------------
  # A native browser folder dialog can't hand the server a real filesystem path,
  # so we browse the server's filesystem here and pass the chosen absolute path
  # to the runner.

  def handle_event("open_picker", _params, socket) do
    dir = socket.assigns.picker_root

    {:noreply,
     assign(socket, picker_open: true, picker_dir: dir, picker_entries: Picker.list_dirs(dir))}
  end

  def handle_event("close_picker", _params, socket) do
    {:noreply, assign(socket, picker_open: false)}
  end

  def handle_event("picker_nav", %{"path" => path}, socket) do
    if Picker.within_root?(path, socket.assigns.picker_root) and File.dir?(path) do
      dir = Path.expand(path)
      {:noreply, assign(socket, picker_dir: dir, picker_entries: Picker.list_dirs(dir))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_repo", %{"path" => path}, socket) do
    path = Path.expand(path)

    cond do
      not Picker.within_root?(path, socket.assigns.picker_root) ->
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

  # --- Fuzzy finder ----------------------------------------------------------

  def handle_event("toggle_palette", _params, socket) do
    open = not socket.assigns.palette_open

    {:noreply,
     assign(socket,
       palette_open: open,
       palette_query: "",
       palette_results: Palette.filter(socket.assigns.path_index, "")
     )}
  end

  def handle_event("close_palette", _params, socket) do
    {:noreply, assign(socket, palette_open: false)}
  end

  def handle_event("palette_search", %{"q" => q}, socket) do
    {:noreply,
     assign(socket,
       palette_query: q,
       palette_results: Palette.filter(socket.assigns.path_index, q)
     )}
  end

  # Selecting mirrors the click grammar: a file opens its X-Ray, a folder sets scope.
  def handle_event("palette_select", %{"path" => path, "kind" => "folder"}, socket) do
    handle_event("scope_to", %{"path" => path}, assign(socket, palette_open: false))
  end

  def handle_event("palette_select", %{"path" => path, "kind" => "file"}, socket) do
    handle_event("xray", %{"path" => path}, assign(socket, palette_open: false))
  end

  def handle_event("toggle_prefs", _params, socket) do
    {:noreply, update(socket, :prefs_open, &(!&1))}
  end

  def handle_event("toggle_hotspots", _params, socket) do
    {:noreply, update(socket, :hotspots_open, &(!&1))}
  end

  # Map already zoomed client-side, so re-scope the list and scatter only: no zoom is
  # pushed back and the full tree is not re-fetched.
  def handle_event("scope_changed", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(current_scope: path)
     |> assign_hotspots()
     |> assign_scatter()}
  end

  # Scope from the breadcrumb or a folder row: adopt it, close any X-Ray, and drive
  # the map to it.
  def handle_event("scope_to", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(current_scope: path, xray: nil, view_mode: "map")
     |> assign_hotspots()
     |> assign_scatter()
     |> push_event("hotspot:zoom", %{path: path})}
  end

  # Clicking a file circle drills into it: query git live for per-region
  # metrics. The git call shells out, so run it off the LiveView process via
  # `start_async` and show a loading state meanwhile. Opens the panel too.
  def handle_event("xray", %{"path" => path}, socket) do
    case Analysis.repo_path() do
      repo when is_binary(repo) ->
        # Region history (git) + cross-file coupling (db) in one task; the file's
        # blamed source in a second task so the heatmap can render without waiting
        # on the (larger) source. Both honor the global time window.
        %{since: since, until: until} = time_window(socket)
        history_opts = [since: since, until: until]
        coupling_opts = [since: since, until: until]

        {:noreply,
         socket
         |> assign(
           xray: %{state: :loading, path: path, regions: [], complexity: file_complexity(path)}
         )
         |> start_async({:xray, path}, fn ->
           {HotspotRunner.Xray.file_history(repo, path, history_opts),
            Analysis.coupling(path, coupling_opts)}
         end)
         |> start_async({:xray_source, path}, fn -> HotspotRunner.Xray.file_source(repo, path) end)}

      _ ->
        {:noreply,
         assign(socket,
           xray: %{state: :error, path: path, reason: "No repository path on this database."}
         )}
    end
  end

  def handle_event("close_xray", _params, socket) do
    {:noreply, assign(socket, xray: nil)}
  end

  # Open the force-directed coupling "cloud" for the X-Rayed file (default depth 2).
  def handle_event("open_coupling_graph", %{"path" => path}, socket) do
    {:noreply, start_graph(socket, path, 2)}
  end

  # Depth selector in the cloud overlay: re-expand at the new hop count.
  def handle_event(
        "set_graph_depth",
        %{"depth" => depth},
        %{assigns: %{coupling_graph: %{path: path}}} = socket
      ) do
    {:noreply, start_graph(socket, path, Coupling.to_depth(depth))}
  end

  # Clicking a node re-roots the cloud on that file, keeping the current depth.
  def handle_event(
        "recenter",
        %{"path" => path},
        %{assigns: %{coupling_graph: %{depth: depth}}} = socket
      ) do
    {:noreply, start_graph(socket, path, depth)}
  end

  def handle_event("close_coupling_graph", _params, socket) do
    {:noreply, assign(socket, coupling_graph: nil)}
  end

  # The hook came alive (or remounted): re-send the current graph if it's ready.
  def handle_event(
        "coupling:ready",
        _params,
        %{assigns: %{coupling_graph: %{state: :ready, data: data}}} = socket
      ) do
    {:noreply, push_graph(socket, data)}
  end

  def handle_event("coupling:ready", _params, socket), do: {:noreply, socket}

  # Slider moved in the "Forces" panel: cast the changed field(s) and push the merged
  # set to the hook, which re-tunes the live simulation without refetching data.
  def handle_event("set_coupling_params", params, socket) do
    merged = Coupling.merge_params(socket.assigns.coupling_params, params)
    {:noreply, socket |> assign(coupling_params: merged) |> push_event("coupling:params", merged)}
  end

  def handle_event("reset_coupling_params", _params, socket) do
    defaults = Coupling.default_params()

    {:noreply,
     socket |> assign(coupling_params: defaults) |> push_event("coupling:params", defaults)}
  end

  # X-Ray controls: pure view preferences over already-fetched data, so re-rendering
  # the dashboard applies them (no async, no push to the client).
  def handle_event("set_xray_view", params, socket) do
    {:noreply, assign(socket, xray_prefs: XRay.merge_prefs(socket.assigns.xray_prefs, params))}
  end

  def handle_event("reset_xray_view", _params, socket) do
    {:noreply, assign(socket, xray_prefs: XRay.default_prefs())}
  end

  @impl true
  # Region history + coupling. Merge (not replace) so a source result that already
  # arrived isn't clobbered; both clauses guard on the still-current path.
  def handle_async({:xray, path}, result, socket) do
    patch =
      case result do
        {:ok, {{:ok, history}, coupling}} ->
          Map.merge(history, %{state: :ready, coupling: coupling_list(coupling)})

        {:ok, {{:error, reason}, _coupling}} ->
          %{state: :error, reason: reason}

        {:exit, reason} ->
          %{state: :error, reason: inspect(reason)}
      end

    {:noreply, merge_xray(socket, path, patch)}
  end

  # Blamed source arrives independently; stash it under `:source`.
  def handle_async({:xray_source, path}, result, socket) do
    source =
      case result do
        {:ok, {:ok, src}} -> src
        _ -> %{lines: [], total: 0}
      end

    {:noreply, merge_xray(socket, path, %{source: source})}
  end

  # Coupling-graph build finished. Push to the hook only if the result still matches
  # the open overlay's path+depth (a fast click could have superseded it).
  def handle_async({:coupling_graph, path, depth}, result, socket) do
    case {socket.assigns.coupling_graph, result} do
      {%{path: ^path, depth: ^depth} = cg, {:ok, %{nodes: _} = graph}} ->
        {:noreply,
         socket
         |> assign(coupling_graph: %{cg | state: :ready, data: graph})
         |> push_graph(graph)}

      {%{path: ^path, depth: ^depth} = cg, _} ->
        {:noreply, assign(socket, coupling_graph: %{cg | state: :error})}

      _ ->
        {:noreply, socket}
    end
  end

  # Set the loading overlay and kick off the (db-bound) graph build off-process.
  defp start_graph(socket, path, depth) do
    %{since: since, until: until} = time_window(socket)

    socket
    |> assign(coupling_graph: %{state: :loading, path: path, depth: depth, data: nil})
    |> start_async({:coupling_graph, path, depth}, fn ->
      Analysis.coupling_graph(path, depth: depth, since: since, until: until)
    end)
  end

  # Apply a patch to the live X-Ray assign only if it still targets `path`.
  defp merge_xray(socket, path, patch) do
    case socket.assigns.xray do
      %{path: ^path} = xray -> assign(socket, xray: Map.merge(xray, patch))
      _ -> socket
    end
  end

  # `Analysis.coupling/2` returns `{:error, :no_database}` when no db is open.
  defp coupling_list(rows) when is_list(rows), do: rows
  defp coupling_list(_), do: []

  # Push the graph to the hook with the live force params folded in, so a (re)mount or
  # rebuild initializes the simulation at the current slider values rather than defaults.
  defp push_graph(socket, graph) do
    push_event(socket, "coupling:graph", Map.put(graph, :params, socket.assigns.coupling_params))
  end

  @impl true
  def handle_info({:storage_changed, current}, socket) do
    # Scope is repo-specific, so reset it on a db switch; other prefs persist.
    # Removed-filter availability is per-db, so recompute it and its default.
    available = Analysis.removed_filter_available?()
    complexity = Analysis.complexity_available?()
    subjects = Analysis.subjects_available?()

    socket =
      assign(socket,
        current: current,
        dbs: storage().list(),
        # Scope is repo-specific, so reset to the repo root on a db switch.
        current_scope: "",
        # X-Ray paths are repo-specific, so clear it on a db switch.
        xray: nil,
        removed_filter_available: available,
        complexity_available: complexity,
        subjects_available: subjects,
        color_modes: color_modes_for(complexity),
        color_by: keep_color_by(socket.assigns.color_by, complexity),
        metrics: metrics_for(complexity),
        # A non-complexity db can't show the scatter; fall back to the map.
        view_mode: if(complexity, do: socket.assigns.view_mode, else: "map"),
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

  # Recompute the views after a parameter change: push the map tree to the hook,
  # assign the ranked list, and assign the scatter points.
  defp refresh(%{assigns: %{current: nil}} = socket), do: socket

  defp refresh(socket) do
    socket
    |> push_tree()
    |> assign_hotspots()
    |> assign_scatter()
    |> assign_path_index()
  end

  defp assign_path_index(socket) do
    params = Map.merge(%{include_removed: socket.assigns.include_removed}, time_window(socket))

    index =
      case Analysis.path_index(params) do
        {:error, :no_database} -> []
        rows -> rows
      end

    socket
    |> assign(path_index: index)
    |> assign(palette_results: Palette.filter(index, socket.assigns.palette_query))
  end

  defp assign_scatter(%{assigns: %{complexity_available: false}} = socket),
    do: assign(socket, scatter: [])

  defp assign_scatter(socket) do
    params =
      Map.merge(
        %{
          include_removed: socket.assigns.include_removed,
          path_filter: socket.assigns.current_scope
        },
        time_window(socket)
      )

    scatter =
      case Analysis.complexity_scatter(params) do
        {:error, :no_database} -> []
        rows -> rows
      end

    assign(socket, scatter: scatter)
  end

  defp push_tree(socket) do
    # Always the full tree: scope is a client-side zoom, not a server-side filter, so
    # the hook keeps the whole hierarchy loaded and re-roots without a round-trip.
    params = Map.merge(%{include_removed: socket.assigns.include_removed}, time_window(socket))

    case Analysis.tree_for_visualization(params) do
      {:error, :no_database} ->
        socket

      tree ->
        push_event(socket, "hotspot:tree", %{
          tree: tree,
          metric: socket.assigns.metric,
          color_by: socket.assigns.color_by,
          labels: socket.assigns.show_labels
        })
    end
  end

  # Size encodings. LOC needs the complexity snapshot, so it is offered only when
  # the db carries it (older dbs hide the option rather than sizing everything to 0).
  defp metrics_for(true),
    do: @metrics ++ [{"Lines of code", "loc"}, {"Complexity (indentation)", "indent_total"}]

  defp metrics_for(false), do: @metrics

  # Color encodings. Hotspot score multiplies revisions by complexity, so it is offered
  # only when the db carries the complexity snapshot.
  defp color_modes_for(true), do: @color_modes

  defp color_modes_for(false),
    do: Enum.reject(@color_modes, fn {_, v} -> v == "hotspot_score" end)

  # On a db switch that drops complexity, an active hotspot-score coloring would have no
  # matching option and tint everything cold; fall back to the default ramp.
  defp keep_color_by("hotspot_score", false), do: "author_count"
  defp keep_color_by(color_by, _complexity), do: color_by

  # The current file's complexity for the X-Ray header, or nil (older db, binary, absent).
  defp file_complexity(path) do
    case Analysis.file_complexity(path) do
      m when is_map(m) -> m
      _ -> nil
    end
  end

  defp assign_hotspots(%{assigns: %{current: nil}} = socket), do: assign(socket, hotspots: [])

  defp assign_hotspots(socket) do
    params =
      Map.merge(
        %{
          sort: socket.assigns.hotspots_sort,
          scope: socket.assigns.hotspots_scope,
          include_removed: socket.assigns.include_removed,
          path_filter: socket.assigns.current_scope,
          limit: @top_limit
        },
        time_window(socket)
      )

    hotspots =
      case Analysis.ownership(params) do
        {:error, :no_database} -> []
        rows -> merge_defects(rows, socket.assigns.subjects_available, params)
      end

    assign(socket, hotspots: hotspots)
  end

  # Fold each file's bug-fix density into its row when the db carries subjects.
  defp merge_defects(rows, false, _params), do: rows

  defp merge_defects(rows, true, params) do
    density =
      case Analysis.defect_density(params) do
        {:error, :no_database} -> %{}
        map -> map
      end

    Enum.map(rows, &Map.put(&1, :bug_fix_density, Map.get(density, &1.path, 0.0)))
  end

  # --- Time range ------------------------------------------------------------

  defp time_window(socket), do: TimeRange.window(socket.assigns.time_range)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col overflow-hidden">
      <Picker.extraction_banner :if={@extraction} extraction={@extraction} />
      <Picker.repo_picker
        :if={@picker_open}
        dir={@picker_dir}
        root={@picker_root}
        entries={@picker_entries}
      />

      <%!-- Captures Ctrl/Cmd+P globally to toggle the fuzzy finder (see the Palette hook). --%>
      <div id="palette-key" phx-hook="Palette" class="hidden"></div>
      <Palette.command_palette
        :if={@palette_open}
        query={@palette_query}
        results={@palette_results}
      />

      <Chrome.top_bar dbs={@dbs} current={@current} scope={@current_scope} time_range={@time_range} />

      <div class="flex-1 flex overflow-hidden min-h-0">
        <Chrome.panel
          open={@prefs_open}
          side="left"
          title={Chrome.view_panel_title(@coupling_graph, @xray)}
          toggle="toggle_prefs"
        >
          <Coupling.coupling_controls :if={@coupling_graph} params={@coupling_params} />
          <XRay.xray_controls :if={is_nil(@coupling_graph) and @xray} prefs={@xray_prefs} />
          <Chrome.controls
            :if={is_nil(@coupling_graph) and is_nil(@xray)}
            metric={@metric}
            metrics={@metrics}
            color_by={@color_by}
            color_modes={@color_modes}
            include_removed={@include_removed}
            removed_filter_available={@removed_filter_available}
            show_labels={@show_labels}
          />
        </Chrome.panel>

        <div class="flex-1 relative min-w-0 bg-base-100">
          <%!-- Map/scatter toggle, shown only when the db carries complexity metrics. --%>
          <div
            :if={@current && @complexity_available}
            class="absolute top-2 left-1/2 -translate-x-1/2 z-10 join shadow"
          >
            <button
              type="button"
              phx-click="set_view"
              phx-value-view="map"
              class={["btn btn-xs join-item", @view_mode == "map" && "btn-active"]}
            >
              Map
            </button>
            <button
              type="button"
              phx-click="set_view"
              phx-value-view="scatter"
              class={["btn btn-xs join-item", @view_mode == "scatter" && "btn-active"]}
            >
              Scatter
            </button>
          </div>

          <%!-- The hook stays mounted across view switches; we only toggle the wrapper's
        visibility. The class must live on the wrapper, not the hook element: LiveView
        skips attribute patches on a phx-update="ignore" node, so a class toggled there
        would never apply. --%>
          <div :if={@current} class={["w-full h-full", @view_mode == "scatter" && "hidden"]}>
            <div id="hotspot-chart" phx-hook="CirclePack" phx-update="ignore" class="w-full h-full">
            </div>
          </div>

          <Scatter.scatter_plot :if={@current && @view_mode == "scatter"} points={@scatter} />

          <div :if={is_nil(@current)} class="h-full flex items-center justify-center px-6">
            <p class="text-sm opacity-60 text-center">
              ↑ Open a database from the <span class="font-semibold">top bar</span> to see hotspots.
            </p>
          </div>

          <%!-- A selected file overlays its deep-dive on top of the (still-mounted) circle pack. --%>
          <XRay.file_dashboard
            :if={@current && @xray && @xray.state in [:loading, :ready, :error]}
            xray={@xray}
            prefs={@xray_prefs}
          />

          <%!-- The coupling cloud overlays the X-Ray dashboard when opened. --%>
          <Coupling.coupling_graph_view :if={@current && @coupling_graph} graph={@coupling_graph} />
        </div>

        <Chrome.panel open={@hotspots_open} side="right" title="Top hotspots" toggle="toggle_hotspots">
          <Hotspots.top_hotspots
            current={@current}
            scope={@hotspots_scope}
            sort={@hotspots_sort}
            sorts={@sorts}
            hotspots={@hotspots}
          />
        </Chrome.panel>
      </div>
    </div>
    """
  end

  defp storage, do: Application.get_env(:hotspot, :storage, Storage)
end
