defmodule Hotspot.IntegrationCase do
  use ExUnit.CaseTemplate

  alias Exqlite.Sqlite3

  # Mirrors HotspotRunner.Writer's DDL + schema_version; kept in sync by hand so
  # the read path is exercised against the real on-disk shape.
  @schema_version "2"

  @schema """
  CREATE TABLE commit_info (
    sha          TEXT PRIMARY KEY,
    committed_at INTEGER NOT NULL,
    author_name  TEXT NOT NULL,
    author_email TEXT NOT NULL,
    parent_count INTEGER NOT NULL,
    subject      TEXT
  );
  CREATE TABLE file_change (
    commit_sha TEXT NOT NULL,
    path       TEXT NOT NULL,
    added      INTEGER,
    deleted    INTEGER
  );
  CREATE TABLE rename_edge (
    commit_sha TEXT NOT NULL,
    old_path   TEXT NOT NULL,
    new_path   TEXT NOT NULL,
    similarity INTEGER
  );
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
  CREATE TABLE tracked_file (
    path         TEXT PRIMARY KEY,
    loc          INTEGER,
    indent_total INTEGER,
    indent_max   INTEGER
  );
  CREATE INDEX idx_file_change_commit ON file_change(commit_sha);
  CREATE INDEX idx_file_change_path   ON file_change(path);
  CREATE INDEX idx_commit_committed   ON commit_info(committed_at);
  CREATE INDEX idx_rename_new         ON rename_edge(new_path);
  CREATE INDEX idx_rename_old         ON rename_edge(old_path);
  """

  using do
    quote do
      @moduletag :integration

      import Hotspot.IntegrationCase
    end
  end

  setup do
    prev_repo = Application.get_env(:hotspot, :repo)
    prev_storage = Application.get_env(:hotspot, :storage)
    Application.put_env(:hotspot, :repo, Hotspot.Repo)
    Application.put_env(:hotspot, :storage, Hotspot.Storage)

    on_exit(fn ->
      Hotspot.Storage.close()
      restore(:repo, prev_repo)
      restore(:storage, prev_storage)
    end)

    :ok
  end

  @doc """
  Build a db from `commits` (and optional `tracked` file rows), open it through
  `Hotspot.Storage`, and return its path.

  `Hotspot.Storage` only opens files inside its configured `:db_dir`, so the file
  is written there under a unique name and removed on exit. Each `commit` is a map
  shaped by `commit/2`; `tracked` rows are `%{path, loc, indent_total, indent_max}`.
  """
  @spec seed_db!([map()], [map()]) :: String.t()
  def seed_db!(commits, tracked \\ []) do
    dir = Application.fetch_env!(:hotspot, :db_dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "seed_#{System.unique_integer([:positive])}.db")

    {:ok, conn} = Sqlite3.open(path)

    try do
      # Match the runner's WAL mode so the read-only pool doesn't try to switch it
      # (a write) on connect; checkpoint so the data lives in the main file.
      :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
      :ok = Sqlite3.execute(conn, @schema)
      set_meta(conn, "schema_version", @schema_version)
      Enum.each(commits, &insert_commit(conn, &1))
      Enum.each(tracked, &insert_tracked(conn, &1))

      last = List.last(commits)
      if last, do: set_meta(conn, "last_sha", last.sha)
      if last, do: set_meta(conn, "tracked_sha", last.sha)
      :ok = Sqlite3.execute(conn, "PRAGMA wal_checkpoint(TRUNCATE);")
    after
      Sqlite3.close(conn)
    end

    on_exit(fn ->
      Hotspot.Storage.close()
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    :ok = Hotspot.Storage.open(path)
    path
  end

  @doc """
  Seed and open a four-commit repo where `lib/a.ex` is the busiest file, coupled
  with `lib/b.ex` and `lib/c.ex` (two shared commits each).
  """
  @spec seed_coupling_repo!() :: String.t()
  def seed_coupling_repo! do
    now = System.os_time(:second)

    seed_db!([
      commit("c1", committed_at: now, files: [{"lib/a.ex", 10, 0}, {"lib/b.ex", 5, 0}]),
      commit("c2",
        committed_at: now,
        files: [{"lib/a.ex", 10, 0}, {"lib/b.ex", 5, 0}, {"lib/c.ex", 5, 0}]
      ),
      commit("c3", committed_at: now, files: [{"lib/a.ex", 10, 0}, {"lib/c.ex", 5, 0}]),
      commit("c4", committed_at: now, files: [{"lib/d.ex", 5, 0}])
    ])
  end

  @doc """
  Build a commit map for `seed_db!/2`. `:files` is a list of `{path, added, deleted}`
  tuples; `opts` overrides `:author_name`, `:author_email`, `:committed_at`,
  `:parent_count`, `:subject`, and `:renames` (list of `{old_path, new_path, similarity}`).
  """
  @spec commit(String.t(), keyword()) :: map()
  def commit(sha, opts \\ []) do
    %{
      sha: sha,
      committed_at: Keyword.get(opts, :committed_at, System.os_time(:second)),
      author_name: Keyword.get(opts, :author_name, "Ada Lovelace"),
      author_email: Keyword.get(opts, :author_email, "ada@example.com"),
      parent_count: Keyword.get(opts, :parent_count, 1),
      subject: Keyword.get(opts, :subject, "commit #{sha}"),
      files: Keyword.get(opts, :files, []),
      renames: Keyword.get(opts, :renames, [])
    }
  end

  ## Internals

  defp insert_commit(conn, c) do
    exec(
      conn,
      "INSERT INTO commit_info (sha, committed_at, author_name, author_email, parent_count, subject) VALUES (?, ?, ?, ?, ?, ?)",
      [c.sha, c.committed_at, c.author_name, c.author_email, c.parent_count, c.subject]
    )

    Enum.each(c.files, fn {path, added, deleted} ->
      exec(
        conn,
        "INSERT INTO file_change (commit_sha, path, added, deleted) VALUES (?, ?, ?, ?)",
        [
          c.sha,
          path,
          added,
          deleted
        ]
      )
    end)

    Enum.each(c.renames, fn {old_path, new_path, similarity} ->
      exec(
        conn,
        "INSERT INTO rename_edge (commit_sha, old_path, new_path, similarity) VALUES (?, ?, ?, ?)",
        [c.sha, old_path, new_path, similarity]
      )
    end)
  end

  defp insert_tracked(conn, t) do
    exec(
      conn,
      "INSERT INTO tracked_file (path, loc, indent_total, indent_max) VALUES (?, ?, ?, ?)",
      [
        t.path,
        t.loc,
        t.indent_total,
        t.indent_max
      ]
    )
  end

  defp set_meta(conn, key, value) do
    exec(conn, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value])
  end

  defp exec(conn, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, args)
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
  end

  defp restore(key, nil), do: Application.delete_env(:hotspot, key)
  defp restore(key, value), do: Application.put_env(:hotspot, key, value)
end
