defmodule Hotspot.Analysis.DefectsTest do
  use Hotspot.IntegrationCase

  alias Hotspot.Analysis

  # buggy.ex: 2 of 3 commits are fixes; clean.ex: 0 of 1.
  setup do
    now = System.os_time(:second)

    seed_db!([
      commit("c1", committed_at: now, subject: "Add buggy module", files: [{"buggy.ex", 10, 0}]),
      commit("c2", committed_at: now, subject: "Fix crash in buggy", files: [{"buggy.ex", 2, 1}]),
      commit("c3", committed_at: now, subject: "bugfix: edge case", files: [{"buggy.ex", 3, 0}]),
      commit("c4", committed_at: now, subject: "Add clean module", files: [{"clean.ex", 8, 0}])
    ])

    :ok
  end

  test "subjects_available? is true for a schema-v2 db" do
    assert Analysis.subjects_available?()
  end

  test "bug_fix_density is fix commits over total commits per file" do
    by_path = Map.new(Analysis.defects(%{}), &{&1.path, &1})

    assert by_path["buggy.ex"].commits == 3
    assert by_path["buggy.ex"].fix_commits == 2
    assert_in_delta by_path["buggy.ex"].bug_fix_density, 2 / 3, 1.0e-9

    assert by_path["clean.ex"].fix_commits == 0
    assert by_path["clean.ex"].bug_fix_density == 0.0
  end

  test "density_map keys paths to their bug-fix density" do
    map = Analysis.defect_density(%{})
    assert_in_delta map["buggy.ex"], 2 / 3, 1.0e-9
    assert map["clean.ex"] == 0.0
  end
end
