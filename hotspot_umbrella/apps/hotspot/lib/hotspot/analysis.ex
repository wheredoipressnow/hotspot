defmodule Hotspot.Analysis do
  @moduledoc """
  The single public surface of the analytics app. "What is a hotspot" lives here
  and nowhere else (HANDOFF §2): the web app calls this context only — never the
  Repo, schemas, or raw SQL directly.

  Currently a thin read path proving the read-only Ecto wiring; the four metrics
  and the change-coupling query land here next.

  No db is loaded at boot (see `Hotspot.Storage`). Every read here first checks
  that a db is open, returning `{:error, :no_database}` rather than crashing on a
  missing Repo pool.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Storage.{Commit, FileChange, Meta, RenameEdge}

  @doc """
  Nested directory tree for the circle-packing view. See `Hotspot.Analysis.Tree`.
  Returns `{:error, :no_database}` when no db is open.
  """
  def tree_for_visualization(params \\ %{}) do
    with_database(fn -> Hotspot.Analysis.Tree.tree_for_visualization(params) end)
  end

  @doc """
  Summary counts for the extracted repo — smoke test of the read path.
  Returns `{:error, :no_database}` when no db is open.
  """
  def repo_stats do
    with_database(fn ->
      %{
        commits: Repo.aggregate(Commit, :count, :sha),
        file_changes: Repo.aggregate(FileChange, :count, :path),
        renames: Repo.aggregate(RenameEdge, :count, :new_path),
        last_sha: Repo.one(from(m in Meta, where: m.key == "last_sha", select: m.value))
      }
    end)
  end

  defp with_database(fun) do
    if Hotspot.Storage.loaded?(), do: fun.(), else: {:error, :no_database}
  end
end
