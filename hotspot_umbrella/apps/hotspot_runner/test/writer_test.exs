defmodule HotspotRunner.WriterTest do
  use ExUnit.Case, async: true

  alias HotspotRunner.Writer

  setup do
    name = "hotspot_writer_#{System.unique_integer([:positive])}_#{:erlang.system_time()}.db"
    path = Path.join(System.tmp_dir!(), name)
    # Guard against a stale file from a previous run (open is create-if-missing).
    Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1))

    writer = Writer.open(path)

    on_exit(fn ->
      Writer.close(writer)
      Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1))
    end)

    %{writer: writer, path: path}
  end

  defp commit(sha, opts) do
    %{
      sha: sha,
      committed_at: opts[:at] || 1_700_000_000,
      author_name: opts[:name] || "Ada",
      author_email: opts[:email] || "ada@example.com",
      parent_count: opts[:parents] || 1,
      files: opts[:files] || [],
      renames: opts[:renames] || []
    }
  end

  test "writes commits, files, renames and advances last_sha", %{writer: w} do
    commits = [
      commit("aaa", parents: 0, files: [%{path: "a.txt", added: 2, deleted: 0}]),
      commit("bbb",
        files: [%{path: "src/app.ts", added: 1, deleted: 0}],
        renames: [%{old_path: "src/main.ts", new_path: "src/app.ts", similarity: nil}]
      )
    ]

    Writer.write_batch(w, commits)

    s = Writer.summary(w)
    assert s.commits == 2
    assert s.files == 2
    assert s.renames == 1
    assert s.last_sha == "bbb"
  end

  test "stores binary changes as NULL", %{writer: w} do
    Writer.write_batch(w, [
      commit("aaa", files: [%{path: "logo.bin", added: nil, deleted: nil}])
    ])

    assert %{conn: conn} = w
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT added, deleted FROM file_change")
    assert {:row, [nil, nil]} = Exqlite.Sqlite3.step(conn, stmt)
  end

  test "merge commits keep parent_count but write no file rows", %{writer: w} do
    Writer.write_batch(w, [commit("merge", parents: 2, files: [])])

    s = Writer.summary(w)
    assert s.commits == 1
    assert s.files == 0

    {:ok, stmt} = Exqlite.Sqlite3.prepare(w.conn, "SELECT parent_count FROM commit_info")
    assert {:row, [2]} = Exqlite.Sqlite3.step(w.conn, stmt)
  end

  test "replaying a commit does not duplicate file rows (idempotent)", %{writer: w} do
    c = commit("aaa", files: [%{path: "a.txt", added: 1, deleted: 0}])
    Writer.write_batch(w, [c])
    Writer.write_batch(w, [c])

    assert Writer.summary(w).files == 1
  end

  test "meta round-trips", %{writer: w} do
    assert Writer.get_meta(w, "ref") == nil
    Writer.set_meta(w, "ref", "main")
    assert Writer.get_meta(w, "ref") == "main"
  end

  test "tracked snapshot is replaced wholesale and pins tracked_sha", %{writer: w} do
    Writer.replace_tracked_files(w, ["a.txt", "b.txt"], "sha1")
    assert Writer.summary(w).tracked == 2
    assert Writer.get_meta(w, "tracked_sha") == "sha1"

    Writer.replace_tracked_files(w, ["c.txt"], "sha2")
    assert Writer.summary(w).tracked == 1
    assert Writer.get_meta(w, "tracked_sha") == "sha2"
  end
end
