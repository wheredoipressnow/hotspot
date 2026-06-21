defmodule Hotspot.Analysis.Coupling do
  @moduledoc """
  Temporal (logical) coupling: the files that most often change in the same
  commits as a given file. High co-change means the two are coupled in practice
  even with no direct code reference: a hidden dependency or a refactoring smell.

  For non-merge commits only:

      coupling = shared_commits / commits_touching(path)

  i.e. "when `path` changes, how often does the other file change too". Renames
  are not folded in this first cut, so a file's pre-rename path counts separately.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Storage.{Commit, FileChange}

  @type coupled :: %{path: String.t(), shared_commits: non_neg_integer, coupling: float}

  @doc """
  Top files co-changing with `path`, by coupling ratio (desc). `opts`: `:limit`
  (default 15), `:min_shared` (default 2, drops one-off co-changes as noise).
  """
  @spec top(String.t(), keyword) :: [coupled]
  def top(path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 15)
    min_shared = Keyword.get(opts, :min_shared, 2)

    # Distinct non-merge commits that touched `path`.
    shas =
      from(f in FileChange,
        join: c in Commit,
        on: c.sha == f.commit_sha,
        where: f.path == ^path and c.parent_count < 2,
        distinct: true,
        select: f.commit_sha
      )

    denom = Repo.one(from(s in subquery(shas), select: count()))

    if denom in [nil, 0] do
      []
    else
      from(f in FileChange,
        where: f.commit_sha in subquery(shas) and f.path != ^path,
        group_by: f.path,
        select: %{path: f.path, shared_commits: count(f.commit_sha, :distinct)}
      )
      |> Repo.all()
      |> Enum.filter(&(&1.shared_commits >= min_shared))
      |> Enum.map(&Map.put(&1, :coupling, Float.round(&1.shared_commits / denom, 2)))
      |> Enum.sort_by(&{&1.coupling, &1.shared_commits}, :desc)
      |> Enum.take(limit)
    end
  end
end
