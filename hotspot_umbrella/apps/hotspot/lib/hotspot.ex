defmodule Hotspot do
  @moduledoc """
  Root namespace for the analytics app. There is no logic here.

  The public read surface is `Hotspot.Analysis`; storage lifecycle (which
  runner-produced `.db` is open) is `Hotspot.Storage`.
  """
end
