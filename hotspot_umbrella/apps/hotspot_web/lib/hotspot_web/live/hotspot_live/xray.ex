defmodule HotspotWeb.HotspotLive.XRay do
  @moduledoc """
  File deep-dive dashboard: a region by time churn heatmap (hottest rows on top; rows
  hot in the same columns are entangled), a cohesion verdict, temporal coupling, and
  the blamed source pane.

  The render preferences (`sort`, limits, toggles) slice data already in the `xray`
  assign, so changing one only re-renders with no refetch.
  """
  use HotspotWeb, :html

  alias HotspotWeb.HotspotLive.Format

  @xray_sorts [{"Churn", "churn"}, {"Recency", "recency"}, {"Authors", "authors"}]
  @xray_region_opts [{"Top 10", "10"}, {"Top 30", "30"}, {"All", "all"}]
  @xray_commit_opts [{"5", "5"}, {"15", "15"}, {"All", "all"}]
  @xray_pref_defaults %{
    sort: "churn",
    region_limit: 30,
    commit_limit: 15,
    hide_unattributed: false,
    show_source: true
  }

  attr(:xray, :map, required: true)
  attr(:prefs, :map, required: true)

  def file_dashboard(assigns) do
    ready = assigns.xray.state == :ready
    prefs = assigns.prefs

    selected =
      if ready do
        assigns.xray.regions
        |> sort_regions(prefs.sort)
        |> drop_unattributed(prefs.hide_unattributed)
      else
        []
      end

    regions = take_limit(selected, prefs.region_limit)
    maxcell = regions |> Enum.flat_map(& &1.heat) |> Enum.max(fn -> 0 end)

    assigns =
      assign(assigns,
        ready: ready,
        regions: regions,
        maxcell: max(maxcell, 1),
        extra: length(selected) - length(regions)
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
          <div class={["space-y-5", @prefs.show_source && "lg:w-[34rem] lg:shrink-0"]}>
            <div>
              <div class="font-mono text-sm truncate" title={@xray.path}>{@xray.path}</div>
              <div class="text-xs opacity-60 mt-1 flex flex-wrap gap-x-4 gap-y-1">
                <span>{length(@xray.regions)} regions</span>
                <span :if={@xray.span}>
                  active {Format.relative_age(@xray.span.first)} → {Format.relative_age(
                    @xray.span.last
                  )}
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
                            title={"#{round(r.top_author_share * 100)}% by #{Format.author_label(r.top_author)}: knowledge risk"}
                          >⚠</span>
                        </span>
                      </summary>

                      <ul class="pl-48 pr-2 pt-1 pb-2 space-y-0.5">
                        <li
                          :for={c <- take_limit(r.commits, @prefs.commit_limit)}
                          class="flex items-center gap-2 text-[11px]"
                        >
                          <span class="font-mono opacity-60 shrink-0">{short_sha(c.sha)}</span>
                          <span class="truncate grow opacity-70" title={c.author}>{Format.author_label(
                            c.author
                          )}</span>
                          <span class="opacity-50 shrink-0">{Format.relative_age(c.committed_at)}</span>
                          <span class="opacity-70 shrink-0 tabular-nums">+{c.churn}</span>
                        </li>
                        <li
                          :if={commits_hidden(r.commits, @prefs.commit_limit) > 0}
                          class="text-[11px] opacity-40 pl-1"
                        >
                          + {commits_hidden(r.commits, @prefs.commit_limit)} more
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

          <div :if={@prefs.show_source} class="grow min-w-0 lg:h-full">
            <.source_pane source={@xray[:source]} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Current source, each line tinted by age (recent = warm) and carrying its
  # last-change commit as a hover tooltip (sha · age · author + summary/reason).
  attr(:source, :map, default: nil)

  def source_pane(assigns) do
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
              title={"#{short_sha(l.sha)} · #{Format.relative_age(l.time)} · #{l.author}\n#{l.summary}"}
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

  # Render-time controls for the X-Ray dashboard, shown in place of the map controls
  # while a file is X-Rayed. Every field slices data already in `xray`, so changes
  # re-render instantly with no refetch.
  attr(:prefs, :map, required: true)

  def xray_controls(assigns) do
    assigns =
      assign(assigns,
        sorts: @xray_sorts,
        region_opts: @xray_region_opts,
        commit_opts: @xray_commit_opts
      )

    ~H"""
    <form id="xray-form" phx-change="set_xray_view" class="space-y-3">
      <label class="flex flex-col gap-1">
        <span class="text-sm">Sort regions by</span>
        <select name="sort" class="select select-bordered select-sm">
          <option :for={{label, value} <- @sorts} value={value} selected={value == @prefs.sort}>
            {label}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span class="text-sm">Regions shown</span>
        <select name="region_limit" class="select select-bordered select-sm">
          <option
            :for={{label, value} <- @region_opts}
            value={value}
            selected={value == to_string(@prefs.region_limit)}
          >
            {label}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span class="text-sm">Commits per region</span>
        <select name="commit_limit" class="select select-bordered select-sm">
          <option
            :for={{label, value} <- @commit_opts}
            value={value}
            selected={value == to_string(@prefs.commit_limit)}
          >
            {label}
          </option>
        </select>
      </label>

      <label class="flex items-center gap-2 cursor-pointer">
        <input type="hidden" name="hide_unattributed" value="false" />
        <input
          type="checkbox"
          name="hide_unattributed"
          value="true"
          checked={@prefs.hide_unattributed}
          class="checkbox checkbox-sm"
        />
        <span class="text-sm">Hide unattributed region</span>
      </label>

      <label class="flex items-center gap-2 cursor-pointer">
        <input type="hidden" name="show_source" value="false" />
        <input
          type="checkbox"
          name="show_source"
          value="true"
          checked={@prefs.show_source}
          class="checkbox checkbox-sm"
        />
        <span class="text-sm">Show source pane</span>
      </label>

      <button type="button" phx-click="reset_xray_view" class="btn btn-sm btn-outline w-full">
        Reset
      </button>
    </form>
    """
  end

  @doc "Default render preferences for the dashboard."
  def default_prefs, do: @xray_pref_defaults

  @doc """
  Casts the whole controls form back into prefs. Each checkbox sends a hidden "false"
  companion, so an unchecked box reads false and a checked one true. Absent or
  unparseable fields keep their current value.
  """
  def merge_prefs(current, params) do
    current
    |> put_pref(:sort, params["sort"], fn v -> if valid_sort?(v), do: v end)
    |> put_pref(:region_limit, params["region_limit"], &parse_limit/1)
    |> put_pref(:commit_limit, params["commit_limit"], &parse_limit/1)
    |> put_pref(:hide_unattributed, params["hide_unattributed"], &parse_bool/1)
    |> put_pref(:show_source, params["show_source"], &parse_bool/1)
  end

  # Apply `cast` to a raw form value and store it under `key`, unless the field is
  # absent (nil) or the cast rejects it (also nil).
  defp put_pref(prefs, _key, nil, _cast), do: prefs

  defp put_pref(prefs, key, raw, cast) do
    case cast.(raw) do
      nil -> prefs
      value -> Map.put(prefs, key, value)
    end
  end

  defp valid_sort?(value), do: Enum.any?(@xray_sorts, fn {_label, v} -> v == value end)

  defp parse_limit("all"), do: :all

  defp parse_limit(raw) do
    case Integer.parse(raw) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  # Re-rank regions by the chosen key. Defaults to churn, the order the runner already
  # returns, so "churn" is a stable no-op.
  defp sort_regions(regions, "recency"), do: Enum.sort_by(regions, & &1.recency_churn, :desc)
  defp sort_regions(regions, "authors"), do: Enum.sort_by(regions, & &1.author_count, :desc)
  defp sort_regions(regions, _churn), do: Enum.sort_by(regions, & &1.churn, :desc)

  defp take_limit(list, :all), do: list
  defp take_limit(list, n) when is_integer(n), do: Enum.take(list, n)

  defp drop_unattributed(regions, false), do: regions

  defp drop_unattributed(regions, true),
    do: Enum.reject(regions, &(&1.name == unattributed_name()))

  defp commits_hidden(_commits, :all), do: 0
  defp commits_hidden(commits, n) when is_integer(n), do: max(0, length(commits) - n)

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
  defp short_sha(_), do: ""

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
end
