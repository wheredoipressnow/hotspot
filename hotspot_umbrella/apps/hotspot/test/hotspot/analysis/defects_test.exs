defmodule Hotspot.Analysis.DefectsTest do
  @moduledoc """
  Subject classification is pure; `summary/1` is checked against a hand-built
  schema-v2 db carrying commit subjects.
  """
  use ExUnit.Case, async: false

  alias Hotspot.Analysis
  alias Hotspot.Analysis.Defects

  describe "fix?/1 and revert?/1" do
    test "recognizes fix keywords and issue references" do
      assert Defects.fix?("Fix the parser")
      assert Defects.fix?("bugfix: off-by-one")
      assert Defects.fix?("resolves the crash")
      assert Defects.fix?("address #123")
      refute Defects.fix?("Add a feature")
      refute Defects.fix?(nil)
    end

    test "recognizes reverts only at the start" do
      assert Defects.revert?("Revert \"bad change\"")
      refute Defects.revert?("this reverts nothing in particular")
      refute Defects.revert?("Add revert button")
    end
  end

  describe "summary/1 against a db" do
    @ddl """
    CREATE TABLE commit_info (sha TEXT PRIMARY KEY, committed_at INTEGER NOT NULL,
      author_name TEXT NOT NULL, author_email TEXT NOT NULL, parent_count INTEGER NOT NULL,
      subject TEXT);
    CREATE TABLE file_change (commit_sha TEXT NOT NULL, path TEXT NOT NULL,
      added INTEGER, deleted INTEGER);
    CREATE TABLE rename_edge (commit_sha TEXT NOT NULL, old_path TEXT NOT NULL,
      new_path TEXT NOT NULL, similarity INTEGER);
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """

    setup do
      now = System.os_time(:second)

      # buggy.ex: 2 of 3 commits are fixes; clean.ex: 0 of 1.
      rows = """
      INSERT INTO commit_info VALUES ('c1', #{now}, 'Ada', 'ada@x', 1, 'Add buggy module');
      INSERT INTO commit_info VALUES ('c2', #{now}, 'Ada', 'ada@x', 1, 'Fix crash in buggy');
      INSERT INTO commit_info VALUES ('c3', #{now}, 'Ada', 'ada@x', 1, 'bugfix: edge case');
      INSERT INTO commit_info VALUES ('c4', #{now}, 'Ada', 'ada@x', 1, 'Add clean module');
      INSERT INTO file_change VALUES ('c1', 'buggy.ex', 10, 0);
      INSERT INTO file_change VALUES ('c2', 'buggy.ex', 2, 1);
      INSERT INTO file_change VALUES ('c3', 'buggy.ex', 3, 0);
      INSERT INTO file_change VALUES ('c4', 'clean.ex', 8, 0);
      INSERT INTO meta VALUES ('schema_version', '2');
      INSERT INTO meta VALUES ('last_sha', 'c4');
      """

      dir = Path.expand(Application.fetch_env!(:hotspot, :db_dir))
      previous = Hotspot.Storage.current()
      path = Path.join(dir, "defects_#{System.unique_integer([:positive])}.db")

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

    test "subjects_available? is true for a schema-v2 db" do
      assert Analysis.subjects_available?()
    end

    test "bug_fix_density is fix commits over total commits per file" do
      by_path = Map.new(Analysis.defects(%{}), &{&1.path, &1})

      assert by_path["buggy.ex"].commits == 3
      assert by_path["buggy.ex"].fix_commits == 2
      assert_in_delta by_path["buggy.ex"].bug_fix_density, 2 / 3, 1.0e-9

      assert by_path["clean.ex"].fix_commits == 0
      assert by_path["clean.ex"].bug_fix_density == 0.0
    end

    test "density_map keys paths to their bug-fix density" do
      map = Analysis.defect_density(%{})
      assert_in_delta map["buggy.ex"], 2 / 3, 1.0e-9
      assert map["clean.ex"] == 0.0
    end
  end
end
