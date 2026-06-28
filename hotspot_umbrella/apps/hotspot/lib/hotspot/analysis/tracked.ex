defmodule Hotspot.Analysis.Tracked do
  @moduledoc """
  The set of paths that exist at the extracted ref, backing the removed-file filter.
  The snapshot is trustworthy only when the runner pinned it to the same commit the
  history was extracted to, i.e. `meta('tracked_sha') == meta('last_sha')`. Older
  databases have no `tracked_file` table; `available?/0` returns false for them so
  callers fall back to unfiltered behavior.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Storage.{Meta, TrackedFile}

  @doc "Whether a current tracked-file snapshot exists for this db."
  @spec available?() :: boolean()
  def available? do
    meta =
      from(m in Meta, where: m.key in ["tracked_sha", "last_sha"], select: {m.key, m.value})
      |> repo().all()
      |> Map.new()

    case meta do
      %{"tracked_sha" => sha, "last_sha" => sha} when is_binary(sha) ->
        repo().exists?(TrackedFile)

      _ ->
        false
    end
  rescue
    # tracked_file (or the query) missing on an older db.
    _ -> false
  end

  @doc "MapSet of paths currently present at the extracted ref."
  @spec set() :: MapSet.t(String.t())
  def set do
    TrackedFile |> select([t], t.path) |> repo().all() |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  @doc """
  Keep only rows whose `:path` still exists at the extracted ref. Rows must already be
  rename-resolved, so a path equals the file's current HEAD name (deleted files drop;
  renamed files survive under their new name). A no-op when no snapshot is available.
  """
  @spec filter([%{path: String.t()}]) :: [%{path: String.t()}]
  def filter(rows) do
    if available?() do
      tracked = set()
      Enum.filter(rows, &MapSet.member?(tracked, &1.path))
    else
      rows
    end
  end

  defp repo, do: Application.get_env(:hotspot, :repo, Repo)
end
