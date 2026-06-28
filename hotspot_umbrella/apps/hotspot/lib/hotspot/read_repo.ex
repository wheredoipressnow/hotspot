defmodule Hotspot.ReadRepo do
  @callback all(Ecto.Queryable.t()) :: [term()]
  @callback one(Ecto.Queryable.t()) :: term() | nil
  @callback exists?(Ecto.Queryable.t()) :: boolean()
  @callback aggregate(Ecto.Queryable.t(), :count, atom()) :: term()
end
