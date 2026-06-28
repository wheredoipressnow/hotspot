defmodule HotspotRunner.ExtractorMoxTest do
  # Not async: resolves the global `:git`/`:store` config that the opt-in `:git`
  # tests mutate, so it must run in the serial phase.
  use ExUnit.Case, async: false

  import Mox

  alias HotspotRunner.Extractor

  setup :verify_on_exit!

  # One commit slice in the framing `HotspotRunner.Parser` expects leading NUL,
  # SHA, epoch, name, email, parents, subject, then a newline and the NUL-terminated
  # numstat entries.
  defp commit_bytes(sha, epoch, parents, subject, numstat) do
    <<0>> <>
      sha <>
      <<0>> <>
      epoch <>
      <<0>> <>
      "Ada" <> <<0>> <> "ada@x" <> <<0>> <> parents <> <<0>> <> subject <> "\n" <> numstat
  end

  test "full extraction streams the log through the parser into the store" do
    sha1 = String.duplicate("a", 40)
    sha2 = String.duplicate("b", 40)

    log =
      commit_bytes(sha1, "1000", "", "first", "1\t0\ta.txt" <> <<0>>) <>
        commit_bytes(sha2, "2000", sha1, "second", "2\t0\tb.txt" <> <<0>>)

    HotspotRunner.GitMock
    |> expect(:toplevel, fn "repo" -> "/abs/repo" end)
    |> expect(:tip_sha, fn "/abs/repo", "main" -> sha2 end)
    |> expect(:open_log, fn "/abs/repo", _args ->
      port = make_ref()
      send(self(), {port, {:data, log}})
      send(self(), {port, {:exit_status, 0}})
      port
    end)
    |> expect(:tree_blobs, fn "/abs/repo", ^sha2 -> [{"blob1", "a.txt"}] end)
    |> expect(:read_blobs, fn "/abs/repo", ["blob1"] -> %{"blob1" => "code\n"} end)

    parent = self()

    HotspotRunner.StoreMock
    |> expect(:open, fn _db_path -> :writer end)
    |> expect(:set_meta, fn :writer, "repo_path", "/abs/repo" -> :ok end)
    |> expect(:set_meta, fn :writer, "ref", "main" -> :ok end)
    |> expect(:get_meta, fn :writer, "last_sha" -> nil end)
    |> expect(:write_batch, fn :writer, commits ->
      send(parent, {:batch, commits})
      :ok
    end)
    |> expect(:set_meta, fn :writer, "last_sha", ^sha2 -> :ok end)
    |> expect(:replace_tracked_files, fn :writer, tracked, ^sha2 ->
      send(parent, {:tracked, tracked})
      :ok
    end)
    |> expect(:close, fn :writer -> :ok end)

    assert {:ok, result} = Extractor.extract("repo", ref: "main")
    assert result.mode == :full
    assert result.commits_written == 2
    assert result.tip_sha == sha2
    assert result.tracked_files == 1

    assert_received {:batch, batch}
    assert Enum.map(batch, & &1.sha) == [sha1, sha2]
    assert_received {:tracked, [%{path: "a.txt", loc: 1}]}
  end

  test "stale? compares the stored last_sha against the ref tip" do
    HotspotRunner.GitMock
    |> expect(:toplevel, fn "repo" -> "/abs/repo" end)
    |> expect(:tip_sha, fn "/abs/repo", "main" -> "tip_new" end)

    HotspotRunner.StoreMock
    |> expect(:open, fn _db_path -> :writer end)
    |> expect(:get_meta, fn :writer, "last_sha" -> "tip_old" end)
    |> expect(:close, fn :writer -> :ok end)

    assert Extractor.stale?("repo", ref: "main")
  end

  test "stale? is false when the stored last_sha already equals the tip" do
    HotspotRunner.GitMock
    |> expect(:toplevel, fn "repo" -> "/abs/repo" end)
    |> expect(:tip_sha, fn "/abs/repo", "main" -> "tip_same" end)

    HotspotRunner.StoreMock
    |> expect(:open, fn _db_path -> :writer end)
    |> expect(:get_meta, fn :writer, "last_sha" -> "tip_same" end)
    |> expect(:close, fn :writer -> :ok end)

    refute Extractor.stale?("repo", ref: "main")
  end
end
