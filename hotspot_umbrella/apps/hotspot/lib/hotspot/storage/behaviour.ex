defmodule Hotspot.Storage.Behaviour do
  @callback loaded?() :: boolean()
  @callback current() :: String.t() | nil
  @callback list() :: [%{name: String.t(), path: String.t(), size: non_neg_integer()}]
  @callback open(path :: String.t()) :: :ok | {:error, term()}
  @callback close() :: :ok
  @callback topic() :: String.t()
end
