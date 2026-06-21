defmodule HotspotRunner.XrayTest do
  use ExUnit.Case, async: true

  alias HotspotRunner.Xray

  defp ev(function, churn, author, committed_at, sha),
    do: %{function: function, churn: churn, author: author, committed_at: committed_at, sha: sha}

  # Span [1000, 2600] -> 16 buckets of width 100. Indices: 1000->0, 1800->8, 2600->15.
  # Commits: s1 touches A only; s2 touches A only; s3 touches A and B.
  defp events do
    [
      ev("A", 10, "ada", 1000, "s1"),
      ev("A", 3, "ada", 1000, "s1"),
      ev("A", 5, "bob", 2600, "s2"),
      ev("A", 2, "ada", 1800, "s3"),
      ev("B", 7, "ada", 1800, "s3")
    ]
  end

  defp history, do: Xray.analyze(events(), now: 2600, half_life: 1000)

  defp region(h, name), do: Enum.find(h.regions, &(&1.name == name))

  test "regions are ranked by churn, with totals matching their events" do
    h = history()
    assert Enum.map(h.regions, & &1.name) == ["A", "B"]
    assert region(h, "A").churn == 20
    assert region(h, "B").churn == 7
  end

  test "heat buckets churn over the shared time axis" do
    a = region(history(), "A")
    assert length(a.heat) == 16
    # s1 (t=1000) -> bucket 0 = 10+3; s3 (t=1800) -> bucket 8 = 2; s2 (t=2600) -> bucket 15 = 5.
    assert Enum.at(a.heat, 0) == 13
    assert Enum.at(a.heat, 8) == 2
    assert Enum.at(a.heat, 15) == 5
    assert Enum.sum(a.heat) == a.churn
  end

  test "16 bucket labels and the file span are reported" do
    h = history()
    assert length(h.buckets) == 16
    assert Enum.all?(h.buckets, &is_binary(&1.label))
    assert h.span == %{first: 1000, last: 2600}
  end

  test "cohesion measures distinct regions touched per commit" do
    %{cohesion: c} = history()
    # s1 -> {A}, s2 -> {A}, s3 -> {A,B}: mean (1+1+2)/3, one of three commits multi-region.
    assert c.regions_per_commit == 1.33
    assert c.multi_region_ratio == 0.33
  end

  test "ownership reports the dominant author's churn share per region" do
    h = history()
    # A: ada 10+3+2=15, bob 5 -> 15/20.
    a = region(h, "A")
    assert a.top_author == "ada"
    assert a.top_author_share == 0.75
    assert a.commit_count == 3
    # B: only ada.
    assert region(h, "B").top_author_share == 1.0
  end

  test "empty history is well-formed" do
    h = Xray.analyze([], [])
    assert h.regions == []
    assert h.buckets == []
    assert h.span == nil
    assert h.cohesion == %{regions_per_commit: 0.0, multi_region_ratio: 0.0}
  end
end
