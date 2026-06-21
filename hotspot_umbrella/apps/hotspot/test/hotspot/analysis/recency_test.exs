defmodule Hotspot.Analysis.RecencyTest do
  @moduledoc """
  Pure unit tests for the recency decay and per-file scoring. No db: every value
  is passed explicitly so results are deterministic.
  """
  use ExUnit.Case, async: true

  alias Hotspot.Analysis.Recency

  @day 86_400
  @half_life 90 * @day

  describe "weight/3" do
    test "is 1.0 at now and 0.5 exactly one half-life ago" do
      now = 1_000_000_000
      assert Recency.weight(now, now, @half_life) == 1.0
      assert_in_delta Recency.weight(now - @half_life, now, @half_life), 0.5, 1.0e-9
      assert_in_delta Recency.weight(now - 2 * @half_life, now, @half_life), 0.25, 1.0e-9
    end

    test "clamps future timestamps (clock skew) to 1.0" do
      now = 1_000_000_000
      assert Recency.weight(now + @day, now, @half_life) == 1.0
    end
  end

  describe "metrics_for/2" do
    test "recency_churn down-weights old churn so a recent file outranks an equal-churn old one" do
      now = 1_000_000_000
      opts = [now: now, half_life: @half_life]

      recent = [%{churn: 100, author: "a@x", committed_at: now}]
      old = [%{churn: 100, author: "a@x", committed_at: now - 5 * @half_life}]

      assert Recency.metrics_for(recent, opts).churn == Recency.metrics_for(old, opts).churn

      assert Recency.metrics_for(recent, opts).recency_churn >
               Recency.metrics_for(old, opts).recency_churn
    end

    test "last_changed is the max committed_at; author_count is distinct" do
      now = 1_000_000_000

      rows = [
        %{churn: 3, author: "a@x", committed_at: now - 10 * @day, sha: "a"},
        %{churn: 4, author: "b@x", committed_at: now - 2 * @day, sha: "b"},
        %{churn: 1, author: "a@x", committed_at: now - 30 * @day, sha: "c"}
      ]

      m = Recency.metrics_for(rows, now: now, half_life: @half_life)
      assert m.churn == 8
      assert m.author_count == 2
      assert m.last_changed == now - 2 * @day
      assert m.first_changed == now - 30 * @day
    end

    test "revisions counts distinct commit shas, not change rows" do
      now = 1_000_000_000

      rows = [
        %{churn: 3, author: "a@x", committed_at: now, sha: "a"},
        %{churn: 4, author: "b@x", committed_at: now, sha: "a"},
        %{churn: 1, author: "a@x", committed_at: now, sha: "b"}
      ]

      assert Recency.metrics_for(rows, now: now, half_life: @half_life).revisions == 2
    end

    test "trend is :rising when recent churn beats the prior window" do
      now = 1_000_000_000
      opts = [now: now, half_life: @half_life]

      rising = [
        %{churn: 1, author: "a@x", committed_at: now - 100 * @day, sha: "a"},
        %{churn: 50, author: "a@x", committed_at: now - 1 * @day, sha: "b"}
      ]

      cooling = [
        %{churn: 50, author: "a@x", committed_at: now - 100 * @day, sha: "a"},
        %{churn: 1, author: "a@x", committed_at: now - 1 * @day, sha: "b"}
      ]

      assert Recency.metrics_for(rising, opts).trend == :rising
      assert Recency.metrics_for(cooling, opts).trend == :cooling
    end

    test "trend is :stable for a dormant file (no churn in either window)" do
      now = 1_000_000_000
      rows = [%{churn: 9, author: "a@x", committed_at: now - 10 * @half_life, sha: "a"}]
      assert Recency.metrics_for(rows, now: now, half_life: @half_life).trend == :stable
    end
  end
end
