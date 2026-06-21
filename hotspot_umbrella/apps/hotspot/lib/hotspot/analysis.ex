defmodule Hotspot.Analysis do
  @moduledoc """
  The single public surface of the analytics app. The definition of a hotspot
  lives here and nowhere else: the web app calls this context only, never the
  Repo, schemas, or raw SQL directly.

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
  Ranked top hotspots for the overview list. See `Hotspot.Analysis.Hotspots`.
  Returns `{:error, :no_database}` when no db is open.
  """
  def top_hotspots(params \\ %{}) do
    with_database(fn -> Hotspot.Analysis.Hotspots.top(params) end)
  end

  @doc """
  Files that most often change together with `path` (temporal coupling). See
  `Hotspot.Analysis.Coupling`. Returns `{:error, :no_database}` when no db is open.
  """
  def coupling(path, opts \\ []) do
    with_database(fn -> Hotspot.Analysis.Coupling.top(path, opts) end)
  end

  @doc """
  Recursively-expanded coupling graph rooted at `path` for the force-directed
  ("cloud") view. See `Hotspot.Analysis.Coupling.graph/2`. Returns
  `{:error, :no_database}` when no db is open.
  """
  def coupling_graph(path, opts \\ []) do
    with_database(fn -> Hotspot.Analysis.Coupling.graph(path, opts) end)
  end

  @doc """
  Whether the open db can exclude removed (deleted) files, i.e. whether it carries a
  current `tracked_file` snapshot. `false` when no db is open or on an older db without
  that snapshot, in which case `include_removed: false` only folds renames.
  """
  def removed_filter_available? do
    with_database(&Hotspot.Analysis.Tracked.available?/0) == true
  end

  @doc """
  Absolute path of the repo the open db was extracted from (`meta.repo_path`),
  needed by the live file X-Ray which queries git directly. Returns `nil` when
  unset, `{:error, :no_database}` when no db is open.
  """
  def repo_path do
    with_database(fn ->
      Repo.one(from(m in Meta, where: m.key == "repo_path", select: m.value))
    end)
  end

  @doc """
  Summary counts for the extracted repo.
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
