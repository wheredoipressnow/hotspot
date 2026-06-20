defmodule Hotspot.Analysis.Renames do
  @moduledoc """
  Resolves `rename_edge` chains so a file that moved (`old_path` → `new_path`,
  possibly several hops) can be folded onto its terminal path. Used by the tree
  and top-hotspots aggregations when `include_removed: false` (HANDOFF §5 "follow
  renames"). A small cycle guard keeps pathological data from looping forever.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Storage.RenameEdge

  @type map_t :: %{optional(String.t()) => String.t()}

  @doc "old_path -> new_path map built from the `rename_edge` table."
  @spec map() :: map_t
  def map do
    RenameEdge
    |> select([r], {r.old_path, r.new_path})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Resolve `path` to the end of its rename chain using `map/0`'s result."
  @spec resolve(map_t, String.t()) :: String.t()
  def resolve(rename, path), do: resolve(rename, path, MapSet.new())

  defp resolve(rename, path, seen) do
    case Map.get(rename, path) do
      nil ->
        path

      ^path ->
        path

      next ->
        if MapSet.member?(seen, next),
          do: path,
          else: resolve(rename, next, MapSet.put(seen, path))
    end
  end
end
