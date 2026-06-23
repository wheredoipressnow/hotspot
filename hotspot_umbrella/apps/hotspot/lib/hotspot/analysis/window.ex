defmodule Hotspot.Analysis.Window do
  @moduledoc """
  Shared time-window filter for the history queries. A window is an inclusive
  `committed_at` range, either bound of which may be `nil` (open-ended). It lets
  callers consider only commits within a chosen range while leaving the
  snapshot-derived metrics (current size, indentation) untouched.

  Callers pass `:since` and/or `:until` (epoch seconds) in their params map. The
  query builders below add the bounds to a `FileChange`/`Commit` query where the
  commit is the second binding (`from([file_change, commit] in ...)`).
  """
  import Ecto.Query

  @doc "The `{since, until}` epoch bounds from a params map (both default `nil`)."
  @spec bounds(map) :: {integer | nil, integer | nil}
  def bounds(params), do: {Map.get(params, :since), Map.get(params, :until)}

  @doc """
  Restrict `query` to commits within `[since, until]`. A `nil` bound is omitted,
  so `restrict(q, nil, nil)` returns `q` unchanged. The commit must be the second
  binding in `query`.
  """
  @spec restrict(Ecto.Query.t(), integer | nil, integer | nil) :: Ecto.Query.t()
  def restrict(query, since, until) do
    query
    |> maybe_since(since)
    |> maybe_until(until)
  end

  @doc "Convenience: `restrict/3` reading the bounds from a params map."
  @spec restrict(Ecto.Query.t(), map) :: Ecto.Query.t()
  def restrict(query, params) when is_map(params) do
    {since, until} = bounds(params)
    restrict(query, since, until)
  end

  defp maybe_since(query, nil), do: query
  defp maybe_since(query, since), do: from([_f, c] in query, where: c.committed_at >= ^since)

  defp maybe_until(query, nil), do: query
  defp maybe_until(query, until), do: from([_f, c] in query, where: c.committed_at <= ^until)
end
