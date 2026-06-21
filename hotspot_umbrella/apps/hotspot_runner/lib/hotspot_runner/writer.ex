defmodule HotspotRunner.Writer do
  @moduledoc """
  The write side of storage: opens (or creates) a per-repo SQLite db, owns the
  schema DDL, and writes raw facts in batched transactions.

  Uses raw `Exqlite.Sqlite3` (prepared statements + explicit transactions) for the
  bulk-insert hot path; the `Hotspot` app reads the same file through Ecto in
  read-only mode. Pragmas are tuned for bulk load (`WAL` so a reader can open the
  file concurrently while extraction runs).
  """

  alias Exqlite.Sqlite3

  # Bump when the schema or captured fields change; the reader gates new features
  # on `meta('schema_version')` so older dbs keep working until re-extracted.
  @schema_version "2"

  @schema """
  CREATE TABLE IF NOT EXISTS commit_info (
    sha          TEXT PRIMARY KEY,
    committed_at INTEGER NOT NULL,
    author_name  TEXT NOT NULL,
    author_email TEXT NOT NULL,
    parent_count INTEGER NOT NULL,
    subject      TEXT
  );

  CREATE TABLE IF NOT EXISTS file_change (
    commit_sha TEXT NOT NULL,
    path       TEXT NOT NULL,
    added      INTEGER,
    deleted    INTEGER,
    FOREIGN KEY (commit_sha) REFERENCES commit_info(sha)
  );

  CREATE TABLE IF NOT EXISTS rename_edge (
    commit_sha TEXT NOT NULL,
    old_path   TEXT NOT NULL,
    new_path   TEXT NOT NULL,
    similarity INTEGER,
    FOREIGN KEY (commit_sha) REFERENCES commit_info(sha)
  );

  CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
  );

  CREATE TABLE IF NOT EXISTS tracked_file (
    path         TEXT PRIMARY KEY,
    loc          INTEGER,
    indent_total INTEGER,
    indent_max   INTEGER
  );

  CREATE INDEX IF NOT EXISTS idx_file_change_commit ON file_change(commit_sha);
  CREATE INDEX IF NOT EXISTS idx_file_change_path   ON file_change(path);
  CREATE INDEX IF NOT EXISTS idx_commit_committed   ON commit_info(committed_at);
  CREATE INDEX IF NOT EXISTS idx_rename_new         ON rename_edge(new_path);
  CREATE INDEX IF NOT EXISTS idx_rename_old         ON rename_edge(old_path);
  """

  defstruct [:conn, :stmts]

  @type t :: %__MODULE__{conn: term(), stmts: map()}

  @doc "Open (or create) the db at `path`, apply pragmas, ensure schema, prepare statements."
  @spec open(String.t()) :: t()
  def open(path) do
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode = WAL;")
    :ok = Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL;")
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys = ON;")
    :ok = Sqlite3.execute(conn, @schema)

    w = %__MODULE__{conn: conn, stmts: prepare_all(conn)}
    set_meta(w, "schema_version", @schema_version)
    w
  end

  @doc "Release prepared statements and close the connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{conn: conn, stmts: stmts}) do
    Enum.each(stmts, fn {_name, stmt} -> Sqlite3.release(conn, stmt) end)
    Sqlite3.close(conn)
  end

  @doc """
  Write a batch of commits atomically. Per commit: delete-by-sha then insert
  (idempotent replay), then advance `meta.last_sha` to the newest commit in the
  batch. The caller batches (e.g. N=1000) before calling.
  """
  @spec write_batch(t(), [map()]) :: :ok
  def write_batch(_w, []), do: :ok

  def write_batch(%__MODULE__{conn: conn, stmts: s} = w, commits) do
    :ok = Sqlite3.execute(conn, "BEGIN")

    Enum.each(commits, fn c ->
      run(w, s.del_files, [c.sha])
      run(w, s.del_renames, [c.sha])

      run(w, s.ins_commit, [
        c.sha,
        c.committed_at,
        c.author_name,
        c.author_email,
        c.parent_count,
        c.subject
      ])

      Enum.each(c.files, fn f ->
        run(w, s.ins_file, [c.sha, f.path, f.added, f.deleted])
      end)

      Enum.each(c.renames, fn r ->
        run(w, s.ins_rename, [c.sha, r.old_path, r.new_path, r.similarity])
      end)
    end)

    last = List.last(commits)
    run(w, s.set_meta, ["last_sha", last.sha])
    :ok = Sqlite3.execute(conn, "COMMIT")
    :ok
  end

  @doc """
  Replace the whole `tracked_file` snapshot with the files present at `sha` and
  pin `meta('tracked_sha')`, in one transaction. A whole-tree snapshot, so it is
  always replaced (not appended), keeping the `tracked_sha == last_sha` invariant
  the reader checks.

  Each entry is `%{path, loc, indent_total, indent_max}`; the metric fields are
  `nil` for binary files.
  """
  @spec replace_tracked_files(t(), [map()], String.t()) :: :ok
  def replace_tracked_files(%__MODULE__{conn: conn, stmts: s} = w, files, sha) do
    :ok = Sqlite3.execute(conn, "BEGIN")
    run(w, s.del_tracked, [])

    Enum.each(files, fn f ->
      run(w, s.ins_tracked, [f.path, f.loc, f.indent_total, f.indent_max])
    end)

    run(w, s.set_meta, ["tracked_sha", sha])
    :ok = Sqlite3.execute(conn, "COMMIT")
    :ok
  end

  @doc "Read a meta value, or nil."
  @spec get_meta(t(), String.t()) :: String.t() | nil
  def get_meta(%__MODULE__{conn: conn, stmts: s}, key) do
    :ok = Sqlite3.reset(s.get_meta)
    :ok = Sqlite3.bind(s.get_meta, [key])

    case Sqlite3.step(conn, s.get_meta) do
      {:row, [value]} -> value
      :done -> nil
    end
  end

  @doc "Set a meta value (autocommit)."
  @spec set_meta(t(), String.t(), String.t()) :: :ok
  def set_meta(%__MODULE__{stmts: s} = w, key, value) do
    run(w, s.set_meta, [key, value])
  end

  @doc "Row counts + last_sha, for verification/dump."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{conn: conn} = w) do
    %{
      commits: count(conn, "commit_info"),
      files: count(conn, "file_change"),
      renames: count(conn, "rename_edge"),
      tracked: count(conn, "tracked_file"),
      last_sha: get_meta(w, "last_sha")
    }
  end

  ## Internals

  defp prepare_all(conn) do
    %{
      del_files: prep(conn, "DELETE FROM file_change WHERE commit_sha = ?"),
      del_renames: prep(conn, "DELETE FROM rename_edge WHERE commit_sha = ?"),
      ins_commit:
        prep(
          conn,
          "INSERT OR REPLACE INTO commit_info (sha, committed_at, author_name, author_email, parent_count, subject) VALUES (?, ?, ?, ?, ?, ?)"
        ),
      ins_file:
        prep(
          conn,
          "INSERT INTO file_change (commit_sha, path, added, deleted) VALUES (?, ?, ?, ?)"
        ),
      ins_rename:
        prep(
          conn,
          "INSERT INTO rename_edge (commit_sha, old_path, new_path, similarity) VALUES (?, ?, ?, ?)"
        ),
      del_tracked: prep(conn, "DELETE FROM tracked_file"),
      ins_tracked:
        prep(
          conn,
          "INSERT OR IGNORE INTO tracked_file (path, loc, indent_total, indent_max) VALUES (?, ?, ?, ?)"
        ),
      set_meta: prep(conn, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)"),
      get_meta: prep(conn, "SELECT value FROM meta WHERE key = ?")
    }
  end

  defp prep(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    stmt
  end

  # Reset, bind, and step a prepared statement to completion (no result rows).
  defp run(%__MODULE__{conn: conn}, stmt, args) do
    :ok = Sqlite3.reset(stmt)
    :ok = Sqlite3.bind(stmt, args)
    :done = Sqlite3.step(conn, stmt)
    :ok
  end

  defp count(conn, table) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT COUNT(*) FROM #{table}")

    try do
      {:row, [n]} = Sqlite3.step(conn, stmt)
      n
    after
      Sqlite3.release(conn, stmt)
    end
  end
end
