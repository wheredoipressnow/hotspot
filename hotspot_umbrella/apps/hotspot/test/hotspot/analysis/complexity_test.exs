defmodule Hotspot.Analysis.ComplexityTest do
  @moduledoc """
  The complexity axis against a hand-built schema-v2 db: `tracked_file` carries
  loc/indent, joined with each file's change frequency for the scatter.
  """
  use ExUnit.Case, async: false

  alias Hotspot.Analysis

  @ddl """
  CREATE TABLE commit_info (sha TEXT PRIMARY KEY, committed_at INTEGER NOT NULL,
    author_name TEXT NOT NULL, author_email TEXT NOT NULL, parent_count INTEGER NOT NULL,
    subject TEXT);
  CREATE TABLE file_change (commit_sha TEXT NOT NULL, path TEXT NOT NULL,
    added INTEGER, deleted INTEGER);
  CREATE TABLE rename_edge (commit_sha TEXT NOT NULL, old_path TEXT NOT NULL,
    new_path TEXT NOT NULL, similarity INTEGER);
  CREATE TABLE tracked_file (path TEXT PRIMARY KEY, loc INTEGER, indent_total INTEGER,
    indent_max INTEGER);
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
  """

  setup do
    now = System.os_time(:second)

    rows = """
    INSERT INTO commit_info VALUES ('c1', #{now}, 'Ada', 'ada@x', 1, 'work');
    INSERT INTO commit_info VALUES ('c2', #{now}, 'Bob', 'bob@x', 1, 'work');
    INSERT INTO file_change VALUES ('c1', 'deep.ex', 30, 0);
    INSERT INTO file_change VALUES ('c2', 'deep.ex', 30, 0);
    INSERT INTO file_change VALUES ('c1', 'flat.ex', 5, 0);
    INSERT INTO file_change VALUES ('c1', 'gone.ex', 99, 0);
    INSERT INTO tracked_file VALUES ('deep.ex', 100, 800, 24);
    INSERT INTO tracked_file VALUES ('flat.ex', 40, 40, 4);
    INSERT INTO tracked_file VALUES ('logo.png', NULL, NULL, NULL);
    INSERT INTO meta VALUES ('schema_version', '2');
    INSERT INTO meta VALUES ('last_sha', 'c1');
    INSERT INTO meta VALUES ('tracked_sha', 'c1');
    """

    dir = Path.expand(Application.fetch_env!(:hotspot, :db_dir))
    previous = Hotspot.Storage.current()
    path = Path.join(dir, "complexity_#{System.unique_integer([:positive])}.db")

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

    :ok
  end

  test "complexity_available? is true for a schema-v2 db with a snapshot" do
    assert Analysis.complexity_available?()
  end

  test "file_complexity returns loc + derived indent_avg, nil for binary or absent" do
    deep = Analysis.file_complexity("deep.ex")
    assert deep.loc == 100
    assert deep.indent_total == 800
    assert deep.indent_max == 24
    assert deep.indent_avg == 8.0

    assert Analysis.file_complexity("logo.png") == nil
    assert Analysis.file_complexity("nope.ex") == nil
  end

  test "scatter joins frequency to complexity and drops files without metrics" do
    by_path = Map.new(Analysis.complexity_scatter(%{}), &{&1.path, &1})

    # deep.ex changed in 2 commits, indent_total 800 => hotspot_score 1600.
    assert by_path["deep.ex"].revisions == 2
    assert by_path["deep.ex"].hotspot_score == 1600
    assert by_path["flat.ex"].hotspot_score == 40

    # gone.ex has churn but no tracked_file row (deleted) => excluded.
    refute Map.has_key?(by_path, "gone.ex")
    # binary file carries no complexity => excluded.
    refute Map.has_key?(by_path, "logo.png")
  end
end
