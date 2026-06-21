defmodule Hotspot.Analysis.OwnershipTest do
  @moduledoc """
  Bus-factor and abandoned-owner flags. The classifiers are pure; `summary/1` and
  `last_activity/0` are checked against a hand-built db.
  """
  use ExUnit.Case, async: false

  alias Hotspot.Analysis
  alias Hotspot.Analysis.Ownership

  describe "bus_factor?/2" do
    test "flags a file one author dominates (multi-author, share over threshold)" do
      assert Ownership.bus_factor?(%{ownership: 0.7, author_count: 3}, 0.6)
    end

    test "does not flag a sole-author file (no factor to lose)" do
      refute Ownership.bus_factor?(%{ownership: 1.0, author_count: 1}, 0.6)
    end

    test "does not flag a well-shared file" do
      refute Ownership.bus_factor?(%{ownership: 0.4, author_count: 4}, 0.6)
    end
  end

  describe "abandoned?/3" do
    test "flags a file whose owner has not committed since the cutoff" do
      activity = %{"ada@x" => 100}
      assert Ownership.abandoned?(%{main_author: "ada@x"}, activity, 200)
    end

    test "does not flag a file whose owner is still active" do
      activity = %{"ada@x" => 300}
      refute Ownership.abandoned?(%{main_author: "ada@x"}, activity, 200)
    end

    test "a churn-free file (no owner) is never abandoned" do
      refute Ownership.abandoned?(%{main_author: nil}, %{}, 200)
    end
  end

  describe "summary/1 against a db" do
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
      ancient = now - 3000 * 86_400

      # solo.ex: Ada owns 90% but is the only meaningful author with a co-author => bus factor.
      # ghost.ex: Bob owns it and last committed ~8 years ago => abandoned.
      rows = """
      INSERT INTO commit_info VALUES ('c1', #{recent}, 'Ada', 'ada@x', 1);
      INSERT INTO commit_info VALUES ('c2', #{recent}, 'Cleo', 'cleo@x', 1);
      INSERT INTO commit_info VALUES ('c3', #{ancient}, 'Bob', 'bob@x', 1);
      INSERT INTO file_change VALUES ('c1', 'solo.ex', 90, 0);
      INSERT INTO file_change VALUES ('c2', 'solo.ex', 10, 0);
      INSERT INTO file_change VALUES ('c3', 'ghost.ex', 50, 0);
      INSERT INTO file_change VALUES ('c1', 'ghost.ex', 5, 0);
      INSERT INTO meta VALUES ('last_sha', 'c1');
      """

      dir = Path.expand(Application.fetch_env!(:hotspot, :db_dir))
      previous = Hotspot.Storage.current()
      path = Path.join(dir, "ownership_#{System.unique_integer([:positive])}.db")

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

    defp by_path(rows), do: Map.new(rows, &{&1.path, &1})

    test "last_activity reports each author's most recent commit" do
      activity = Ownership.last_activity()
      assert activity["bob@x"] < activity["ada@x"]
    end

    test "flags a dominated file as bus-factor and an inactive owner as abandoned" do
      rows = by_path(Analysis.ownership(%{scope: "files"}))

      assert rows["solo.ex"].main_author == "ada@x"
      assert rows["solo.ex"].bus_factor?
      refute rows["solo.ex"].abandoned?

      assert rows["ghost.ex"].main_author == "bob@x"
      assert rows["ghost.ex"].abandoned?
    end
  end
end
