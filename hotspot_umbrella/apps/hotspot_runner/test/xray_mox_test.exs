defmodule HotspotRunner.XrayMoxTest do
  # Not async: resolves the global `:git` config that the opt-in `:git` tests mutate.
  use ExUnit.Case, async: false

  import Mox

  alias HotspotRunner.Xray

  setup :verify_on_exit!

  describe "file_history/3" do
    test "propagates a git error" do
      expect(HotspotRunner.GitMock, :file_log, fn "repo", "HEAD", "a.ex", nil, nil ->
        {:error, "no such path"}
      end)

      assert Xray.file_history("repo", "a.ex") == {:error, "no such path"}
    end

    test "empty git output yields a well-formed empty history" do
      expect(HotspotRunner.GitMock, :file_log, fn _repo, _ref, _path, _since, _until ->
        {:ok, ""}
      end)

      assert {:ok, history} = Xray.file_history("repo", "a.ex")
      assert history.regions == []
      assert history.span == nil
      assert history.cohesion == %{regions_per_commit: 0.0, multi_region_ratio: 0.0}
    end

    test "forwards :ref/:since/:until to the git seam" do
      expect(HotspotRunner.GitMock, :file_log, fn "repo", "main", "a.ex", 100, 200 ->
        {:ok, ""}
      end)

      assert {:ok, _} = Xray.file_history("repo", "a.ex", ref: "main", since: 100, until: 200)
    end
  end

  describe "file_source/3" do
    test "propagates a git error" do
      expect(HotspotRunner.GitMock, :blame, fn "repo", "HEAD", "a.ex" ->
        {:error, "not a file"}
      end)

      assert Xray.file_source("repo", "a.ex") == {:error, "not a file"}
    end
  end
end
