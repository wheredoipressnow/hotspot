defmodule Hotspot.AnalysisCouplingTest do
  use Hotspot.IntegrationCase

  alias Hotspot.Analysis

  setup do
    seed_coupling_repo!()
    :ok
  end

  # The most-changed file is the most likely to have co-changed with others.
  defp busiest_path do
    [%{path: path} | _] = Analysis.top_hotspots(%{scope: "files", limit: 1})
    path
  end

  describe "coupling/2" do
    test "returns well-formed, ranked co-change rows for a real file" do
      path = busiest_path()
      rows = Analysis.coupling(path)

      assert is_list(rows)

      for r <- rows do
        assert is_binary(r.path) and r.path != path
        assert is_integer(r.shared_commits) and r.shared_commits >= 2
        assert is_float(r.coupling) and r.coupling > 0.0 and r.coupling <= 1.0
      end

      couplings = Enum.map(rows, & &1.coupling)
      assert couplings == Enum.sort(couplings, :desc)
    end

    test "respects :limit and :min_shared" do
      path = busiest_path()
      assert length(Analysis.coupling(path, limit: 3)) <= 3
      # An impossibly high floor yields nothing.
      assert Analysis.coupling(path, min_shared: 1_000_000) == []
    end

    test "a path that never changed has no coupling" do
      assert Analysis.coupling("does/not/exist.zzz") == []
    end
  end
end
