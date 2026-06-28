defmodule Mix.Tasks.Hotspot.Extract do
  @shortdoc "Extract a git repo's history into its hotspot SQLite db"

  @moduledoc """
  Extract a repository's git history into its per-repo SQLite database (under
  `$XDG_DATA_HOME/hotspot`).

      mix hotspot.extract [REPO_PATH] [--ref REF] [--force]

    * `REPO_PATH`: path to the repo (default: current directory)
    * `--ref`: git ref to extract (default: `HEAD`)
    * `--force`: re-extract the whole history instead of incrementally

  Full on first run (or with `--force`); otherwise incremental over `last_sha..ref`.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv, switches: [ref: :string, force: :boolean])

    repo = List.first(args) || File.cwd!()
    ref = opts[:ref] || "HEAD"
    force = opts[:force] || false

    {:ok, _} = Application.ensure_all_started(:hotspot_runner)

    case HotspotRunner.Extractor.extract(repo, ref: ref, force: force) do
      {:ok, r} ->
        Mix.shell().info("""
        Extracted #{r.mode} #{repo} (#{r.tip_sha})
          db:        #{r.db_path}
          commits:   #{r.commits_written}
          tracked:   #{r.tracked_files}
        """)

      {:error, reason} ->
        Mix.raise("extraction failed: #{inspect(reason)}")
    end
  end
end
