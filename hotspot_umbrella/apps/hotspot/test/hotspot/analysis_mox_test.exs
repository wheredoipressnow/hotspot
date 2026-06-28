defmodule Hotspot.AnalysisMoxTest do
  # Not async: resolves the global `:repo`/`:storage` config that the opt-in
  # `:integration` tests mutate, so it must run in the serial phase.
  use ExUnit.Case, async: false

  import Mox

  alias Hotspot.Analysis
  alias Hotspot.Storage.{Commit, FileChange, RenameEdge}

  setup :verify_on_exit!

  describe "with no db loaded" do
    setup do
      stub(Hotspot.StorageMock, :loaded?, fn -> false end)
      :ok
    end

    test "reads short-circuit to {:error, :no_database} without touching the repo" do
      # No expectation is set on Hotspot.RepoMock: if any of these reached the
      # repo, Mox would raise. That is the hermeticity guarantee.
      assert Analysis.tree_for_visualization(%{}) == {:error, :no_database}
      assert Analysis.top_hotspots(%{}) == {:error, :no_database}
      assert Analysis.repo_stats() == {:error, :no_database}
      assert Analysis.coupling("a.ex") == {:error, :no_database}
    end

    test "availability flags are false when no db is loaded" do
      refute Analysis.removed_filter_available?()
      refute Analysis.subjects_available?()
      refute Analysis.complexity_available?()
    end
  end

  describe "with a db loaded" do
    setup do
      stub(Hotspot.StorageMock, :loaded?, fn -> true end)
      :ok
    end

    test "repo_stats aggregates counts and reads last_sha through the repo" do
      Hotspot.RepoMock
      |> expect(:aggregate, 3, fn
        Commit, :count, :sha -> 5
        FileChange, :count, :path -> 12
        RenameEdge, :count, :new_path -> 1
      end)
      |> expect(:one, fn _query -> "deadbeef" end)

      assert Analysis.repo_stats() == %{
               commits: 5,
               file_changes: 12,
               renames: 1,
               last_sha: "deadbeef"
             }
    end

    test "subjects_available? is true when schema_version >= 2" do
      expect(Hotspot.RepoMock, :one, fn _query -> "2" end)
      assert Analysis.subjects_available?()
    end

    test "subjects_available? is false on an older db without the schema_version key" do
      expect(Hotspot.RepoMock, :one, fn _query -> nil end)
      refute Analysis.subjects_available?()
    end
  end
end
