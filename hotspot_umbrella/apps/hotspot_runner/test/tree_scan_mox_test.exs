defmodule HotspotRunner.TreeScanMoxTest do
  # Not async: resolves the global `:git` config that the opt-in `:git` tests mutate.
  use ExUnit.Case, async: false

  import Mox

  alias HotspotRunner.TreeScan

  setup :verify_on_exit!

  test "scans each blob, computing indent metrics and nil for binary content" do
    blobs = [{"sha_a", "a.ex"}, {"sha_bin", "logo.bin"}]
    contents = %{"sha_a" => "def f do\n  :ok\nend\n", "sha_bin" => <<0, 1, 2, 0, 255>>}

    HotspotRunner.GitMock
    |> expect(:tree_blobs, fn "repo", "HEAD" -> blobs end)
    |> expect(:read_blobs, fn "repo", shas ->
      assert shas == ["sha_a", "sha_bin"]
      contents
    end)

    by_path = "repo" |> TreeScan.scan("HEAD") |> Map.new(&{&1.path, &1})

    assert by_path["a.ex"] == %{path: "a.ex", loc: 3, indent_total: 2, indent_max: 2}

    assert by_path["logo.bin"] == %{
             path: "logo.bin",
             loc: nil,
             indent_total: nil,
             indent_max: nil
           }
  end

  test "a blob with no readable content carries nil metrics" do
    HotspotRunner.GitMock
    |> expect(:tree_blobs, fn _cwd, _ref -> [{"sha_x", "x.ex"}] end)
    |> expect(:read_blobs, fn _cwd, _shas -> %{} end)

    assert TreeScan.scan("repo", "HEAD") == [
             %{path: "x.ex", loc: nil, indent_total: nil, indent_max: nil}
           ]
  end
end
