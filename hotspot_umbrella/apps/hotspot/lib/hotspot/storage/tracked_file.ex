defmodule Hotspot.Storage.TrackedFile do
  @moduledoc """
  Read-only mirror of the runner's `tracked_file` snapshot: the set of paths that
  exist at the extracted ref's tree, with each file's current size + indentation
  complexity. Backs the removed-file filter and the complexity axis; valid only
  when `meta('tracked_sha') == meta('last_sha')`. See `Hotspot.Analysis.Tracked`.

  `loc`, `indent_total`, and `indent_max` are `nil` for binary files.
  """
  use Ecto.Schema

  @primary_key {:path, :string, autogenerate: false}
  schema "tracked_file" do
    field(:loc, :integer)
    field(:indent_total, :integer)
    field(:indent_max, :integer)
  end
end
