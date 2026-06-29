defmodule HotspotWeb.HotspotLive.TimeRange do
  @moduledoc """
  Stored analysis windows for the top-bar time-range control.

  A range is either a preset atom (`:all`, `:y1`, `:m6`, `:m3`, `:m1`) or a
  `{:custom, from, until}` tuple of inclusive epoch bounds, where `nil` is an open end.
  """

  @time_presets [
    {"All time", "all"},
    {"Last 12 months", "y1"},
    {"Last 6 months", "m6"},
    {"Last 3 months", "m3"},
    {"Last 30 days", "m1"}
  ]
  @seconds_per_day 86_400

  @doc "Preset `{label, value}` options for the control. `custom` is added by the control."
  def presets, do: @time_presets

  @doc "Range resolved to `:since`/`:until` query params."
  def window(time_range) do
    {since, until} = bounds(time_range)
    %{since: since, until: until}
  end

  @doc "Inclusive `{since, until}` epoch bounds for a range; `nil` is open."
  def bounds(:all), do: {nil, nil}
  def bounds(:y1), do: {days_ago(365), nil}
  def bounds(:m6), do: {days_ago(182), nil}
  def bounds(:m3), do: {days_ago(91), nil}
  def bounds(:m1), do: {days_ago(30), nil}
  def bounds({:custom, from, until}), do: {from, until}
  def bounds(_), do: {nil, nil}

  defp days_ago(n), do: System.os_time(:second) - n * @seconds_per_day

  @doc """
  Parses the control's form params into a stored range. `custom` carries from/to
  dates as start-of-day and end-of-day UTC; blank dates stay open-ended.
  """
  def parse(%{"preset" => "custom"} = params) do
    {:custom, parse_date(params["from"], :start), parse_date(params["to"], :end)}
  end

  def parse(%{"preset" => preset}), do: preset_atom(preset)
  def parse(_), do: :all

  defp preset_atom("y1"), do: :y1
  defp preset_atom("m6"), do: :m6
  defp preset_atom("m3"), do: :m3
  defp preset_atom("m1"), do: :m1
  defp preset_atom(_), do: :all

  defp parse_date(date, _edge) when date in [nil, ""], do: nil

  defp parse_date(date, edge) do
    case Date.from_iso8601(date) do
      {:ok, d} ->
        time = if edge == :end, do: ~T[23:59:59], else: ~T[00:00:00]
        d |> DateTime.new!(time, "Etc/UTC") |> DateTime.to_unix()

      _ ->
        nil
    end
  end

  @doc "The select option value for a range; `{:custom, ...}` becomes `\"custom\"`."
  def key({:custom, _, _}), do: "custom"
  def key(range), do: to_string(range)

  @doc "The `{from, to}` date strings to pre-fill the custom inputs, else blanks."
  def custom_dates({:custom, from, until}), do: {date_str(from), date_str(until)}
  def custom_dates(_), do: {"", ""}

  defp date_str(nil), do: ""

  defp date_str(epoch),
    do: epoch |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()
end
