defmodule HotspotWeb.HotspotLive.Scatter do
  @moduledoc """
  Hotspot scatter plot: x is revisions, y is indentation complexity, dot area is
  churn. Both axes are log-scaled because the data is heavily right-skewed. Median
  guides split the plane into quadrants; the top-right (often-changed and complex)
  is the prioritize-for-refactoring zone.
  """
  use HotspotWeb, :html

  @scatter_w 1000
  @scatter_h 640
  @scatter_pad %{left: 64, right: 28, top: 28, bottom: 52}

  attr(:points, :list, required: true)

  def scatter_plot(assigns) do
    assigns =
      assigns
      |> assign(:geom, geometry(assigns.points))
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

  @doc "Maps raw points into SVG geometry, or `:empty` when there is nothing to plot."
  def geometry([]), do: :empty

  def geometry(points) do
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
end
