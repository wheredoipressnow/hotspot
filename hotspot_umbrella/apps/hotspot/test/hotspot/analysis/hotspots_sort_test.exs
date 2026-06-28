defmodule Hotspot.Analysis.HotspotsSortTest do
  use Hotspot.IntegrationCase

  alias Hotspot.Analysis

  setup do
    now = System.os_time(:second)
    recent = now - 1 * 86_400
    old = now - 3000 * 86_400

    # recent.ex and old.ex have equal raw churn (50) but recent.ex changed yesterday
    # and old.ex ~8 years ago; many.ex has the most raw churn and most authors.
    seed_db!([
      commit("c1",
        committed_at: recent,
        author_name: "Ada",
        author_email: "ada@x",
        files: [{"recent.ex", 50, 0}]
      ),
      commit("c2",
        committed_at: old,
        author_name: "Bob",
        author_email: "bob@x",
        files: [{"old.ex", 50, 0}, {"many.ex", 40, 0}]
      ),
      commit("c3",
        committed_at: old,
        author_name: "Cleo",
        author_email: "cleo@x",
        files: [{"many.ex", 40, 0}]
      )
    ])

    %{recent_at: recent}
  end

  defp paths(rows), do: Enum.map(rows, & &1.path)

  test "sort: churn ranks by raw churn (recent and old tie below many)" do
    rows = Analysis.top_hotspots(%{sort: "churn", scope: "files"})
    assert hd(paths(rows)) == "many.ex"
  end

  test "sort: recency_churn ranks the recently-changed file first" do
    rows = Analysis.top_hotspots(%{sort: "recency_churn", scope: "files"})
    # recent.ex (churn 50, yesterday) outweighs many.ex (churn 80, ~8y ago) and old.ex.
    assert hd(paths(rows)) == "recent.ex"
  end

  test "sort: last_changed orders by the most recent commit, and reports its epoch" do
    rows = Analysis.top_hotspots(%{sort: "last_changed", scope: "files"})
    top = hd(rows)
    assert top.path == "recent.ex"
    assert is_integer(top.last_changed)

    last_changes = Enum.map(rows, & &1.last_changed)
    assert last_changes == Enum.sort(last_changes, :desc)
  end

  test "every row carries all four metric values" do
    for row <- Analysis.top_hotspots(%{sort: "churn", scope: "files"}) do
      assert is_integer(row.churn)
      assert is_integer(row.author_count)
      assert is_integer(row.recency_churn)
      assert is_integer(row.last_changed)
    end
  end
end
