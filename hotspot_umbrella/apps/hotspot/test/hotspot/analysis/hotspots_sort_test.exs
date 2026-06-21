defmodule Hotspot.Analysis.HotspotsSortTest do
  @moduledoc """
  The Top-hotspots `sort` param against a hand-built db. Timestamps are relative to
  now so recency weighting separates files that have identical raw churn. Builds the
  db in the configured db_dir and opens it through `Hotspot.Storage`.
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
  """

  setup do
    now = System.os_time(:second)
    recent = now - 1 * 86_400
    old = now - 3000 * 86_400

    # recent.ex and old.ex have equal raw churn (50) but recent.ex changed yesterday
    # and old.ex ~8 years ago; many.ex has the most raw churn and most authors.
    rows = """
    INSERT INTO commit_info VALUES ('c1', #{recent}, 'Ada', 'ada@x', 1);
    INSERT INTO commit_info VALUES ('c2', #{old}, 'Bob', 'bob@x', 1);
    INSERT INTO commit_info VALUES ('c3', #{old}, 'Cleo', 'cleo@x', 1);
    INSERT INTO file_change VALUES ('c1', 'recent.ex', 50, 0);
    INSERT INTO file_change VALUES ('c2', 'old.ex', 50, 0);
    INSERT INTO file_change VALUES ('c2', 'many.ex', 40, 0);
    INSERT INTO file_change VALUES ('c3', 'many.ex', 40, 0);
    INSERT INTO meta VALUES ('last_sha', 'c1');
    """

    dir = Path.expand(Application.fetch_env!(:hotspot, :db_dir))
    previous = Hotspot.Storage.current()
    path = Path.join(dir, "hotspots_sort_#{System.unique_integer([:positive])}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
    :ok = Exqlite.Sqlite3.execute(conn, @ddl <> rows)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA wal_checkpoint(TRUNCATE);")
    :ok = Exqlite.Sqlite3.close(conn)

    :ok = Hotspot.Storage.open(path)

    on_exit(fn ->
      Hotspot.Storage.close()
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
      if previous, do: Hotspot.Storage.open(previous)
    end)

    %{recent_at: recent}
  end

  defp paths(rows), do: Enum.map(rows, & &1.path)

  test "sort: churn ranks by raw churn (recent and old tie below many)" do
    rows = Analysis.top_hotspots(%{sort: "churn", scope: "files"})
    assert hd(paths(rows)) == "many.ex"
  end

  test "sort: recency_churn ranks the recently-changed file first" do
    rows = Analysis.top_hotspots(%{sort: "recency_churn", scope: "files"})
    # recent.ex (churn 50, yesterday) outweighs many.ex (churn 80, ~8y ago) and old.ex.
    assert hd(paths(rows)) == "recent.ex"
  end

  test "sort: last_changed orders by the most recent commit, and reports its epoch" do
    rows = Analysis.top_hotspots(%{sort: "last_changed", scope: "files"})
    top = hd(rows)
    assert top.path == "recent.ex"
    assert is_integer(top.last_changed)

    last_changes = Enum.map(rows, & &1.last_changed)
    assert last_changes == Enum.sort(last_changes, :desc)
  end

  test "every row carries all four metric values" do
    for row <- Analysis.top_hotspots(%{sort: "churn", scope: "files"}) do
      assert is_integer(row.churn)
      assert is_integer(row.author_count)
      assert is_integer(row.recency_churn)
      assert is_integer(row.last_changed)
    end
  end
end
