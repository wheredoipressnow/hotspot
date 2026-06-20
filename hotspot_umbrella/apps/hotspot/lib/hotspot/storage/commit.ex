defmodule Hotspot.Storage.Commit do
  @moduledoc """
  Read-only mirror of the runner's `commit_info` table. The schema is owned by
  the git runner; this app never writes to it.
  """
  use Ecto.Schema

  @primary_key {:sha, :string, autogenerate: false}
  schema "commit_info" do
    field(:committed_at, :integer)
    field(:author_name, :string)
    field(:author_email, :string)
    field(:parent_count, :integer)
  end
end
