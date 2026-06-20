defmodule Hotspot.Analysis.Tree do
  @moduledoc """
  Builds the nested directory tree for the circle-packing visualization
  (HANDOFF §5 `tree_for_visualization`). SQL reduces to per-file aggregates;
  Elixir nests them by path. Owned by the analytics app — never called from web
  except through `Hotspot.Analysis`.

  ## Removed / renamed files (`include_removed`)

  By default every path ever touched in history is included (`include_removed:
  true`) — including files deleted or renamed away, each carrying full historical
  churn. With `include_removed: false` the aggregates are recomputed after
  *folding renames*: each `file_change` path is remapped to the terminal path of
  its `rename_edge` chain, so a refactored file counts once under its final name
  and its obsolete path disappears (3a).

  Truly *deleted* files (gone from HEAD, never renamed) cannot be excluded yet:
  the runner-produced db carries no working-tree file list, so there is no signal
  for "still exists" (3b — blocked on a runner change). Until then
  `include_removed: false` only collapses renames.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.Renames
  alias Hotspot.Storage.{Commit, FileChange}

  @type params :: %{
          optional(:path_filter) => String.t() | nil,
          optional(:include_merges) => boolean,
          optional(:include_removed) => boolean
        }

  @doc """
  Returns a JSON-able nested tree. Leaves carry both metric values so the client
  can switch the size encoding without a server round-trip:

      %{name: "root", children: [
        %{name: "lib", children: [
          %{name: "app.ex", path: "lib/app.ex", churn: 412, author_count: 3}]}]}
  """
  @spec tree_for_visualization(params) :: map
  def tree_for_visualization(params \\ %{}) do
    params
    |> aggregate()
    |> build_tree()
  end

  # Per-file aggregates of `%{path, churn, author_count}`. When include_removed is
  # true (default) we group in SQL over every historical path. When false we fold
  # renames first, which needs row-level remapping, so we aggregate in Elixir.
  defp aggregate(params) do
    include_merges = Map.get(params, :include_merges, false)
    include_removed = Map.get(params, :include_removed, true)
    path_filter = Map.get(params, :path_filter)

    if include_removed do
      aggregate_all(include_merges, path_filter)
    else
      aggregate_folded(include_merges, path_filter)
    end
  end

  # One grouped query joining file_change -> commit_info. Binary rows (added IS NULL)
  # are excluded from churn. Merges excluded unless include_merges is true.
  defp aggregate_all(include_merges, path_filter) do
    from(f in FileChange,
      join: c in Commit,
      on: c.sha == f.commit_sha,
      where: not is_nil(f.added),
      group_by: f.path,
      select: %{
        path: f.path,
        churn: sum(f.added + f.deleted),
        author_count: count(c.author_email, :distinct)
      }
    )
    |> maybe_exclude_merges(include_merges)
    |> maybe_filter_path(path_filter)
    |> Repo.all()
  end

  # Fold renames: pull per-change rows, remap each path to its terminal rename
  # target, then aggregate in Elixir so distinct author counts stay correct (they
  # are not additive across merged paths).
  defp aggregate_folded(include_merges, path_filter) do
    rename = Renames.map()

    base =
      from(f in FileChange,
        join: c in Commit,
        on: c.sha == f.commit_sha,
        where: not is_nil(f.added),
        select: %{path: f.path, churn: f.added + f.deleted, author: c.author_email}
      )

    base
    |> maybe_exclude_merges(include_merges)
    |> Repo.all()
    |> Enum.group_by(&Renames.resolve(rename, &1.path))
    |> Enum.map(fn {path, rows} ->
      %{
        path: path,
        churn: rows |> Enum.map(& &1.churn) |> Enum.sum(),
        author_count: rows |> Enum.map(& &1.author) |> Enum.uniq() |> length()
      }
    end)
    |> filter_path_list(path_filter)
  end

  defp maybe_exclude_merges(query, true), do: query
  defp maybe_exclude_merges(query, false), do: from([_f, c] in query, where: c.parent_count < 2)

  defp maybe_filter_path(query, nil), do: query
  defp maybe_filter_path(query, ""), do: query

  defp maybe_filter_path(query, prefix) do
    like = prefix <> "%"
    from([f, _c] in query, where: like(f.path, ^like))
  end

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
          author_count: leaf.author_count || 0
        }
      else
        %{name: name, children: to_children(children)}
      end
    end)
  end
end
