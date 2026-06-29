defmodule HotspotWeb.HotspotLive.Format do
  @moduledoc """
  Shared label formatting for the hotspot views.
  """

  @doc ~S'Compact "time ago" label for an epoch second, e.g. "3d", "5mo", "2y". Returns "—" for a missing or non-positive time.'
  def relative_age(epoch) when is_integer(epoch) and epoch > 0 do
    days = div(System.os_time(:second) - epoch, 86_400)

    cond do
      days <= 0 -> "today"
      days < 30 -> "#{days}d"
      days < 365 -> "#{div(days, 30)}mo"
      true -> "#{div(days, 365)}y"
    end
  end

  def relative_age(_), do: "—"

  @doc ~S'Local part of an author email for a compact label. Returns "?" for a missing author.'
  def author_label(email) when is_binary(email), do: email |> String.split("@") |> hd()
  def author_label(_), do: "?"
end
