defmodule Hotspot.Analysis.Tree do
  @moduledoc """
  Builds the nested directory tree for the circle-packing visualization
  (HANDOFF §5 `tree_for_visualization`). SQL reduces to per-file aggregates;
  Elixir nests them by path. Owned by the analytics app — never called from web
  except through `Hotspot.Analysis`.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Storage.{Commit, FileChange}

  @type params :: %{
          optional(:path_filter) => String.t() | nil,
          optional(:include_merges) => boolean
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

  # One grouped query joining file_change -> commit_info. Binary rows (added IS NULL)
  # are excluded from churn. Merges excluded unless include_merges is true.
  defp aggregate(params) do
    include_merges = Map.get(params, :include_merges, false)
    path_filter = Map.get(params, :path_filter)

    base =
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

    base
    |> maybe_exclude_merges(include_merges)
    |> maybe_filter_path(path_filter)
    |> Repo.all()
  end

  defp maybe_exclude_merges(query, true), do: query
  defp maybe_exclude_merges(query, false), do: from([_f, c] in query, where: c.parent_count < 2)

  defp maybe_filter_path(query, nil), do: query
  defp maybe_filter_path(query, ""), do: query

  defp maybe_filter_path(query, prefix) do
    like = prefix <> "%"
    from([f, _c] in query, where: like(f.path, ^like))
  end

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
