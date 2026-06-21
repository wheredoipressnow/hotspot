defmodule Hotspot.Analysis.Ownership do
  @moduledoc """
  Knowledge-map forensics on top of the per-file ownership share computed by
  `Hotspot.Analysis.Recency`. Flags two risks: a bus factor (one author owns most
  of a file's churn, so the knowledge sits with one person) and abandonment (that
  owner has not committed anywhere in the repo for a long time, so the knowledge
  has likely left the team).

  `summary/1` returns the ranked hotspots (see `Hotspot.Analysis.Hotspots`) with
  `bus_factor?` and `abandoned?` flags added. Thresholds are tunable via

      config :hotspot, ownership_bus_factor_share: 0.6
      config :hotspot, ownership_abandoned_days: 365
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.{Hotspots, Recency}
  alias Hotspot.Storage.Commit

  @default_bus_factor_share 0.6
  @default_abandoned_days 365
  @seconds_per_day 86_400

  @doc """
  Ranked hotspots enriched with `bus_factor?` and `abandoned?`. Takes the same
  params as `Hotspot.Analysis.Hotspots.top/1`.
  """
  @spec summary(map) :: [map]
  def summary(params \\ %{}) do
    activity = last_activity()
    now = Recency.now()
    abandoned_cutoff = now - abandoned_days() * @seconds_per_day
    share = bus_factor_share()

    params
    |> Hotspots.top()
    |> Enum.map(fn h ->
      h
      |> Map.put(:bus_factor?, bus_factor?(h, share))
      |> Map.put(:abandoned?, abandoned?(h, activity, abandoned_cutoff))
    end)
  end

  @doc "Map of `author_email => most recent commit time` across the whole repo."
  @spec last_activity() :: %{String.t() => integer}
  def last_activity do
    from(c in Commit,
      group_by: c.author_email,
      select: {c.author_email, max(c.committed_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Whether one author owns at least `share` of the file's churn (knowledge concentration)."
  @spec bus_factor?(map, float) :: boolean
  def bus_factor?(%{ownership: ownership, author_count: count}, share) do
    ownership >= share and count > 1
  end

  @doc """
  Whether the file's main author has not committed anywhere since `cutoff` (their
  knowledge has likely left the team). `false` when there is no main author.
  """
  @spec abandoned?(map, %{String.t() => integer}, integer) :: boolean
  def abandoned?(%{main_author: nil}, _activity, _cutoff), do: false

  def abandoned?(%{main_author: author}, activity, cutoff) do
    case Map.get(activity, author) do
      nil -> false
      last -> last < cutoff
    end
  end

  defp bus_factor_share,
    do: Application.get_env(:hotspot, :ownership_bus_factor_share, @default_bus_factor_share)

  defp abandoned_days,
    do: Application.get_env(:hotspot, :ownership_abandoned_days, @default_abandoned_days)
end
