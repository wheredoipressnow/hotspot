defmodule HotspotWeb.HotspotLive.Chrome do
  @moduledoc """
  Shared layout chrome: the top bar (database picker, scope breadcrumb, time range,
  theme toggle), the reusable docked side panel, and the default map controls.
  """
  use HotspotWeb, :html

  alias HotspotWeb.HotspotLive.TimeRange

  attr(:open, :boolean, required: true)
  attr(:title, :string, required: true)
  attr(:side, :string, default: "left", values: ~w(left right))
  attr(:toggle, :string, required: true, doc: "phx-click event that flips `open`")
  slot(:inner_block, required: true)

  def panel(assigns) do
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

  # Repository/database management, the scope breadcrumb, and the theme toggle.
  attr(:dbs, :list, required: true)
  attr(:current, :string, default: nil)
  attr(:scope, :string, required: true)
  attr(:time_range, :any, required: true)

  def top_bar(assigns) do
    {from_str, to_str} = TimeRange.custom_dates(assigns.time_range)

    assigns =
      assign(assigns, preset: TimeRange.key(assigns.time_range), from: from_str, to: to_str)

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
          id="time-range-form"
          phx-change="set_time_range"
          class="flex items-center gap-2"
          title="Analysis time range"
        >
          <.icon name="hero-clock" class="size-5 opacity-70" />
          <select name="preset" class="select select-bordered select-sm min-w-32">
            <option
              :for={{label, value} <- TimeRange.presets()}
              value={value}
              selected={value == @preset}
            >
              {label}
            </option>
            <option value="custom" selected={@preset == "custom"}>Custom…</option>
          </select>
          <input
            :if={@preset == "custom"}
            type="date"
            name="from"
            value={@from}
            class="input input-bordered input-sm"
          />
          <input
            :if={@preset == "custom"}
            type="date"
            name="to"
            value={@to}
            class="input input-bordered input-sm"
          />
        </form>

        <Layouts.theme_toggle />
      </div>
    </header>
    """
  end

  # Trail of the current scope path. Each crumb re-roots the map (and the list)
  # at that ancestor via `scope_to`; the leading "root" crumb resets to `""`.
  attr(:scope, :string, required: true)

  def breadcrumb(assigns) do
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

  attr(:metric, :string, required: true)
  attr(:metrics, :list, required: true)
  attr(:color_by, :string, required: true)
  attr(:color_modes, :list, required: true)
  attr(:include_removed, :boolean, required: true)
  attr(:removed_filter_available, :boolean, required: true)
  attr(:show_labels, :boolean, required: true)

  def controls(assigns) do
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

  @doc """
  Title for the left panel: the coupling cloud (a child overlay of X-Ray) wins, then
  X-Ray, then the default hotspots chart.
  """
  def view_panel_title(coupling_graph, _xray) when not is_nil(coupling_graph), do: "Coupling"
  def view_panel_title(_coupling_graph, xray) when not is_nil(xray), do: "X-Ray"
  def view_panel_title(_coupling_graph, _xray), do: "Hotspots"
end
