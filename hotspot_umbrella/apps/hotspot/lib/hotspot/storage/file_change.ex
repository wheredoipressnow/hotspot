defmodule Hotspot.Storage.FileChange do
  @moduledoc """
  Read-only mirror of the runner's `file_change` table, one row per (commit, file
  touched). `added`/`deleted` are nil for binary files. No natural primary key.
  """
  use Ecto.Schema

  @primary_key false
  schema "file_change" do
    field(:commit_sha, :string)
    field(:path, :string)
    field(:added, :integer)
    field(:deleted, :integer)
  end
end
