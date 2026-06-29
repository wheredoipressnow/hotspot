defmodule HotspotWeb.HotspotLive.Coupling do
  @moduledoc """
  Force-directed coupling "cloud" overlay and its live layout controls.

  Nodes are files, an edge means they change together, and node color ramps with how
  often a file is coupled (hubs run hot). Layout and interaction live in the
  `CouplingGraph` JS hook; this frames the overlay and exposes the slider-driven force
  parameters shared between the controls and the hook.
  """
  use HotspotWeb, :html

  # Live layout knobs shared between the "Forces" panel and the JS hook. Each entry
  # is `{key, default, min, max, step, label}`; the defaults reproduce the baseline
  # layout. `min`/`max` clamp slider input so an out-of-range value cannot wedge the
  # simulation.
  @coupling_param_specs [
    {:repel, -420, -800, -100, 20, "Repel"},
    {:center, 1.0, 0.0, 1.0, 0.05, "Center pull"},
    {:link_strength, 1.0, 0.0, 2.0, 0.1, "Link strength"},
    {:link_distance, 1.0, 0.3, 2.5, 0.1, "Link distance"},
    {:node_size, 1.0, 0.5, 2.0, 0.1, "Node size"},
    {:link_width, 1.0, 0.5, 3.0, 0.1, "Link thickness"}
  ]

  attr(:graph, :map, required: true)

  def coupling_graph_view(assigns) do
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

  attr(:params, :map, required: true)

  def coupling_controls(assigns) do
    assigns = assign(assigns, :specs, @coupling_param_specs)

    ~H"""
    <form id="coupling-form" phx-change="set_coupling_params" class="space-y-3">
      <label :for={{key, _default, min, max, step, label} <- @specs} class="flex flex-col gap-1">
        <span class="text-sm flex items-center justify-between gap-2">
          {label}
          <span class="opacity-50 font-mono text-xs">{fmt_param(@params[key])}</span>
        </span>
        <input
          type="range"
          name={key}
          min={min}
          max={max}
          step={step}
          value={@params[key]}
          class="range range-xs"
        />
      </label>

      <button type="button" phx-click="reset_coupling_params" class="btn btn-sm btn-outline w-full">
        Reset
      </button>
    </form>
    """
  end

  # Compact slider readout: drop a trailing ".0" but keep real fractional values.
  defp fmt_param(value) when is_integer(value), do: Integer.to_string(value)

  defp fmt_param(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, decimals: 2)
  end

  @doc "Baseline force parameters keyed by slider name."
  def default_params do
    Map.new(@coupling_param_specs, fn {key, default, _min, _max, _step, _label} ->
      {key, default}
    end)
  end

  @doc """
  Casts the changed slider field(s) into the current params, clamped to each spec's
  range. A single-slider `phx-change` carries only one key; unknown keys are ignored.
  """
  def merge_params(current, params) do
    Enum.reduce(@coupling_param_specs, current, fn {key, _default, min, max, _step, _label},
                                                   acc ->
      case Map.fetch(params, Atom.to_string(key)) do
        {:ok, raw} ->
          case Float.parse(to_string(raw)) do
            {value, _} -> Map.put(acc, key, value |> max(min) |> min(max))
            :error -> acc
          end

        :error ->
          acc
      end
    end)
  end

  @doc "Parses a depth selection to an integer clamped to 1..3, defaulting to 2."
  def to_depth(depth) do
    case Integer.parse(to_string(depth)) do
      {n, _} -> n |> max(1) |> min(3)
      :error -> 2
    end
  end
end
