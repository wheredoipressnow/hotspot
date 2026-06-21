defmodule Hotspot.Analysis.Hotspots do
  @moduledoc """
  Ranked "top hotspots" overview backing the list panel. Aggregates the same
  per-change facts as `Hotspot.Analysis.Tree` but at the requested `scope`
  (`"files"` for full paths, `"folders"` for every ancestor directory) and returns
  the top N by `sort`. Distinct author counts are computed from raw author
  emails so folder rollups stay correct (they are not additive across files).
  Recency-weighted churn and last-changed time are scored from `committed_at` via
  `Hotspot.Analysis.Recency`.

  Respects `include_removed` (folds renames when false, see
  `Hotspot.Analysis.Renames`) and `include_merges`.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.{Recency, Renames, Tracked}
  alias Hotspot.Storage.{Commit, FileChange}

  @sorts ~w(churn author_count recency_churn last_changed revisions)

  @type params :: %{
          optional(:sort) => String.t(),
          optional(:scope) => String.t(),
          optional(:limit) => pos_integer,
          optional(:path_filter) => String.t() | nil,
          optional(:include_merges) => boolean,
          optional(:include_removed) => boolean
        }

  @doc """
  Returns `[%{path, churn, author_count, recency_churn, last_changed,
  first_changed, revisions, trend}]` sorted by `sort` descending. Options: `sort`
  (`"churn"` | `"author_count"` | `"recency_churn"` | `"last_changed"` |
  `"revisions"`, default `"churn"`), `scope` (`"files"` | `"folders"`), `limit`
  (default 25).
  """
  @spec top(params) :: [map]
  def top(params \\ %{}) do
    sort = sort_key(Map.get(params, :sort))
    scope = if Map.get(params, :scope) == "folders", do: :folders, else: :files
    limit = Map.get(params, :limit, 25)
    opts = [now: Recency.now(), half_life: Recency.half_life_seconds()]

    params
    |> raw_rows()
    |> filter_path(Map.get(params, :path_filter))
    |> by_keys(scope)
    |> Enum.map(fn {key, rows} -> Map.put(Recency.metrics_for(rows, opts), :path, key) end)
    |> Enum.sort_by(&Map.fetch!(&1, sort), :desc)
    |> Enum.take(limit)
  end

  defp sort_key(sort) when sort in @sorts, do: String.to_existing_atom(sort)
  defp sort_key(_), do: :churn

  # Per-change rows, paths folded onto rename terminals when include_removed is false.
  defp raw_rows(params) do
    include_merges = Map.get(params, :include_merges, false)
    include_removed = Map.get(params, :include_removed, true)

    rows =
      from(f in FileChange,
        join: c in Commit,
        on: c.sha == f.commit_sha,
        where: not is_nil(f.added),
        select: %{
          path: f.path,
          sha: f.commit_sha,
          churn: f.added + f.deleted,
          author: c.author_email,
          committed_at: c.committed_at
        }
      )
      |> maybe_exclude_merges(include_merges)
      |> Repo.all()

    if include_removed do
      rows
    else
      rename = Renames.map()

      rows
      |> Enum.map(&%{&1 | path: Renames.resolve(rename, &1.path)})
      |> Tracked.filter()
    end
  end

  defp maybe_exclude_merges(query, true), do: query
  defp maybe_exclude_merges(query, false), do: from([_f, c] in query, where: c.parent_count < 2)

  defp filter_path(rows, prefix) when prefix in [nil, ""], do: rows
  defp filter_path(rows, prefix), do: Enum.filter(rows, &String.starts_with?(&1.path, prefix))

  # Files: group by the full path. Folders: a file contributes to every ancestor
  # directory, so it lands in each prefix group.
  defp by_keys(rows, :files), do: Enum.group_by(rows, & &1.path)

  defp by_keys(rows, :folders) do
    Enum.reduce(rows, %{}, fn row, acc ->
      row.path
      |> ancestors()
      |> Enum.reduce(acc, fn dir, acc -> Map.update(acc, dir, [row], &[row | &1]) end)
    end)
  end

  # "lib/a/b.ex" -> ["lib", "lib/a"]
  defp ancestors(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.scan(&"#{&2}/#{&1}")
  end
end
