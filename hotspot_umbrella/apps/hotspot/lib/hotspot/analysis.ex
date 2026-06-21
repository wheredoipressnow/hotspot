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
  Ranked hotspots enriched with bus-factor and abandoned-owner flags. See
  `Hotspot.Analysis.Ownership`. Returns `{:error, :no_database}` when no db is open.
  """
  def ownership(params \\ %{}) do
    with_database(fn -> Hotspot.Analysis.Ownership.summary(params) end)
  end

  @doc """
  Scatter points pairing each current file's change frequency with its complexity.
  See `Hotspot.Analysis.Complexity`. Returns `{:error, :no_database}` when no db is open.
  """
  def complexity_scatter(params \\ %{}) do
    with_database(fn -> Hotspot.Analysis.Complexity.scatter(params) end)
  end

  @doc """
  Complexity metrics for one current file, or `nil` when absent or binary. Returns
  `{:error, :no_database}` when no db is open.
  """
  def file_complexity(path) do
    with_database(fn -> Hotspot.Analysis.Complexity.for_path(path) end)
  end

  @doc """
  Per-file defect signals (bug-fix density, revert rate) mined from commit
  subjects. See `Hotspot.Analysis.Defects`. Returns `{:error, :no_database}` when
  no db is open.
  """
  def defects(params \\ %{}) do
    with_database(fn -> Hotspot.Analysis.Defects.summary(params) end)
  end

  @doc """
  Map of `path => bug_fix_density` for merging into a hotspots list. See
  `Hotspot.Analysis.Defects`. Returns `{:error, :no_database}` when no db is open.
  """
  def defect_density(params \\ %{}) do
    with_database(fn -> Hotspot.Analysis.Defects.density_map(params) end)
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
  Whether the open db captured commit subjects (`schema_version >= 2`), needed by
  the defect-signal features. `false` when no db is open or on an older db that
  predates the column, in which case those features stay hidden until re-extraction.
  """
  def subjects_available? do
    with_database(fn -> schema_version() >= 2 end) == true
  end

  @doc """
  Whether the open db carries per-file complexity metrics: `schema_version >= 2`
  and a current `tracked_file` snapshot. `false` when no db is open or on an older
  db, in which case the complexity axis stays hidden until re-extraction.
  """
  def complexity_available? do
    with_database(fn ->
      schema_version() >= 2 and Hotspot.Analysis.Tracked.available?()
    end) == true
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

  # Stored `meta('schema_version')` as an integer; 1 when absent (predates the key).
  defp schema_version do
    case Repo.one(from(m in Meta, where: m.key == "schema_version", select: m.value)) do
      nil -> 1
      value -> String.to_integer(value)
    end
  rescue
    _ -> 1
  end

  defp with_database(fun) do
    if Hotspot.Storage.loaded?(), do: fun.(), else: {:error, :no_database}
  end
end
