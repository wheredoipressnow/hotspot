defmodule HotspotRunner.TreeScanTest do
  use HotspotRunner.GitCase

  alias HotspotRunner.TreeScan

  setup do
    repo = Path.join(System.tmp_dir!(), "hotspot_tree_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["config", "user.email", "ada@example.com"])
    git(repo, ["config", "user.name", "Ada Lovelace"])
    on_exit(fn -> File.rm_rf!(repo) end)
    %{repo: repo}
  end

  defp git(repo, args), do: {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

  test "scans every blob with size + indentation metrics", %{repo: repo} do
    File.write!(Path.join(repo, "a.ex"), "def f do\n  :ok\nend\n")
    File.mkdir_p!(Path.join(repo, "src"))
    File.write!(Path.join(repo, "src/b.txt"), "flat\n")
    File.write!(Path.join(repo, "logo.bin"), <<0, 1, 2, 0, 255>>)
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", "init"])

    by_path = repo |> TreeScan.scan("HEAD") |> Map.new(&{&1.path, &1})

    assert map_size(by_path) == 3

    assert by_path["a.ex"] == %{path: "a.ex", loc: 3, indent_total: 2, indent_max: 2}
    assert by_path["src/b.txt"] == %{path: "src/b.txt", loc: 1, indent_total: 0, indent_max: 0}

    # Binary blob is kept but carries nil metrics.
    assert by_path["logo.bin"] == %{
             path: "logo.bin",
             loc: nil,
             indent_total: nil,
             indent_max: nil
           }
  end

  test "an empty tree yields no entries", %{repo: repo} do
    git(repo, ["commit", "-q", "--allow-empty", "-m", "empty"])
    assert TreeScan.scan(repo, "HEAD") == []
  end
end
