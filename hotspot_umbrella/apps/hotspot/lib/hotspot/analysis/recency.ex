defmodule Hotspot.Analysis.Recency do
  @moduledoc """
  Recency scoring shared by the tree and top-hotspots aggregations. The decay
  formula and its half-life knob live here and nowhere else.

  Callers pull per-change rows carrying `committed_at` and reduce them to per-file
  metrics with `metrics_for/2`.

  ## Half-life

  A commit's churn is weighted by `0.5 ^ (age / half_life)`: a change exactly one
  half-life old counts half as much as one made now, two half-lives a quarter,
  and so on. The half-life defaults to 90 days and is tunable via

      config :hotspot, recency_half_life_days: 90
  """

  @default_half_life_days 90
  @seconds_per_day 86_400

  @type change_row :: %{churn: number, author: String.t(), committed_at: integer}

  @doc "Half-life in seconds, from `:hotspot, :recency_half_life_days` (default 90 days)."
  @spec half_life_seconds() :: pos_integer
  def half_life_seconds do
    days = Application.get_env(:hotspot, :recency_half_life_days, @default_half_life_days)
    days * @seconds_per_day
  end

  @doc "Reference \"now\" used for ages, as a unix epoch in seconds."
  @spec now() :: integer
  def now, do: System.os_time(:second)

  @doc """
  Exponential decay weight for a commit at `committed_at` relative to `now`, with
  the given `half_life` (all unix-epoch seconds). `1.0` at `now`, `0.5` one
  half-life ago. Future timestamps (clock skew) are clamped to weight `1.0`.
  """
  @spec weight(integer, integer, pos_integer) :: float
  def weight(committed_at, now, half_life) do
    age = max(now - committed_at, 0)
    :math.pow(0.5, age / half_life)
  end

  @doc """
  Reduce per-change rows for one logical file to its metric map. Rows are
  `%{churn, author, committed_at}`. `now` and `half_life` default to `now/0` and
  `half_life_seconds/0`; callers pass them explicitly to keep results
  deterministic (e.g. in tests).
  """
  @spec metrics_for([change_row], keyword) :: %{
          churn: number,
          author_count: non_neg_integer,
          recency_churn: non_neg_integer,
          last_changed: integer
        }
  def metrics_for(rows, opts \\ []) do
    now = Keyword.get(opts, :now, now())
    half_life = Keyword.get(opts, :half_life, half_life_seconds())

    %{
      churn: rows |> Enum.map(& &1.churn) |> Enum.sum(),
      author_count: rows |> Enum.map(& &1.author) |> Enum.uniq() |> length(),
      recency_churn:
        rows
        |> Enum.map(fn r -> r.churn * weight(r.committed_at, now, half_life) end)
        |> Enum.sum()
        |> round(),
      last_changed: rows |> Enum.map(& &1.committed_at) |> Enum.max()
    }
  end
end
