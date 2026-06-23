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
  # Leaf circle color encodings. "author_count" is the cool->warm ramp; "main_author"
  # is the knowledge map (one categorical hue per dominant author).
  @color_modes [
    {"Author count", "author_count"},
    {"Main author (knowledge map)", "main_author"}
  ]
  @top_limit 25

  # Preset analysis windows for the top-bar time-range control. "custom" is added
  # by the control itself (a from/to date pair); see `parse_time_range/1`.
  @time_presets [
    {"All time", "all"},
    {"Last 12 months", "y1"},
    {"Last 6 months", "m6"},
    {"Last 3 months", "m3"},
    {"Last 30 days", "m1"}
  ]
  @seconds_per_day 86_400

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hotspot.PubSub, Storage.topic())
      Phoenix.PubSub.subscribe(Hotspot.PubSub, HotspotRunner.Job.topic())
    end

    available = Analysis.removed_filter_available?()
    complexity = Analysis.complexity_available?()
    subjects = Analysis.subjects_available?()
    root = repo_root()

    {:ok,
     assign(socket,
       metric: "churn",
       color_by: "author_count",
       color_modes: @color_modes,
       current_scope: "",
       # Global analysis window; persists across db switches. See `time_bounds/1`.
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
       # Force-directed coupling "cloud" overlay (nil = closed). Opened from the
       # X-Ray dashboard; re-rooted by clicking a node.
       coupling_graph: nil,
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

  # Global time-range change: reshapes circle sizes, the list, and the scatter, so a
  # full refresh (which re-pushes the tree) is needed.
  def handle_event("set_time_range", params, socket) do
    {:noreply, socket |> assign(time_range: parse_time_range(params)) |> refresh()}
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

  # --- Fuzzy finder ----------------------------------------------------------

  def handle_event("toggle_palette", _params, socket) do
    open = not socket.assigns.palette_open

    {:noreply,
     assign(socket,
       palette_open: open,
       palette_query: "",
       palette_results: palette_filter(socket.assigns.path_index, "")
     )}
  end

  def handle_event("close_palette", _params, socket) do
    {:noreply, assign(socket, palette_open: false)}
  end

  def handle_event("palette_search", %{"q" => q}, socket) do
    {:noreply,
     assign(socket,
       palette_query: q,
       palette_results: palette_filter(socket.assigns.path_index, q)
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

  # The map zoomed (user clicked a folder or the background): adopt the new scope and
  # re-scope the list + scatter. The map already moved client-side, so no zoom is
  # pushed back and the (full) tree is not re-fetched.
  def handle_event("scope_changed", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(current_scope: path)
     |> assign_hotspots()
     |> assign_scatter()}
  end

  # Scope set from the breadcrumb or a folder row: adopt it, then drive the map to it.
  # Make the map visible first (close any X-Ray overlay, leave the scatter); the hook
  # kept its drawing across the switch (phx-update="ignore"), so the pushed zoom lands
  # without a re-fetch.
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
    {:noreply, start_graph(socket, path, to_depth(depth))}
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
    {:noreply, push_event(socket, "coupling:graph", data)}
  end

  def handle_event("coupling:ready", _params, socket), do: {:noreply, socket}

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
         |> push_event("coupling:graph", graph)}

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

  defp to_depth(depth) do
    case Integer.parse(to_string(depth)) do
      {n, _} -> n |> max(1) |> min(3)
      :error -> 2
    end
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
        dbs: Storage.list(),
        # Scope is repo-specific, so reset to the repo root on a db switch.
        current_scope: "",
        # X-Ray paths are repo-specific, so clear it on a db switch.
        xray: nil,
        removed_filter_available: available,
        complexity_available: complexity,
        subjects_available: subjects,
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
    |> assign(palette_results: palette_filter(index, socket.assigns.palette_query))
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
  defp metrics_for(true), do: @metrics ++ [{"Lines of code", "loc"}]
  defp metrics_for(false), do: @metrics

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

  defp time_presets, do: @time_presets

  # `:since`/`:until` params for the current window, ready to merge into a query
  # params map.
  defp time_window(socket) do
    {since, until} = time_bounds(socket.assigns.time_range)
    %{since: since, until: until}
  end

  # Resolve a stored range to inclusive `{since, until}` epoch bounds; `nil` is open.
  defp time_bounds(:all), do: {nil, nil}
  defp time_bounds(:y1), do: {days_ago(365), nil}
  defp time_bounds(:m6), do: {days_ago(182), nil}
  defp time_bounds(:m3), do: {days_ago(91), nil}
  defp time_bounds(:m1), do: {days_ago(30), nil}
  defp time_bounds({:custom, from, until}), do: {from, until}
  defp time_bounds(_), do: {nil, nil}

  defp days_ago(n), do: System.os_time(:second) - n * @seconds_per_day

  # Parse the time-range form into a stored range. "custom" carries from/to dates
  # (start-of-day / end-of-day, UTC); blanks stay open-ended.
  defp parse_time_range(%{"preset" => "custom"} = params) do
    {:custom, parse_date(params["from"], :start), parse_date(params["to"], :end)}
  end

  defp parse_time_range(%{"preset" => preset}), do: preset_atom(preset)
  defp parse_time_range(_), do: :all

  defp preset_atom("y1"), do: :y1
  defp preset_atom("m6"), do: :m6
  defp preset_atom("m3"), do: :m3
  defp preset_atom("m1"), do: :m1
  defp preset_atom(_), do: :all

  defp parse_date(date, _edge) when date in [nil, ""], do: nil

  defp parse_date(date, edge) do
    case Date.from_iso8601(date) do
      {:ok, d} ->
        time = if edge == :end, do: ~T[23:59:59], else: ~T[00:00:00]
        d |> DateTime.new!(time, "Etc/UTC") |> DateTime.to_unix()

      _ ->
        nil
    end
  end

  # The select's option value for the stored range; `{:custom, ...}` -> "custom".
  defp time_range_key({:custom, _, _}), do: "custom"
  defp time_range_key(range), do: to_string(range)

  # The from/to date strings to pre-fill the custom inputs, else blanks.
  defp custom_dates({:custom, from, until}), do: {date_str(from), date_str(until)}
  defp custom_dates(_), do: {"", ""}

  defp date_str(nil), do: ""

  defp date_str(epoch),
    do: epoch |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()

  # --- Fuzzy finder ----------------------------------------------------------

  @palette_limit 50

  # Rank index entries against the query. Empty query shows the first N entries; a
  # substring match ranks above a looser subsequence match; ties break on path length.
  defp palette_filter(index, query) do
    case String.trim(query) do
      "" ->
        Enum.take(index, @palette_limit)

      q ->
        q = String.downcase(q)

        index
        |> Enum.flat_map(fn e ->
          case fuzzy_score(String.downcase(e.path), q) do
            nil -> []
            score -> [{score, e}]
          end
        end)
        |> Enum.sort_by(fn {score, e} -> {score, String.length(e.path)} end)
        |> Enum.take(@palette_limit)
        |> Enum.map(&elem(&1, 1))
    end
  end

  # Lower is better: a substring match (ranked by its position) beats a subsequence
  # match; `nil` when the query is not even a subsequence.
  defp fuzzy_score(path, q) do
    case :binary.match(path, q) do
      {pos, _} -> {0, pos}
      :nomatch -> if subsequence?(path, q), do: {1, 0}, else: nil
    end
  end

  defp subsequence?(_path, ""), do: true
  defp subsequence?("", _q), do: false

  defp subsequence?(<<ch::utf8, prest::binary>>, <<ch::utf8, qrest::binary>>),
    do: subsequence?(prest, qrest)

  defp subsequence?(<<_::utf8, prest::binary>>, q), do: subsequence?(prest, q)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col overflow-hidden">
      <.extraction_banner :if={@extraction} extraction={@extraction} />
      <.repo_picker
        :if={@picker_open}
        dir={@picker_dir}
        root={@picker_root}
        entries={@picker_entries}
      />

      <%!-- Captures Ctrl/Cmd+P globally to toggle the fuzzy finder (see the Palette hook). --%>
      <div id="palette-key" phx-hook="Palette" class="hidden"></div>
      <.command_palette
        :if={@palette_open}
        query={@palette_query}
        results={@palette_results}
      />

      <.top_bar dbs={@dbs} current={@current} scope={@current_scope} time_range={@time_range} />

      <div class="flex-1 flex overflow-hidden min-h-0">
        <.panel open={@prefs_open} side="left" title="View" toggle="toggle_prefs">
          <.controls
            metric={@metric}
            metrics={@metrics}
            color_by={@color_by}
            color_modes={@color_modes}
            include_removed={@include_removed}
            removed_filter_available={@removed_filter_available}
            show_labels={@show_labels}
          />
        </.panel>

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

          <.scatter_plot :if={@current && @view_mode == "scatter"} points={@scatter} />

          <div :if={is_nil(@current)} class="h-full flex items-center justify-center px-6">
            <p class="text-sm opacity-60 text-center">
              ↑ Open a database from the <span class="font-semibold">top bar</span> to see hotspots.
            </p>
          </div>

          <%!-- A selected file overlays its deep-dive on top of the (still-mounted) circle pack. --%>
          <.file_dashboard
            :if={@current && @xray && @xray.state in [:loading, :ready, :error]}
            xray={@xray}
          />

          <%!-- The coupling cloud overlays the X-Ray dashboard when opened. --%>
          <.coupling_graph_view :if={@current && @coupling_graph} graph={@coupling_graph} />
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
    </div>
    """
  end

  # --- File dashboard (overlays the chart while X-Ray is open) ---------------
  # Behavioral view of one file: a region×time churn heatmap (hottest rows on top;
  # rows hot in the same columns are entangled), a cohesion verdict, and the files
  # this one changes together with (temporal coupling).

  attr(:xray, :map, required: true)

  defp file_dashboard(assigns) do
    ready = assigns.xray.state == :ready
    regions = if ready, do: Enum.take(assigns.xray.regions, 30), else: []
    maxcell = regions |> Enum.flat_map(& &1.heat) |> Enum.max(fn -> 0 end)

    assigns =
      assign(assigns,
        ready: ready,
        regions: regions,
        maxcell: max(maxcell, 1),
        extra: if(ready, do: length(assigns.xray.regions) - length(regions), else: 0)
      )

    ~H"""
    <div class="absolute inset-0 z-10 bg-base-100 flex flex-col">
      <div class="sticky top-0 z-10 flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-100/95 backdrop-blur">
        <button type="button" phx-click="close_xray" class="btn btn-sm btn-ghost gap-1">
          <.icon name="hero-arrow-left" class="size-4" /> Back to map
        </button>
        <span class="font-mono text-xs truncate opacity-70" title={@xray.path}>
          {Path.basename(@xray.path)}
        </span>
        <button
          :if={@ready}
          type="button"
          phx-click="open_coupling_graph"
          phx-value-path={@xray.path}
          class="btn btn-sm btn-ghost gap-1 ml-auto"
          title="Explore this file's coupling neighbourhood as a graph"
        >
          <.icon name="hero-share" class="size-4" /> Coupling graph
        </button>
      </div>

      <div class="grow overflow-auto">
        <div
          :if={!@ready and @xray.state == :loading}
          class="h-full flex items-center justify-center gap-2 text-sm opacity-70"
        >
          <span class="loading loading-spinner loading-sm" />
          Analyzing <span class="font-mono">{Path.basename(@xray.path)}</span>…
        </div>

        <div :if={@xray.state == :error} class="h-full flex items-center justify-center px-6">
          <p class="text-sm text-error text-center">{@xray.reason}</p>
        </div>

        <div :if={@ready} class="flex flex-col lg:flex-row gap-4 p-4 h-full">
          <div class="lg:w-[34rem] lg:shrink-0 space-y-5">
            <div>
              <div class="font-mono text-sm truncate" title={@xray.path}>{@xray.path}</div>
              <div class="text-xs opacity-60 mt-1 flex flex-wrap gap-x-4 gap-y-1">
                <span>{length(@xray.regions)} regions</span>
                <span :if={@xray.span}>
                  active {relative_age(@xray.span.first)} → {relative_age(@xray.span.last)}
                </span>
                <span title="average distinct regions touched per commit">
                  cohesion {@xray.cohesion.regions_per_commit}/commit · {cohesion_verdict(
                    @xray.cohesion.regions_per_commit
                  )}
                </span>
                <span :if={@xray[:complexity]} title="current size and indentation complexity">
                  {@xray.complexity.loc} LOC · indent avg {Float.round(@xray.complexity.indent_avg, 1)} · max {@xray.complexity.indent_max}
                </span>
              </div>
            </div>

            <p :if={@regions == []} class="text-sm opacity-60">No attributable changes to chart.</p>

            <div :if={@regions != []}>
              <div class="text-xs opacity-60 mb-2">
                Changed regions over time: hotter cells = more churn; rows hot in the
                same columns tend to be entangled. Click a region for its commits.
              </div>
              <div class="overflow-x-auto">
                <ol class="space-y-0.5 min-w-fit">
                  <li :for={r <- @regions}>
                    <details class="rounded hover:bg-base-200 [&_summary::-webkit-details-marker]:hidden">
                      <summary class="flex items-center gap-2 px-1 py-0.5 cursor-pointer list-none">
                        <span
                          class="font-mono text-xs truncate w-48 shrink-0 flex items-center gap-1"
                          title={r.name}
                        >
                          <span class="truncate">{r.name}</span>
                          <span
                            :if={r.name == unattributed_name()}
                            title={unattributed_help()}
                            class="shrink-0"
                          >
                            <.icon name="hero-information-circle" class="size-3 opacity-60" />
                          </span>
                        </span>
                        <span class="flex gap-px shrink-0">
                          <span
                            :for={v <- r.heat}
                            class="w-3 h-3 rounded-sm"
                            style={heat_style(v, @maxcell)}
                            title={"churn #{v}"}
                          />
                        </span>
                        <span class="text-[11px] opacity-60 whitespace-nowrap ml-auto pl-2">
                          {r.churn} · {r.author_count}a
                          <span
                            :if={owner_risk?(r)}
                            class="text-warning"
                            title={"#{round(r.top_author_share * 100)}% by #{author_label(r.top_author)}: knowledge risk"}
                          >⚠</span>
                        </span>
                      </summary>

                      <ul class="pl-48 pr-2 pt-1 pb-2 space-y-0.5">
                        <li
                          :for={c <- Enum.take(r.commits, 15)}
                          class="flex items-center gap-2 text-[11px]"
                        >
                          <span class="font-mono opacity-60 shrink-0">{short_sha(c.sha)}</span>
                          <span class="truncate grow opacity-70" title={c.author}>{author_label(
                            c.author
                          )}</span>
                          <span class="opacity-50 shrink-0">{relative_age(c.committed_at)}</span>
                          <span class="opacity-70 shrink-0 tabular-nums">+{c.churn}</span>
                        </li>
                        <li :if={length(r.commits) > 15} class="text-[11px] opacity-40 pl-1">
                          + {length(r.commits) - 15} more
                        </li>
                      </ul>
                    </details>
                  </li>
                </ol>
              </div>
              <div
                :if={@xray.buckets != []}
                class="flex justify-between text-[11px] opacity-50 mt-1"
                style="margin-left: 12.5rem; max-width: 13rem"
              >
                <span>{List.first(@xray.buckets).label}</span>
                <span>{List.last(@xray.buckets).label}</span>
              </div>
              <p :if={@extra > 0} class="text-[11px] opacity-40 mt-1">+ {@extra} more regions</p>
              <p class="text-[11px] opacity-40 mt-3 leading-snug">
                Regions are git diff section headings: accurate for languages git has a
                driver for, approximate otherwise.
              </p>
            </div>

            <div :if={@xray.coupling != []}>
              <div class="text-xs opacity-60 mb-2">
                Changes together with (temporal coupling, share of this file's commits)
              </div>
              <ul class="space-y-1 max-w-2xl">
                <li :for={c <- @xray.coupling}>
                  <button
                    type="button"
                    phx-click="xray"
                    phx-value-path={c.path}
                    class="w-full flex items-center gap-2 text-left px-1 py-0.5 rounded hover:bg-base-200"
                    title={"drill into #{c.path}"}
                  >
                    <span class="font-mono text-xs truncate grow">{c.path}</span>
                    <span
                      class="h-1.5 rounded bg-primary/60 shrink-0"
                      style={"width: #{round(c.coupling * 60)}px"}
                    />
                    <span class="text-[11px] opacity-60 shrink-0 w-24 text-right">
                      {round(c.coupling * 100)}% · {c.shared_commits}c
                    </span>
                  </button>
                </li>
              </ul>
            </div>
            <p :if={@xray.coupling == []} class="text-xs opacity-40">
              No notable cross-file coupling.
            </p>
          </div>

          <div class="grow min-w-0 lg:h-full">
            <.source_pane source={@xray[:source]} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Coupling graph ("cloud") overlay --------------------------------------
  # Force-directed neighbourhood of the X-Rayed file: nodes are files, an edge means
  # they change together, node color ramps with how often a file is coupled (hubs run
  # hot). Layout + interaction live in the `CouplingGraph` JS hook; this just frames
  # it with a header, a depth selector, and the mount point.

  attr(:graph, :map, required: true)

  defp coupling_graph_view(assigns) do
    ~H"""
    <div class="absolute inset-0 z-20 bg-base-100 flex flex-col">
      <div class="sticky top-0 z-10 flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-100/95 backdrop-blur">
        <button type="button" phx-click="close_coupling_graph" class="btn btn-sm btn-ghost gap-1">
          <.icon name="hero-arrow-left" class="size-4" /> Back to X-Ray
        </button>
        <span class="font-mono text-xs truncate opacity-70" title={@graph.path}>
          {Path.basename(@graph.path)} · coupling cloud
        </span>
        <form phx-change="set_graph_depth" class="ml-auto flex items-center gap-2 text-xs opacity-70">
          <label for="graph-depth">depth</label>
          <select id="graph-depth" name="depth" class="select select-xs select-bordered">
            <option :for={d <- 1..3} value={d} selected={d == @graph.depth}>{d}</option>
          </select>
        </form>
      </div>

      <div class="grow relative min-h-0">
        <div
          :if={@graph.state == :loading}
          class="absolute inset-0 flex items-center justify-center gap-2 text-sm opacity-70 z-10"
        >
          <span class="loading loading-spinner loading-sm" /> Building coupling cloud…
        </div>
        <div
          :if={@graph.state == :error}
          class="absolute inset-0 flex items-center justify-center px-6 text-sm text-error z-10"
        >
          Could not build the coupling cloud.
        </div>

        <%!-- Kept mounted across depth/recenter changes; new data arrives via push_event. --%>
        <div id="coupling-graph" phx-hook="CouplingGraph" phx-update="ignore" class="w-full h-full">
        </div>

        <div class="absolute bottom-2 left-3 text-[11px] opacity-50 leading-snug max-w-md">
          Files that change together. Hotter = coupled to more files. Drag to nudge;
          click a node to re-center the cloud on it.
        </div>
      </div>
    </div>
    """
  end

  # --- Source pane (blamed file in the X-Ray free area) ----------------------
  # Current source, each line tinted by age (recent = warm) and carrying its
  # last-change commit as a hover tooltip (sha · age · author + summary/reason).

  attr(:source, :map, default: nil)

  defp source_pane(assigns) do
    src = assigns.source
    lines = (src && src.lines) || []
    times = lines |> Enum.map(& &1.time) |> Enum.reject(&(&1 == 0))
    {tmin, tmax} = if(times == [], do: {0, 1}, else: {Enum.min(times), Enum.max(times)})

    assigns =
      assign(assigns,
        lines: lines,
        loading: is_nil(src),
        total: (src && src.total) || 0,
        tmin: tmin,
        tmax: max(tmax, tmin + 1)
      )

    ~H"""
    <div class="h-full flex flex-col min-h-0">
      <div class="text-xs opacity-60 mb-2">
        Source: lines tinted by age; hover for the change reason
      </div>

      <div :if={@loading} class="text-sm opacity-60">Loading source…</div>

      <p :if={!@loading and @lines == []} class="text-sm opacity-60">
        No source to show (binary file or not present at HEAD).
      </p>

      <div
        :if={@lines != []}
        class="grow min-h-0 overflow-auto rounded border border-base-300 bg-base-200/40"
      >
        <table class="font-mono text-xs leading-5 w-full">
          <tbody>
            <tr
              :for={l <- @lines}
              style={age_heat_style(l.time, @tmin, @tmax)}
              title={"#{short_sha(l.sha)} · #{relative_age(l.time)} · #{l.author}\n#{l.summary}"}
            >
              <td class="px-2 text-right opacity-40 select-none align-top w-12">{l.line}</td>
              <td class="pr-3 whitespace-pre">{l.code}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@total > length(@lines)} class="text-[11px] opacity-40 mt-1">
        showing first {length(@lines)} of {@total} lines
      </p>
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

  # --- Top bar ---------------------------------------------------------------
  # Repository/database management, the scope breadcrumb, and the theme toggle.

  attr(:dbs, :list, required: true)
  attr(:current, :string, default: nil)
  attr(:scope, :string, required: true)
  attr(:time_range, :any, required: true)

  defp top_bar(assigns) do
    {from_str, to_str} = custom_dates(assigns.time_range)

    assigns =
      assign(assigns, preset: time_range_key(assigns.time_range), from: from_str, to: to_str)

    ~H"""
    <header class="shrink-0 h-12 flex items-center gap-3 px-3 border-b border-base-300 bg-base-200">
      <span class="font-semibold text-sm whitespace-nowrap">Hotspot</span>

      <form id="db-form" phx-change="open_db" class="shrink-0">
        <select name="db" class="select select-bordered select-sm" title="Open database">
          <option value="" disabled selected={is_nil(@current)}>Choose database…</option>
          <option :for={db <- @dbs} value={db.path} selected={@current == db.path}>
            {db.name}
          </option>
        </select>
      </form>

      <button type="button" phx-click="open_picker" class="btn btn-sm btn-primary shrink-0">
        <.icon name="hero-folder-open" class="size-4" /> Open repository…
      </button>

      <%!-- Breadcrumb of the current scope; clicking a crumb re-roots the map there. --%>
      <.breadcrumb :if={@current} scope={@scope} />

      <div class="ml-auto flex items-center gap-2 shrink-0">
        <button
          :if={@current}
          type="button"
          phx-click="toggle_palette"
          class="btn btn-sm btn-ghost gap-1"
          title="Go to file or folder"
        >
          <.icon name="hero-magnifying-glass" class="size-4" />
          <kbd class="kbd kbd-sm hidden sm:inline">⌘P</kbd>
        </button>

        <%!-- Global analysis window. "Custom…" reveals a from/to date pair. --%>
        <form
          phx-change="set_time_range"
          class="flex items-center gap-1 text-xs"
          title="Analysis time range"
        >
          <.icon name="hero-clock" class="size-4 opacity-60" />
          <select name="preset" class="select select-bordered select-xs">
            <option :for={{label, value} <- time_presets()} value={value} selected={value == @preset}>
              {label}
            </option>
            <option value="custom" selected={@preset == "custom"}>Custom…</option>
          </select>
          <input
            :if={@preset == "custom"}
            type="date"
            name="from"
            value={@from}
            class="input input-bordered input-xs"
          />
          <input
            :if={@preset == "custom"}
            type="date"
            name="to"
            value={@to}
            class="input input-bordered input-xs"
          />
        </form>

        <Layouts.theme_toggle />
      </div>
    </header>
    """
  end

  # --- Scope breadcrumb ------------------------------------------------------
  # Trail of the current scope path. Each crumb re-roots the map (and the list)
  # at that ancestor via `scope_to`; the leading "root" crumb resets to `""`.

  attr(:scope, :string, required: true)

  defp breadcrumb(assigns) do
    assigns = assign(assigns, crumbs: scope_crumbs(assigns.scope))

    ~H"""
    <nav class="flex items-center gap-1 text-xs min-w-0 overflow-hidden">
      <button
        type="button"
        phx-click="scope_to"
        phx-value-path=""
        class={["btn btn-ghost btn-xs px-1", @scope == "" && "btn-active"]}
        title="Whole repository"
      >
        <.icon name="hero-home" class="size-3.5" />
      </button>
      <span :for={{label, path} <- @crumbs} class="flex items-center gap-1 min-w-0">
        <.icon name="hero-chevron-right" class="size-3 opacity-40 shrink-0" />
        <button
          type="button"
          phx-click="scope_to"
          phx-value-path={path}
          class={["btn btn-ghost btn-xs px-1 font-mono truncate", path == @scope && "btn-active"]}
          title={path}
        >
          {label}
        </button>
      </span>
    </nav>
    """
  end

  # "lib/a/b" -> [{"lib", "lib"}, {"a", "lib/a"}, {"b", "lib/a/b"}]; [] for the root.
  defp scope_crumbs(""), do: []

  defp scope_crumbs(scope) do
    scope
    |> String.split("/")
    |> Enum.reduce({[], ""}, fn seg, {acc, prefix} ->
      path = if prefix == "", do: seg, else: prefix <> "/" <> seg
      {[{seg, path} | acc], path}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # --- Command palette (fuzzy finder) ----------------------------------------
  # Overlay listing matching files/folders. Selecting a file opens its X-Ray, a
  # folder sets the scope (same grammar as a map click).

  attr(:query, :string, required: true)
  attr(:results, :list, required: true)

  defp command_palette(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-start justify-center pt-[12vh] bg-black/40"
      phx-window-keydown="close_palette"
      phx-key="Escape"
    >
      <div
        class="bg-base-100 rounded-lg shadow-xl w-[36rem] max-w-[92vw] max-h-[70vh] flex flex-col"
        phx-click-away="close_palette"
      >
        <form phx-change="palette_search" class="p-2 border-b border-base-300">
          <input
            type="text"
            name="q"
            value={@query}
            autocomplete="off"
            autofocus
            phx-debounce="80"
            placeholder="Go to file or folder…"
            class="input input-bordered input-sm w-full"
          />
        </form>

        <ul class="overflow-y-auto p-1">
          <li :if={@results == []} class="px-3 py-2 text-sm opacity-60">No matches.</li>
          <li :for={e <- @results}>
            <button
              type="button"
              phx-click="palette_select"
              phx-value-path={e.path}
              phx-value-kind={Atom.to_string(e.kind)}
              class="w-full text-left flex items-center gap-2 px-3 py-1.5 rounded hover:bg-base-200"
            >
              <.icon
                name={if e.kind == :folder, do: "hero-folder", else: "hero-document"}
                class="size-4 shrink-0 opacity-60"
              />
              <span class="font-mono text-sm truncate">{e.path}</span>
              <span :if={e.kind == :folder} class="ml-auto text-[11px] opacity-40 shrink-0">
                folder
              </span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # --- Controls panel body ---------------------------------------------------

  attr(:metric, :string, required: true)
  attr(:metrics, :list, required: true)
  attr(:color_by, :string, required: true)
  attr(:color_modes, :list, required: true)
  attr(:include_removed, :boolean, required: true)
  attr(:removed_filter_available, :boolean, required: true)
  attr(:show_labels, :boolean, required: true)

  defp controls(assigns) do
    ~H"""
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
        <span class="text-sm">Color by</span>
        <select name="color_by" class="select select-bordered select-sm">
          <option :for={{label, value} <- @color_modes} value={value} selected={value == @color_by}>
            {label}
          </option>
        </select>
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
    """
  end

  # Server-rendered hotspot scatter: x = revisions (change frequency), y = indentation
  # complexity, dot area = churn. Median guides split it into quadrants; the top-right
  # (often-changed AND complex) is the prioritize-for-refactoring zone.
  @scatter_w 1000
  @scatter_h 640
  @scatter_pad %{left: 64, right: 28, top: 28, bottom: 52}

  attr(:points, :list, required: true)

  defp scatter_plot(assigns) do
    assigns =
      assigns
      |> assign(:geom, scatter_geometry(assigns.points))
      |> assign(:w, @scatter_w)
      |> assign(:h, @scatter_h)

    ~H"""
    <div
      id="scatter-plot"
      phx-hook="Scatter"
      class="w-full h-full flex items-center justify-center p-4"
    >
      <p :if={@geom == :empty} class="text-sm opacity-60 text-center">
        No files with complexity metrics in view.
      </p>
      <svg
        :if={@geom != :empty}
        viewBox={"0 0 #{@w} #{@h}"}
        preserveAspectRatio="xMidYMid meet"
        class="w-full h-full"
      >
        <%!-- Log-scale gridlines + tick labels (powers of ten) --%>
        <g :for={t <- @geom.xticks}>
          <line
            x1={t.pos}
            y1={@geom.y0}
            x2={t.pos}
            y2={@geom.y1}
            class="stroke-base-200"
            stroke-width="1"
          />
          <text
            x={t.pos}
            y={@geom.y0 + 20}
            text-anchor="middle"
            class="fill-base-content text-[13px] opacity-40"
          >
            {t.label}
          </text>
        </g>
        <g :for={t <- @geom.yticks}>
          <line
            x1={@geom.x0}
            y1={t.pos}
            x2={@geom.x1}
            y2={t.pos}
            class="stroke-base-200"
            stroke-width="1"
          />
          <text
            x={@geom.x0 - 8}
            y={t.pos + 4}
            text-anchor="end"
            class="fill-base-content text-[13px] opacity-40"
          >
            {t.label}
          </text>
        </g>

        <%!-- Axes --%>
        <line
          x1={@geom.x0}
          y1={@geom.y0}
          x2={@geom.x1}
          y2={@geom.y0}
          class="stroke-base-300"
          stroke-width="1"
        />
        <line
          x1={@geom.x0}
          y1={@geom.y0}
          x2={@geom.x0}
          y2={@geom.y1}
          class="stroke-base-300"
          stroke-width="1"
        />

        <%!-- Median quadrant guides --%>
        <line
          x1={@geom.vline}
          y1={@geom.y0}
          x2={@geom.vline}
          y2={@geom.y1}
          class="stroke-base-300"
          stroke-width="1"
          stroke-dasharray="4 4"
        />
        <line
          x1={@geom.x0}
          y1={@geom.hline}
          x2={@geom.x1}
          y2={@geom.hline}
          class="stroke-base-300"
          stroke-width="1"
          stroke-dasharray="4 4"
        />

        <text
          x={@geom.x1}
          y={@geom.y0 + 32}
          text-anchor="end"
          class="fill-base-content text-[18px] opacity-70"
        >
          revisions →
        </text>
        <text
          x={@geom.x0 - 44}
          y={@geom.y1 - 8}
          text-anchor="start"
          class="fill-base-content text-[18px] opacity-70"
        >
          ↑ indentation complexity
        </text>
        <text
          x={@geom.x1 - 6}
          y={@geom.y1 + 20}
          text-anchor="end"
          class="fill-error text-[16px] opacity-80"
        >
          prioritize
        </text>

        <circle
          :for={p <- @geom.points}
          cx={p.cx}
          cy={p.cy}
          r={p.r}
          class={[
            (p.top_right && "fill-error") || "fill-primary",
            "opacity-60 hover:opacity-100 cursor-pointer"
          ]}
          data-xray-path={p.path}
        >
          <title>
            {p.path}: {p.revisions} revisions · complexity {p.complexity} · churn {p.churn}
          </title>
        </circle>
      </svg>
    </div>
    """
  end

  # Map raw points into SVG geometry, or :empty when there is nothing to plot.
  defp scatter_geometry([]), do: :empty

  defp scatter_geometry(points) do
    x0 = @scatter_pad.left
    x1 = @scatter_w - @scatter_pad.right
    y0 = @scatter_h - @scatter_pad.bottom
    y1 = @scatter_pad.top

    # Revisions and complexity are heavily right-skewed (a few files dominate), so
    # both axes are log-scaled to spread the cloud out instead of piling it at the origin.
    max_rev = points |> Enum.map(& &1.revisions) |> Enum.max() |> max(1)
    max_cx = points |> Enum.map(& &1.indent_total) |> Enum.max() |> max(1)
    max_churn = points |> Enum.map(& &1.churn) |> Enum.max() |> max(1)

    lx = :math.log10(max_rev + 1)
    ly = :math.log10(max_cx + 1)
    xpos = fn v -> x0 + (x1 - x0) * log_frac(v, lx) end
    ypos = fn v -> y0 - (y0 - y1) * log_frac(v, ly) end

    med_rev = median(Enum.map(points, & &1.revisions))
    med_cx = median(Enum.map(points, & &1.indent_total))

    scaled =
      Enum.map(points, fn p ->
        %{
          path: p.path,
          revisions: p.revisions,
          complexity: p.indent_total,
          churn: p.churn,
          cx: xpos.(p.revisions),
          cy: ypos.(p.indent_total),
          r: 4 + 16 * :math.sqrt(p.churn / max_churn),
          top_right: p.revisions >= med_rev and p.indent_total >= med_cx
        }
      end)

    %{
      x0: x0,
      x1: x1,
      y0: y0,
      y1: y1,
      vline: xpos.(med_rev),
      hline: ypos.(med_cx),
      xticks: Enum.map(log_ticks(max_rev), &%{pos: xpos.(&1), label: tick_label(&1)}),
      yticks: Enum.map(log_ticks(max_cx), &%{pos: ypos.(&1), label: tick_label(&1)}),
      points: scaled
    }
  end

  # Fraction along a log axis whose span is `log_max` (= log10(max + 1)).
  defp log_frac(_v, +0.0), do: 0.0
  defp log_frac(v, log_max), do: :math.log10(v + 1) / log_max

  # Powers of ten up to `max` (1, 10, 100, ...), the natural ticks on a log axis.
  defp log_ticks(max) do
    Stream.iterate(1, &(&1 * 10))
    |> Enum.take_while(&(&1 <= max))
  end

  defp tick_label(n) when n >= 1000, do: "#{div(n, 1000)}k"
  defp tick_label(n), do: Integer.to_string(n)

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
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

      <%!-- Click grammar matches the map: a folder row re-roots the scope, a file
      row opens its X-Ray. The panel's Scope selector decides which kind a row is. --%>
      <ol class="space-y-0.5">
        <li :for={{h, i} <- Enum.with_index(@hotspots, 1)}>
          <button
            type="button"
            phx-click={if @scope == "folders", do: "scope_to", else: "xray"}
            phx-value-path={h.path}
            class="w-full text-left flex gap-2 px-2 py-1.5 rounded hover:bg-base-300"
            title={h.path}
          >
            <span class="text-xs opacity-40 tabular-nums w-5 shrink-0 pt-0.5">{i}</span>

            <span class="grow min-w-0 flex flex-col gap-0.5">
              <%!-- line 1: filename + sorted metric --%>
              <span class="flex items-baseline gap-2">
                <span class="font-mono text-sm font-medium truncate grow">
                  {Path.basename(h.path)}
                </span>
                <span class="text-xs opacity-70 tabular-nums shrink-0">
                  {sort_value(h, @sort)}
                </span>
              </span>

              <%!-- line 2: directory + risk badges --%>
              <span class="flex items-center gap-1.5 text-[11px]">
                <span class="path-tail font-mono opacity-45 truncate grow min-w-0">
                  {dir_label(h.path)}
                </span>
                <span
                  :if={h[:bus_factor?]}
                  class="text-warning shrink-0"
                  title={"#{round((h.ownership || 0) * 100)}% owned by #{author_label(h.main_author)}: bus-factor risk"}
                >⚠</span>
                <span
                  :if={h[:abandoned?]}
                  title={"owner #{author_label(h.main_author)} has gone inactive: abandoned knowledge"}
                  class="shrink-0"
                >
                  <.icon name="hero-user-minus" class="size-3 opacity-60" />
                </span>
                <span
                  :if={defect_badge?(h)}
                  class="text-error shrink-0 tabular-nums"
                  title={"#{round(h.bug_fix_density * 100)}% of commits are bug fixes"}
                >
                  🐛 {round(h.bug_fix_density * 100)}%
                </span>
                <span :if={badge = trend_badge(h)} class={badge.class} title={badge.help}>
                  {badge.marker}
                </span>
              </span>
            </span>
          </button>
        </li>
      </ol>
    </div>
    """
  end

  # Directory portion of a hotspot path; blank for repo-root files.
  defp dir_label(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end

  # The value shown per row is the one being sorted on.
  defp sort_value(h, "author_count"), do: "#{h.author_count}a"
  defp sort_value(h, "recency_churn"), do: h.recency_churn
  defp sort_value(h, "last_changed"), do: relative_age(h.last_changed)
  defp sort_value(h, "revisions"), do: "#{h.revisions}×"
  defp sort_value(h, _churn), do: h.churn

  # Show the defect badge only when fixes are a meaningful share of the file's
  # history, so a single incidental fix on a young file does not light it up.
  defp defect_badge?(%{bug_fix_density: d}) when is_float(d), do: d >= 0.25
  defp defect_badge?(_), do: false

  # Rising/cooling badge: recent churn vs the prior half-life window. Stable files
  # (and older dbs without the metric) show nothing.
  defp trend_badge(%{trend: :rising}) do
    %{
      marker: "▲",
      class: "text-xs text-error shrink-0",
      help: "rising: more churn in the last window than before"
    }
  end

  defp trend_badge(%{trend: :cooling}) do
    %{
      marker: "▼",
      class: "text-xs text-info shrink-0",
      help: "cooling: less churn in the last window than before"
    }
  end

  defp trend_badge(_), do: nil

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

  # --- X-Ray helpers ---------------------------------------------------------

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
  defp short_sha(_), do: ""

  # Author email -> local part for a compact label (full email kept in `title`).
  defp author_label(email) when is_binary(email), do: email |> String.split("@") |> hd()
  defp author_label(_), do: "?"

  defp unattributed_name, do: "(unattributed)"

  defp unattributed_help do
    "Churn git couldn't tie to a named region: a new file's bulk add, edits " <>
      "above the first definition, or a file type git has no diff driver for."
  end

  # Heatmap cell: faint grid for no churn, else a warm fill scaled (sqrt for
  # perceptual spread) by the cell's share of the busiest cell.
  defp heat_style(0, _max), do: "background-color: rgba(127,127,127,0.06)"

  defp heat_style(v, max) do
    alpha = Float.round(0.15 + 0.85 * :math.sqrt(v / max), 3)
    "background-color: rgba(220,70,60,#{alpha})"
  end

  # Source-line tint by recency within the file: oldest faint, newest warm. Kept
  # subtle (max ~0.34 alpha) so code stays readable.
  defp age_heat_style(0, _min, _max), do: ""

  defp age_heat_style(time, min, max) do
    t = (time - min) / (max - min)
    alpha = Float.round(0.04 + 0.30 * t, 3)
    "background-color: rgba(220,70,60,#{alpha})"
  end

  # Knowledge-concentration flag: one author owns most of a region's churn, and it
  # changed more than once (a single-commit region is trivially 100%-owned).
  defp owner_risk?(r), do: r.top_author_share >= 0.8 and r.commit_count > 1

  defp cohesion_verdict(x) when x < 1.5, do: "focused changes"
  defp cohesion_verdict(x) when x < 2.5, do: "moderate"
  defp cohesion_verdict(_), do: "low: changes span many regions"

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
