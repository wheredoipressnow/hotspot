defmodule Hotspot.Storage.RenameEdge do
  @moduledoc """
  Read-only mirror of the runner's `rename_edge` table. Each row says
  `new_path` continues `old_path` at a commit. `similarity` may be nil.
  """
  use Ecto.Schema

  @primary_key false
  schema "rename_edge" do
    field(:commit_sha, :string)
    field(:old_path, :string)
    field(:new_path, :string)
    field(:similarity, :integer)
  end
end
