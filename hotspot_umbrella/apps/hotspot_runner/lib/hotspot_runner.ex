defmodule HotspotRunner do
  @moduledoc """
  Extracts a repo's `git log` history into a per-repo SQLite database for the
  read-only `Hotspot` app to query. The only component that touches git's output
  or writes the schema; `Hotspot` only reads.

  Entry points:

    * `HotspotRunner.Extractor.extract/2`: synchronous, used by `mix hotspot.extract`.
    * `HotspotRunner.Job.start/2`: background, broadcasts progress on `Hotspot.PubSub`.
  """
end
