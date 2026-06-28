defmodule Hotspot.Analysis.Complexity do
  @moduledoc """
  The complexity axis of a hotspot: how big and how deeply indented a file is now,
  paired with how often it changes. Size and indentation come from the
  `tracked_file` snapshot (current files only, see `Hotspot.Analysis.Tracked`);
  change frequency comes from history via `Hotspot.Analysis.Hotspots`.

  Indentation is a language-agnostic complexity proxy: `indent_avg` is mean leading
  whitespace per non-blank line, `indent_max` the deepest nesting. `hotspot_score`
  is `revisions * indent_total`, ranking files that change often and are complex.
  Binary files carry no metrics and are dropped from the scatter.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.Hotspots
  alias Hotspot.Storage.TrackedFile

  # Generous cap so the scatter shows the whole working tree on typical repos
  # without unbounded server-rendered SVG.
  @scatter_limit 400

  @type point :: %{
          path: String.t(),
          loc: non_neg_integer,
          indent_total: non_neg_integer,
          indent_max: non_neg_integer,
          indent_avg: float,
          revisions: non_neg_integer,
          churn: number,
          hotspot_score: number
        }

  @doc "Per-path complexity metrics for the current tree, keyed by path. Binary files omitted."
  @spec metrics_map() :: %{String.t() => map}
  def metrics_map do
    from(t in TrackedFile,
      where: not is_nil(t.indent_total),
      select: {t.path, %{loc: t.loc, indent_total: t.indent_total, indent_max: t.indent_max}}
    )
    |> repo().all()
    |> Map.new(fn {path, m} -> {path, Map.put(m, :indent_avg, avg(m.indent_total, m.loc))} end)
  rescue
    # tracked_file lacks the metric columns on an older db.
    _ -> %{}
  end

  @doc "Complexity metrics for one path, or `nil` when absent or binary."
  @spec for_path(String.t()) :: map | nil
  def for_path(path) do
    Map.get(metrics_map(), path)
  end

  @doc """
  Scatter points joining each current file's change frequency to its complexity.
  Files with no complexity metric (binary, or absent from the snapshot) are
  dropped. Takes the same params as `Hotspot.Analysis.Hotspots.top/1`; `scope` is
  forced to files and `limit` defaults to #{@scatter_limit}.
  """
  @spec scatter(map) :: [point]
  def scatter(params \\ %{}) do
    metrics = metrics_map()

    params
    |> Map.merge(%{scope: "files", limit: Map.get(params, :limit, @scatter_limit)})
    |> Hotspots.top()
    |> Enum.flat_map(fn h ->
      case Map.get(metrics, h.path) do
        nil -> []
        m -> [point(h, m)]
      end
    end)
  end

  defp point(h, m) do
    %{
      path: h.path,
      loc: m.loc,
      indent_total: m.indent_total,
      indent_max: m.indent_max,
      indent_avg: m.indent_avg,
      revisions: h.revisions,
      churn: h.churn,
      hotspot_score: h.revisions * m.indent_total
    }
  end

  defp avg(_total, loc) when loc in [nil, 0], do: 0.0
  defp avg(total, loc), do: total / loc

  defp repo, do: Application.get_env(:hotspot, :repo, Repo)
end
