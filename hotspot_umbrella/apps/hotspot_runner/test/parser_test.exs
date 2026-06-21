defmodule HotspotRunner.ParserTest do
  use ExUnit.Case, async: false

  # Builds throwaway git repos and shells out to `git`, so it is excluded by
  # default (see test_helper.exs). Run with: mix test --include git
  @moduletag :git

  alias HotspotRunner.{Git, Parser}

  # One repo exercising every framing edge case the parser must handle, captured
  # as the real `git log -z` byte stream. SHAs vary per run, so assertions are
  # structural rather than against fixed SHAs.
  setup_all do
    repo = Path.join(System.tmp_dir!(), "hotspot_parser_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    build_repo(repo)
    bytes = capture_log(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    %{bytes: bytes, commits: Parser.parse(bytes)}
  end

  test "root commit is first, with parent_count 0 and its files", %{commits: commits} do
    root = hd(commits)
    assert root.parent_count == 0
    assert root.author_name == "Ada Lovelace"
    assert root.author_email == "ada@example.com"
    assert root.subject == "root"
    assert Enum.map(root.files, & &1.path) |> Enum.sort() == ["a.txt", "src/main.ts"]
  end

  test "captures the commit subject", %{commits: commits} do
    subjects = Enum.map(commits, & &1.subject)
    assert "binary" in subjects
    assert "merge" in subjects
  end

  test "binary files have nil added/deleted", %{commits: commits} do
    file =
      commits
      |> Enum.flat_map(& &1.files)
      |> Enum.find(&(&1.path == "logo.bin"))

    assert file == %{path: "logo.bin", added: nil, deleted: nil}
  end

  test "rename records an edge and attributes the change to the new path", %{commits: commits} do
    c = Enum.find(commits, &(&1.renames != []))
    assert [%{old_path: "src/main.ts", new_path: "src/app.ts"}] = c.renames
    assert Enum.any?(c.files, &(&1.path == "src/app.ts"))
  end

  test "multibyte paths survive", %{commits: commits} do
    paths = Enum.flat_map(commits, fn c -> Enum.map(c.files, & &1.path) end)
    assert "café ☕.txt" in paths
  end

  test "empty commit has parent_count 1 and no files or renames", %{commits: commits} do
    assert Enum.any?(commits, &(&1.parent_count == 1 and &1.files == [] and &1.renames == []))
  end

  test "merge commit has parent_count 2 and no file rows", %{commits: commits} do
    merge = List.last(commits)
    assert merge.parent_count == 2
    assert merge.files == []
  end

  test "streaming push/finish matches whole-buffer parse across chunk sizes", %{
    bytes: bytes,
    commits: expected
  } do
    for size <- [1, 7, 64, 256, 100_000] do
      {state, got} =
        bytes
        |> chunks(size)
        |> Enum.reduce({Parser.new(), []}, fn chunk, {state, acc} ->
          {state, commits} = Parser.push(state, chunk)
          {state, acc ++ commits}
        end)

      got = got ++ Parser.finish(state)
      assert Enum.map(got, & &1.sha) == Enum.map(expected, & &1.sha), "chunk size #{size}"
    end
  end

  # --- repo construction -----------------------------------------------------

  defp build_repo(repo) do
    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["config", "user.email", "ada@example.com"])
    git(repo, ["config", "user.name", "Ada Lovelace"])

    File.write!(Path.join(repo, "a.txt"), "1\n2\n")
    File.mkdir_p!(Path.join(repo, "src"))
    File.write!(Path.join(repo, "src/main.ts"), "x\n")
    add_commit(repo, "root")

    # NUL bytes make git treat the file as binary (numstat shows -/-).
    File.write!(Path.join(repo, "logo.bin"), <<0, 1, 2, 0, 255, 0>>)
    add_commit(repo, "binary")

    # Pure rename: unchanged content => 100% similarity => -M reports a rename.
    git(repo, ["mv", "src/main.ts", "src/app.ts"])
    git(repo, ["commit", "-q", "-m", "rename"])

    File.write!(Path.join(repo, "café ☕.txt"), "y\n")
    add_commit(repo, "multibyte")

    git(repo, ["commit", "-q", "--allow-empty", "-m", "empty"])

    # Merge with two parents: under --numstat a clean merge emits no file rows.
    git(repo, ["checkout", "-q", "-b", "feature"])
    File.write!(Path.join(repo, "feature.txt"), "f\n")
    add_commit(repo, "feature")
    git(repo, ["checkout", "-q", "main"])
    File.write!(Path.join(repo, "main2.txt"), "m\n")
    add_commit(repo, "main2")
    git(repo, ["merge", "-q", "--no-ff", "-m", "merge", "feature"])
  end

  defp add_commit(repo, msg) do
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", msg])
  end

  defp git(repo, args), do: {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

  defp capture_log(repo) do
    {bytes, 0} = System.cmd("git", Git.full_log_args("HEAD"), cd: repo)
    bytes
  end

  defp chunks(<<>>, _size), do: []
  defp chunks(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunks(bin, size) do
    <<head::binary-size(^size), rest::binary>> = bin
    [head | chunks(rest, size)]
  end
end
