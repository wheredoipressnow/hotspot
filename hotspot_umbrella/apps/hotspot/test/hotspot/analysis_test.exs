defmodule Hotspot.AnalysisTest do
  @moduledoc """
  Runs against a real runner-produced fixture db (read-only). Assertions are
  structural, not exact counts, so they survive the fixture db being re-extracted.
  """
  # Not async: shares the singleton Hotspot.Storage with storage_test, which
  # opens/closes the global db.
  use ExUnit.Case, async: false

  alias Hotspot.Analysis

  describe "repo_stats/0" do
    test "returns non-negative counts and a last_sha" do
      stats = Analysis.repo_stats()
      assert stats.commits > 0
      assert stats.file_changes > 0
      assert is_binary(stats.last_sha)
    end
  end

  describe "tree_for_visualization/1" do
    test "builds a nested tree whose leaves carry both metric values" do
      tree = Analysis.tree_for_visualization(%{})
      assert tree.name == "root"
      assert is_list(tree.children) and tree.children != []

      leaves = collect_leaves(tree)
      assert length(leaves) > 0

      for leaf <- leaves do
        assert is_binary(leaf.path)
        assert is_integer(leaf.churn) and leaf.churn >= 0
        assert is_integer(leaf.author_count) and leaf.author_count >= 1
      end
    end

    test "path_filter narrows the result to matching paths" do
      full = Analysis.tree_for_visualization(%{}) |> collect_leaves()
      # A real top-level segment from the data makes a valid prefix filter.
      prefix = full |> hd() |> Map.fetch!(:path) |> String.split("/") |> hd()

      filtered = Analysis.tree_for_visualization(%{path_filter: prefix}) |> collect_leaves()

      assert filtered != []
      assert length(filtered) <= length(full)
      assert Enum.all?(filtered, &String.starts_with?(&1.path, prefix))
    end
  end

  defp collect_leaves(%{children: children}), do: Enum.flat_map(children, &collect_leaves/1)
  defp collect_leaves(%{path: _} = leaf), do: [leaf]
  defp collect_leaves(_), do: []
end
