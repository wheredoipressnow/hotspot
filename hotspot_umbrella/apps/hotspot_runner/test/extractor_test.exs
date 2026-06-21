defmodule HotspotRunner.ExtractorTest do
  use ExUnit.Case, async: false

  # Builds throwaway git repos and shells out to `git`, so it is excluded by
  # default (see test_helper.exs). Run with: mix test --include git
  @moduletag :git

  alias HotspotRunner.{Extractor, Writer}

  setup do
    repo = Path.join(System.tmp_dir!(), "hotspot_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    # Isolate the db dir so we never touch the real ~/.local/share/hotspot.
    data = Path.join(System.tmp_dir!(), "hotspot_data_#{System.unique_integer([:positive])}")
    prev = System.get_env("XDG_DATA_HOME")
    System.put_env("XDG_DATA_HOME", data)

    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["config", "user.email", "ada@example.com"])
    git(repo, ["config", "user.name", "Ada Lovelace"])

    on_exit(fn ->
      File.rm_rf!(repo)
      File.rm_rf!(data)
      if prev, do: System.put_env("XDG_DATA_HOME", prev), else: System.delete_env("XDG_DATA_HOME")
    end)

    %{repo: repo}
  end

  defp git(repo, args), do: {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

  defp write_commit(repo, file, contents, msg) do
    File.write!(Path.join(repo, file), contents)
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", msg])
  end

  test "full then incremental extraction", %{repo: repo} do
    write_commit(repo, "a.txt", "one\n", "first")
    write_commit(repo, "b.txt", "two\nthree\n", "second")

    assert {:ok, full} = Extractor.extract(repo, ref: "main")
    assert full.mode == :full
    assert full.commits_written == 2
    assert full.tracked_files == 2
    assert File.regular?(full.db_path)

    # Stored db reflects the tip; not stale right after extraction.
    refute Extractor.stale?(repo, ref: "main")

    w = Writer.open(full.db_path)
    assert Writer.summary(w).commits == 2
    Writer.close(w)

    # New commit => stale => incremental adds exactly one.
    write_commit(repo, "c.txt", "four\n", "third")
    assert Extractor.stale?(repo, ref: "main")

    assert {:ok, inc} = Extractor.extract(repo, ref: "main")
    assert inc.mode == :incremental
    assert inc.commits_written == 1

    w = Writer.open(inc.db_path)
    assert Writer.summary(w).commits == 3
    Writer.close(w)
  end

  test "records a rename edge", %{repo: repo} do
    write_commit(repo, "old.txt", String.duplicate("line\n", 20), "add")
    File.rename!(Path.join(repo, "old.txt"), Path.join(repo, "new.txt"))
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", "rename"])

    assert {:ok, r} = Extractor.extract(repo, ref: "main")

    w = Writer.open(r.db_path)
    assert Writer.summary(w).renames == 1
    Writer.close(w)
  end
end
