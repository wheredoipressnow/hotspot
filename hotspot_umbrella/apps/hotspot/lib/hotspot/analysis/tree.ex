defmodule Hotspot.Analysis.Tree do
  @moduledoc """
  Builds the nested directory tree for the circle-packing visualization. SQL
  reduces to per-file aggregates; Elixir nests them by path. Owned by the
  analytics app, never called from web except through `Hotspot.Analysis`.

  ## Removed / renamed files (`include_removed`)

  By default every path ever touched in history is included (`include_removed:
  true`), including files deleted or renamed away, each carrying full historical
  churn. With `include_removed: false` the aggregates are recomputed after
  *folding renames*: each `file_change` path is remapped to the terminal path of
  its `rename_edge` chain, so a refactored file counts once under its final name
  and its obsolete path disappears.

  Truly *deleted* files (gone from HEAD, never renamed) are also excluded when the
  db carries a `tracked_file` snapshot: after folding, rows whose resolved path is
  no longer present at the extracted ref are dropped (`Hotspot.Analysis.Tracked`).
  On older databases without that snapshot, `include_removed: false` falls back to
  only collapsing renames.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.{Recency, Renames, Tracked}
  alias Hotspot.Storage.{Commit, FileChange}

  @type params :: %{
          optional(:path_filter) => String.t() | nil,
          optional(:include_merges) => boolean,
          optional(:include_removed) => boolean
        }

  @doc """
  Returns a JSON-able nested tree. Leaves carry every metric value so the client
  can switch the size encoding without a server round-trip:

      %{name: "root", children: [
        %{name: "lib", children: [
          %{name: "app.ex", path: "lib/app.ex", churn: 412, author_count: 3,
            recency_churn: 88, last_changed: 1_718_900_000}]}]}
  """
  @spec tree_for_visualization(params) :: map
  def tree_for_visualization(params \\ %{}) do
    params
    |> aggregate()
    |> build_tree()
  end

  # Per-file aggregates of `%{path, churn, author_count, recency_churn, last_changed}`.
  # Recency weighting requires per-change rows scored in code (see
  # `Hotspot.Analysis.Recency`), so we aggregate in Elixir uniformly. When
  # include_removed is false we additionally fold renames onto their terminal path
  # before grouping and drop paths gone from HEAD.
  defp aggregate(params) do
    include_merges = Map.get(params, :include_merges, false)
    include_removed = Map.get(params, :include_removed, true)
    path_filter = Map.get(params, :path_filter)

    rename = if include_removed, do: %{}, else: Renames.map()
    opts = [now: Recency.now(), half_life: Recency.half_life_seconds()]

    include_merges
    |> change_rows()
    |> Enum.group_by(&Renames.resolve(rename, &1.path))
    |> Enum.map(fn {path, rows} -> Map.put(Recency.metrics_for(rows, opts), :path, path) end)
    |> then(if include_removed, do: & &1, else: &Tracked.filter/1)
    |> filter_path_list(path_filter)
  end

  # Per-change rows `%{path, churn, author, committed_at}`. Binary rows
  # (added IS NULL) are excluded from churn; merges excluded unless include_merges.
  defp change_rows(include_merges) do
    from(f in FileChange,
      join: c in Commit,
      on: c.sha == f.commit_sha,
      where: not is_nil(f.added),
      select: %{
        path: f.path,
        churn: f.added + f.deleted,
        author: c.author_email,
        committed_at: c.committed_at
      }
    )
    |> maybe_exclude_merges(include_merges)
    |> Repo.all()
  end

  defp maybe_exclude_merges(query, true), do: query
  defp maybe_exclude_merges(query, false), do: from([_f, c] in query, where: c.parent_count < 2)

  defp filter_path_list(rows, prefix) when prefix in [nil, ""], do: rows

  defp filter_path_list(rows, prefix),
    do: Enum.filter(rows, &String.starts_with?(&1.path, prefix))

  # Nest the flat rows into a tree keyed by path segments.
  defp build_tree(rows) do
    children =
      rows
      |> Enum.reduce(%{}, fn row, acc -> insert(acc, String.split(row.path, "/"), row) end)
      |> to_children()

    %{name: "root", children: children}
  end

  defp insert(tree, [leaf], row) do
    Map.update(tree, leaf, %{leaf: row, children: %{}}, &%{&1 | leaf: row})
  end

  defp insert(tree, [dir | rest], row) do
    node = Map.get(tree, dir, %{leaf: nil, children: %{}})
    Map.put(tree, dir, %{node | children: insert(node.children, rest, row)})
  end

  defp to_children(map) do
    Enum.map(map, fn {name, %{leaf: leaf, children: children}} ->
      if map_size(children) == 0 and leaf do
        %{
          name: name,
          path: leaf.path,
          churn: leaf.churn || 0,
          author_count: leaf.author_count || 0,
          recency_churn: leaf.recency_churn || 0,
          last_changed: leaf.last_changed || 0
        }
      else
        %{name: name, children: to_children(children)}
      end
    end)
  end
end
