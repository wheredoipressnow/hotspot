defmodule HotspotWeb.HotspotLive.Hotspots do
  @moduledoc """
  Top hotspots list panel. Rows carry the sorted metric plus knowledge and defect
  risk badges. The click grammar matches the map: a folder row re-roots the scope, a
  file row opens its X-Ray, decided by the panel's Scope selector.
  """
  use HotspotWeb, :html

  alias HotspotWeb.HotspotLive.Format

  attr(:current, :string, default: nil)
  attr(:scope, :string, required: true)
  attr(:sort, :string, required: true)
  attr(:sorts, :list, required: true)
  attr(:hotspots, :list, required: true)

  def top_hotspots(assigns) do
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
                  title={"#{round((h.ownership || 0) * 100)}% owned by #{Format.author_label(h.main_author)}: bus-factor risk"}
                >⚠</span>
                <span
                  :if={h[:abandoned?]}
                  title={"owner #{Format.author_label(h.main_author)} has gone inactive: abandoned knowledge"}
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
  defp sort_value(h, "last_changed"), do: Format.relative_age(h.last_changed)
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
end
