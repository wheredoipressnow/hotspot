defmodule Hotspot.Analysis.OwnershipTest do
  use Hotspot.IntegrationCase

  alias Hotspot.Analysis
  alias Hotspot.Analysis.Ownership

  # solo.ex: Ada owns 90% but has a co-author => bus factor.
  # ghost.ex: Bob owns it and last committed ~8 years ago => abandoned.
  setup do
    now = System.os_time(:second)
    recent = now - 1 * 86_400
    ancient = now - 3000 * 86_400

    seed_db!([
      commit("c1",
        committed_at: recent,
        author_name: "Ada",
        author_email: "ada@x",
        files: [{"solo.ex", 90, 0}, {"ghost.ex", 5, 0}]
      ),
      commit("c2",
        committed_at: recent,
        author_name: "Cleo",
        author_email: "cleo@x",
        files: [{"solo.ex", 10, 0}]
      ),
      commit("c3",
        committed_at: ancient,
        author_name: "Bob",
        author_email: "bob@x",
        files: [{"ghost.ex", 50, 0}]
      )
    ])

    :ok
  end

  defp by_path(rows), do: Map.new(rows, &{&1.path, &1})

  test "last_activity reports each author's most recent commit" do
    activity = Ownership.last_activity()
    assert activity["bob@x"] < activity["ada@x"]
  end

  test "flags a dominated file as bus-factor and an inactive owner as abandoned" do
    rows = by_path(Analysis.ownership(%{scope: "files"}))

    assert rows["solo.ex"].main_author == "ada@x"
    assert rows["solo.ex"].bus_factor?
    refute rows["solo.ex"].abandoned?

    assert rows["ghost.ex"].main_author == "bob@x"
    assert rows["ghost.ex"].abandoned?
  end
end
