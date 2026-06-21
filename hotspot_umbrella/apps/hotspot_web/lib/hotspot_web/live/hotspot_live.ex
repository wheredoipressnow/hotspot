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
       # File deep-dive overlay (nil = showing the map). Set by clicking a circle,
       # cleared by "Back to map".
       xray: nil,
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

  # Clicking a file circle drills into it: query git live for per-region
  # metrics. The git call shells out, so run it off the LiveView process via
  # `start_async` and show a loading state meanwhile. Opens the panel too.
  def handle_event("xray", %{"path" => path}, socket) do
    case Analysis.repo_path() do
      repo when is_binary(repo) ->
        # Region history (git) + cross-file coupling (db) in one task; the file's
        # blamed source in a second task so the heatmap can render without waiting
        # on the (larger) source.
        {:noreply,
         socket
         |> assign(xray: %{state: :loading, path: path, regions: []})
         |> start_async({:xray, path}, fn ->
           {HotspotRunner.Xray.file_history(repo, path), Analysis.coupling(path)}
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
    # Path filter is repo-specific, so clear it on a db switch; other prefs persist.
    # Removed-filter availability is per-db, so recompute it and its default.
    available = Analysis.removed_filter_available?()

    socket =
      assign(socket,
        current: current,
        dbs: Storage.list(),
        path_filter: "",
        # X-Ray paths are repo-specific, so clear it on a db switch.
        xray: nil,
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

        <%!-- A selected file overlays its deep-dive on top of the (still-mounted) circle pack. --%>
        <.file_dashboard
          :if={@current && @xray && @xray.state in [:loading, :ready, :error]}
          xray={@xray}
        />
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
              cohesion {@xray.cohesion.regions_per_commit}/commit ·
              {cohesion_verdict(@xray.cohesion.regions_per_commit)}
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
                    <span class="font-mono text-xs truncate w-48 shrink-0 flex items-center gap-1" title={r.name}>
                      <span class="truncate">{r.name}</span>
                      <span :if={r.name == unattributed_name()} title={unattributed_help()} class="shrink-0">
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
                    <li :for={c <- Enum.take(r.commits, 15)} class="flex items-center gap-2 text-[11px]">
                      <span class="font-mono opacity-60 shrink-0">{short_sha(c.sha)}</span>
                      <span class="truncate grow opacity-70" title={c.author}>{author_label(c.author)}</span>
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
                <span class="h-1.5 rounded bg-primary/60 shrink-0" style={"width: #{round(c.coupling * 60)}px"} />
                <span class="text-[11px] opacity-60 shrink-0 w-24 text-right">
                  {round(c.coupling * 100)}% · {c.shared_commits}c
                </span>
              </button>
            </li>
          </ul>
        </div>
        <p :if={@xray.coupling == []} class="text-xs opacity-40">No notable cross-file coupling.</p>
        </div>

        <div class="grow min-w-0 lg:h-full">
          <.source_pane source={@xray[:source]} />
        </div>
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

      <div :if={@lines != []} class="grow min-h-0 overflow-auto rounded border border-base-300 bg-base-200/40">
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
