defmodule Hotspot.Storage.TrackedFile do
  @moduledoc """
  Read-only mirror of the runner's `tracked_file` snapshot: the set of paths that
  exist at the extracted ref's tree. Backs the removed-file filter; valid only when
  `meta('tracked_sha') == meta('last_sha')`. See `Hotspot.Analysis.Tracked`.
  """
  use Ecto.Schema

  @primary_key {:path, :string, autogenerate: false}
  schema "tracked_file" do
  end
end
