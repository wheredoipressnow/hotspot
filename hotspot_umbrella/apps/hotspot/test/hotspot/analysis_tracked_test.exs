defmodule Hotspot.AnalysisTrackedTest do
  use Hotspot.IntegrationCase

  alias Hotspot.Analysis

  # c1 touches kept.ex, deleted.ex, old.ex; c2 renames old.ex -> new.ex and touches it.
  # HEAD (tracked_file) has kept.ex and new.ex only: deleted.ex is gone, old.ex moved.
  setup do
    seed_db!(
      [
        commit("c1",
          committed_at: 1,
          author_name: "Ada",
          author_email: "ada@x",
          files: [{"kept.ex", 10, 0}, {"deleted.ex", 7, 0}, {"old.ex", 5, 0}]
        ),
        commit("c2",
          committed_at: 2,
          author_name: "Bob",
          author_email: "bob@x",
          files: [{"new.ex", 3, 1}],
          renames: [{"old.ex", "new.ex", 100}]
        )
      ],
      [
        %{path: "kept.ex", loc: nil, indent_total: nil, indent_max: nil},
        %{path: "new.ex", loc: nil, indent_total: nil, indent_max: nil}
      ]
    )

    :ok
  end

  defp leaf_paths(tree), do: tree |> collect_leaves() |> Enum.map(& &1.path) |> Enum.sort()
  defp collect_leaves(%{children: children}), do: Enum.flat_map(children, &collect_leaves/1)
  defp collect_leaves(%{path: _} = leaf), do: [leaf]
  defp collect_leaves(_), do: []

  test "removed_filter_available?/0 is true when tracked_sha == last_sha" do
    assert Analysis.removed_filter_available?()
  end

  test "include_removed: true keeps every historical path" do
    paths = Analysis.tree_for_visualization(%{include_removed: true}) |> leaf_paths()
    assert paths == ["deleted.ex", "kept.ex", "new.ex", "old.ex"]
  end

  test "include_removed: false drops deleted files and folds renames" do
    paths = Analysis.tree_for_visualization(%{include_removed: false}) |> leaf_paths()
    # deleted.ex gone (not in HEAD); old.ex folded into new.ex (its rename terminal).
    assert paths == ["kept.ex", "new.ex"]
  end

  test "folded new.ex carries churn from both old.ex and new.ex" do
    tree = Analysis.tree_for_visualization(%{include_removed: false})
    new = tree |> collect_leaves() |> Enum.find(&(&1.path == "new.ex"))
    # old.ex churn 5 (c1) + new.ex churn 4 (c2) = 9; distinct authors Ada + Bob = 2.
    assert new.churn == 9
    assert new.author_count == 2
  end

  test "top_hotspots respects the removed filter" do
    excluded = Analysis.top_hotspots(%{include_removed: false, scope: "files"})
    paths = Enum.map(excluded, & &1.path)
    refute "deleted.ex" in paths
    refute "old.ex" in paths
    assert "new.ex" in paths
  end
end
