defmodule HotspotRunner.Xray do
  @moduledoc """
  On-demand "X-Ray" of a single file: drill past the file-level hotspot into the
  **changed regions** inside it. Returns, from one `git log -p` pass, everything
  the file-focused view needs:

    * `regions`: per-region metrics (churn, authors, recency, last-changed,
      commit list) ranked by churn, each with a `heat` series (churn per time
      bucket) and `top_author`/`top_author_share` for ownership;
    * `buckets`: the shared time axis the `heat` series align to;
    * `cohesion`: behavioral cohesion of the file (how scattered changes are
      across regions);
    * `span`: first/last commit times.

  Computed live from git. Nothing is stored. A "region" is the git diff section
  heading of each changed hunk (see `HotspotRunner.XrayParser`): accurate for
  languages git has a funcname driver for, an approximate nearest-definition line
  otherwise, and an `(unattributed)` bucket when git emits no heading.

  Per-region scalars reuse `Hotspot.Analysis.Recency.metrics_for/2` so an X-Ray
  row means exactly what a file row means.
  """

  alias HotspotRunner.{Blame, Git, XrayParser}
  alias Hotspot.Analysis.Recency

  # Columns in the region×time heatmap. Equal-width spans over [first, last].
  @bucket_count 16

  # Cap blamed lines shipped to the client (bounds the websocket payload).
  @source_line_cap 4000

  @type commit :: %{sha: String.t(), author: String.t(), committed_at: integer, churn: number}

  @type region :: %{
          name: String.t(),
          churn: number,
          author_count: non_neg_integer,
          recency_churn: non_neg_integer,
          last_changed: integer,
          commit_count: non_neg_integer,
          commits: [commit],
          heat: [number],
          top_author: String.t() | nil,
          top_author_share: float
        }

  @type history :: %{
          regions: [region],
          buckets: [%{label: String.t()}],
          cohesion: %{regions_per_commit: float, multi_region_ratio: float},
          span: %{first: integer, last: integer} | nil
        }

  @doc """
  Behavioral history of `path` in the repo at `repo_path`. `opts`: `:ref`
  (default `"HEAD"`); `:since` / `:until` (epoch bounds restricting the commits
  considered); `:now` / `:half_life` are forwarded to recency scoring (defaulted
  by `Recency`).
  """
  @spec file_history(String.t(), String.t(), keyword) :: {:ok, history} | {:error, String.t()}
  def file_history(repo_path, path, opts \\ []) do
    ref = Keyword.get(opts, :ref, "HEAD")
    since = Keyword.get(opts, :since)
    until = Keyword.get(opts, :until)

    case git().file_log(repo_path, ref, path, since, until) do
      {:ok, output} -> {:ok, output |> XrayParser.parse() |> analyze(opts)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Current source of `path` at `ref`, blamed per line: each line carries the
  commit that last touched it (sha, author, time, `summary` = change reason). The
  returned `lines` are capped (`total` is the true count) to bound payload size.
  """
  @spec file_source(String.t(), String.t(), keyword) ::
          {:ok, %{lines: [Blame.line()], total: non_neg_integer}} | {:error, String.t()}
  def file_source(repo_path, path, opts \\ []) do
    ref = Keyword.get(opts, :ref, "HEAD")

    case git().blame(repo_path, ref, path) do
      {:ok, output} ->
        lines = Blame.parse(output)
        {:ok, %{lines: Enum.take(lines, @source_line_cap), total: length(lines)}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Build the history struct from already-parsed events. Pure (no git)."
  @spec analyze([XrayParser.event()], keyword) :: history
  def analyze([], _opts) do
    %{
      regions: [],
      buckets: [],
      cohesion: %{regions_per_commit: 0.0, multi_region_ratio: 0.0},
      span: nil
    }
  end

  def analyze(events, opts) do
    span = span(events)
    bins = bins(span)

    regions =
      events
      |> Enum.group_by(& &1.function)
      |> Enum.map(fn {name, rows} -> region(name, rows, bins, opts) end)
      |> Enum.sort_by(& &1.churn, :desc)

    %{regions: regions, buckets: bucket_labels(bins), cohesion: cohesion(events), span: span}
  end

  defp region(name, rows, bins, opts) do
    commits = commits_for(rows)
    {top_author, top_share} = ownership(commits)

    rows
    |> Recency.metrics_for(opts)
    |> Map.merge(%{
      name: name,
      commit_count: length(commits),
      commits: commits,
      heat: heat(rows, bins),
      top_author: top_author,
      top_author_share: top_share
    })
  end

  # One entry per commit that touched the region, newest first, with the region's
  # churn within that commit (a commit may touch the region in several hunks).
  defp commits_for(rows) do
    rows
    |> Enum.group_by(& &1.sha)
    |> Enum.map(fn {sha, evs} ->
      %{
        sha: sha,
        author: hd(evs).author,
        committed_at: hd(evs).committed_at,
        churn: evs |> Enum.map(& &1.churn) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(& &1.committed_at, :desc)
  end

  # Ownership / bus-factor: the author with the most churn in this region and
  # their share of it. A high share on a churny region = knowledge concentration.
  defp ownership([]), do: {nil, 0.0}

  defp ownership(commits) do
    by_author =
      commits
      |> Enum.group_by(& &1.author, & &1.churn)
      |> Enum.map(fn {author, churns} -> {author, Enum.sum(churns)} end)

    total = by_author |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {author, churn} = Enum.max_by(by_author, &elem(&1, 1))
    {author, ratio(churn, total)}
  end

  # --- Time bucketing --------------------------------------------------------

  defp span(events) do
    ats = Enum.map(events, & &1.committed_at)
    %{first: Enum.min(ats), last: Enum.max(ats)}
  end

  # {first, width, n}: a zero-length span (single moment) collapses to one bucket.
  defp bins(%{first: f, last: l}) do
    case l - f do
      d when d <= 0 -> {f, 1.0, 1}
      d -> {f, d / @bucket_count, @bucket_count}
    end
  end

  defp bin_index(t, {f, width, n}), do: min(n - 1, trunc((t - f) / width))

  # Churn summed per bucket, as an n-length list aligned to `bucket_labels`.
  defp heat(rows, {_f, _w, n} = bins) do
    sums =
      Enum.reduce(rows, %{}, fn r, acc ->
        Map.update(acc, bin_index(r.committed_at, bins), r.churn, &(&1 + r.churn))
      end)

    Enum.map(0..(n - 1), &Map.get(sums, &1, 0))
  end

  defp bucket_labels({f, width, n}) do
    Enum.map(0..(n - 1), fn i -> %{label: month_label(round(f + i * width))} end)
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp month_label(epoch) do
    d = DateTime.from_unix!(epoch)
    "#{Enum.at(@months, d.month - 1)} '#{d.year |> rem(100) |> pad2()}"
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  # --- Cohesion --------------------------------------------------------------

  # Behavioral cohesion: how many distinct regions a typical commit touches. Many
  # regions per commit => changes are scattered (low cohesion / the file does too
  # much). `multi_region_ratio` is the share of commits touching more than one.
  defp cohesion(events) do
    per_commit =
      events
      |> Enum.group_by(& &1.sha)
      |> Map.values()
      |> Enum.map(fn evs -> evs |> Enum.map(& &1.function) |> Enum.uniq() |> length() end)

    n = length(per_commit)
    multi = Enum.count(per_commit, &(&1 > 1))

    %{
      regions_per_commit: ratio(Enum.sum(per_commit), n),
      multi_region_ratio: ratio(multi, n)
    }
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: Float.round(num / den, 2)

  defp git, do: Application.get_env(:hotspot_runner, :git, Git)
end
