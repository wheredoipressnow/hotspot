defmodule Hotspot.Storage.Meta do
  @moduledoc "Read-only mirror of the runner's `meta` bookkeeping table."
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "meta" do
    field(:value, :string)
  end
end
