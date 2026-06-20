defmodule Hotspot.AnalysisTrackedTest do
  @moduledoc """
  With a `tracked_file` snapshot, `include_removed: false` drops deleted files and
  folds renames; without it, the filter no-ops. Builds a small hand-made db in the
  configured db_dir and opens it through `Hotspot.Storage`.
  """
  # Shares the singleton Hotspot.Storage, so not async.
  use ExUnit.Case, async: false

  alias Hotspot.Analysis

  @ddl """
  CREATE TABLE commit_info (sha TEXT PRIMARY KEY, committed_at INTEGER NOT NULL,
    author_name TEXT NOT NULL, author_email TEXT NOT NULL, parent_count INTEGER NOT NULL);
  CREATE TABLE file_change (commit_sha TEXT NOT NULL, path TEXT NOT NULL,
    added INTEGER, deleted INTEGER);
  CREATE TABLE rename_edge (commit_sha TEXT NOT NULL, old_path TEXT NOT NULL,
    new_path TEXT NOT NULL, similarity INTEGER);
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
  CREATE TABLE tracked_file (path TEXT PRIMARY KEY);
  """

  # c1 touches kept.ex, deleted.ex, old.ex; c2 renames old.ex -> new.ex and touches it.
  # HEAD (tracked_file) has kept.ex and new.ex only: deleted.ex is gone, old.ex moved.
  @rows """
  INSERT INTO commit_info VALUES ('c1', 1, 'Ada', 'ada@x', 1);
  INSERT INTO commit_info VALUES ('c2', 2, 'Bob', 'bob@x', 1);
  INSERT INTO file_change VALUES ('c1', 'kept.ex', 10, 0);
  INSERT INTO file_change VALUES ('c1', 'deleted.ex', 7, 0);
  INSERT INTO file_change VALUES ('c1', 'old.ex', 5, 0);
  INSERT INTO file_change VALUES ('c2', 'new.ex', 3, 1);
  INSERT INTO rename_edge VALUES ('c2', 'old.ex', 'new.ex', 100);
  INSERT INTO tracked_file VALUES ('kept.ex');
  INSERT INTO tracked_file VALUES ('new.ex');
  INSERT INTO meta VALUES ('last_sha', 'c2');
  INSERT INTO meta VALUES ('tracked_sha', 'c2');
  """

  setup do
    dir = Path.expand(Application.fetch_env!(:hotspot, :db_dir))
    previous = Hotspot.Storage.current()
    path = Path.join(dir, "tracked_fixture_#{System.unique_integer([:positive])}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(path)
    # Match the runner's WAL mode so the read-only pool doesn't try to switch it
    # (a write) on connect; checkpoint so the data lives in the main file.
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
    :ok = Exqlite.Sqlite3.execute(conn, @ddl <> @rows)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA wal_checkpoint(TRUNCATE);")
    :ok = Exqlite.Sqlite3.close(conn)

    :ok = Hotspot.Storage.open(path)

    on_exit(fn ->
      Hotspot.Storage.close()
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
      if previous, do: Hotspot.Storage.open(previous)
    end)

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
