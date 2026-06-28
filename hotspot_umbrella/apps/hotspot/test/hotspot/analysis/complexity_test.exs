defmodule Hotspot.Analysis.ComplexityTest do
  @moduledoc """
  The complexity axis against a hand-built schema-v2 db: `tracked_file` carries
  loc/indent, joined with each file's change frequency for the scatter.
  """
  use Hotspot.IntegrationCase

  alias Hotspot.Analysis

  setup do
    now = System.os_time(:second)

    seed_db!(
      [
        commit("c1",
          committed_at: now,
          author_name: "Ada",
          author_email: "ada@x",
          files: [{"deep.ex", 30, 0}, {"flat.ex", 5, 0}, {"gone.ex", 99, 0}]
        ),
        commit("c2",
          committed_at: now,
          author_name: "Bob",
          author_email: "bob@x",
          files: [{"deep.ex", 30, 0}]
        )
      ],
      [
        %{path: "deep.ex", loc: 100, indent_total: 800, indent_max: 24},
        %{path: "flat.ex", loc: 40, indent_total: 40, indent_max: 4},
        %{path: "logo.png", loc: nil, indent_total: nil, indent_max: nil}
      ]
    )

    :ok
  end

  test "complexity_available? is true for a schema-v2 db with a snapshot" do
    assert Analysis.complexity_available?()
  end

  test "file_complexity returns loc + derived indent_avg, nil for binary or absent" do
    deep = Analysis.file_complexity("deep.ex")
    assert deep.loc == 100
    assert deep.indent_total == 800
    assert deep.indent_max == 24
    assert deep.indent_avg == 8.0

    assert Analysis.file_complexity("logo.png") == nil
    assert Analysis.file_complexity("nope.ex") == nil
  end

  test "scatter joins frequency to complexity and drops files without metrics" do
    by_path = Map.new(Analysis.complexity_scatter(%{}), &{&1.path, &1})

    # deep.ex changed in 2 commits, indent_total 800 => hotspot_score 1600.
    assert by_path["deep.ex"].revisions == 2
    assert by_path["deep.ex"].hotspot_score == 1600
    assert by_path["flat.ex"].hotspot_score == 40

    # gone.ex has churn but no tracked_file row (deleted) => excluded.
    refute Map.has_key?(by_path, "gone.ex")
    # binary file carries no complexity => excluded.
    refute Map.has_key?(by_path, "logo.png")
  end
end
