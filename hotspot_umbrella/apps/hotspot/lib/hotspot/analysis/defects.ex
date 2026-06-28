defmodule Hotspot.Analysis.Defects do
  @moduledoc """
  Defect signals mined from commit subjects. A file that is repeatedly the target
  of bug fixes is a quality hotspot, independent of its raw churn.

  A commit counts as a fix when its subject names a fix or references an issue
  (`fix`, `bug`, `hotfix`, `patch`, `close/resolve`, or `#123`), and as a revert
  when the subject starts with "revert". Per file, `bug_fix_density` is fix commits
  over total commits and `revert_rate` is reverts over total commits.

  Needs commit subjects (`schema_version >= 2`, see
  `Hotspot.Analysis.subjects_available?/0`); older dbs have no subject to classify.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.{Renames, Tracked, Window}
  alias Hotspot.Storage.{Commit, FileChange}

  # "fix" only at a word boundary (so prefix/suffix/affix do not match), plus the
  # compound bug/hot-fix forms, common defect words, and bare issue references.
  @fix_re ~r/\b(?:bug|hot)?fix(?:e[sd])?\b|\bbugs?\b|\bdefects?\b|\bpatch(?:e[sd])?\b|\b(?:close|resolve)[sd]?\b|#\d+/i
  @revert_re ~r/^\s*revert\b/i

  @type entry :: %{
          path: String.t(),
          commits: non_neg_integer,
          fix_commits: non_neg_integer,
          reverts: non_neg_integer,
          bug_fix_density: float,
          revert_rate: float
        }

  @doc "Whether a commit subject reads as a bug fix or issue reference."
  @spec fix?(String.t() | nil) :: boolean
  def fix?(subject) when is_binary(subject), do: Regex.match?(@fix_re, subject)
  def fix?(_), do: false

  @doc "Whether a commit subject reads as a revert."
  @spec revert?(String.t() | nil) :: boolean
  def revert?(subject) when is_binary(subject), do: Regex.match?(@revert_re, subject)
  def revert?(_), do: false

  @doc """
  Per-file defect entries. Accepts the same `include_merges`, `include_removed`,
  and `path_filter` options as `Hotspot.Analysis.Hotspots.top/1`.
  """
  @spec summary(map) :: [entry]
  def summary(params \\ %{}) do
    params
    |> rows()
    |> Enum.group_by(& &1.path)
    |> Enum.map(fn {path, rows} -> entry(path, rows) end)
  end

  @doc "Map of `path => bug_fix_density`, for merging into a hotspots list."
  @spec density_map(map) :: %{String.t() => float}
  def density_map(params \\ %{}) do
    params |> summary() |> Map.new(&{&1.path, &1.bug_fix_density})
  end

  # One row per (file, commit): the subject classified once per commit.
  defp rows(params) do
    include_merges = Map.get(params, :include_merges, false)
    include_removed = Map.get(params, :include_removed, true)
    path_filter = Map.get(params, :path_filter)

    rows =
      from(f in FileChange,
        join: c in Commit,
        on: c.sha == f.commit_sha,
        where: not is_nil(f.added),
        distinct: true,
        select: %{path: f.path, sha: f.commit_sha, subject: c.subject}
      )
      |> maybe_exclude_merges(include_merges)
      |> Window.restrict(params)
      |> repo().all()

    rows
    |> fold_renames(include_removed)
    |> filter_path(path_filter)
  end

  defp maybe_exclude_merges(query, true), do: query
  defp maybe_exclude_merges(query, false), do: from([_f, c] in query, where: c.parent_count < 2)

  defp fold_renames(rows, true), do: rows

  defp fold_renames(rows, false) do
    rename = Renames.map()

    rows
    |> Enum.map(&%{&1 | path: Renames.resolve(rename, &1.path)})
    |> Tracked.filter()
  end

  defp filter_path(rows, prefix) when prefix in [nil, ""], do: rows
  defp filter_path(rows, prefix), do: Enum.filter(rows, &String.starts_with?(&1.path, prefix))

  defp entry(path, rows) do
    # Renames can map two original paths to one, so count distinct commits here.
    commits = rows |> Enum.map(& &1.sha) |> Enum.uniq() |> length()

    by_sha = Enum.uniq_by(rows, & &1.sha)
    fixes = Enum.count(by_sha, &fix?(&1.subject))
    reverts = Enum.count(by_sha, &revert?(&1.subject))

    %{
      path: path,
      commits: commits,
      fix_commits: fixes,
      reverts: reverts,
      bug_fix_density: ratio(fixes, commits),
      revert_rate: ratio(reverts, commits)
    }
  end

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, total), do: n / total

  defp repo, do: Application.get_env(:hotspot, :repo, Repo)
end
