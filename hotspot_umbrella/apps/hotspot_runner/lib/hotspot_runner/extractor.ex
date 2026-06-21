defmodule HotspotRunner.Extractor do
  @moduledoc """
  Orchestrates extraction: resolve repo top-level + ref tip + db path, decide full
  vs incremental, stream `git log` output through `HotspotRunner.Parser` into
  `HotspotRunner.Writer` in batched transactions, pin `meta.last_sha`, and snapshot
  tracked files.
  """

  alias HotspotRunner.{DbPath, Git, Parser, TreeScan, Writer}

  # Commits per transaction.
  @batch_size 1000

  @type result :: %{
          db_path: String.t(),
          toplevel: String.t(),
          mode: :full | :incremental,
          commits_written: non_neg_integer(),
          tip_sha: String.t(),
          tracked_files: non_neg_integer()
        }

  @doc """
  Extract `ref`'s history into the repo's SQLite db. Options:

    * `:ref`: git ref to extract (default `"HEAD"`)
    * `:force`: ignore `last_sha` and re-extract the whole history (default `false`)
    * `:on_progress`: `fn commits_written -> _ end`, called after each batch
  """
  @spec extract(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def extract(repo_path, opts \\ []) do
    ref = Keyword.get(opts, :ref, "HEAD")
    force = Keyword.get(opts, :force, false)
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)

    toplevel = Git.toplevel(repo_path)
    tip = Git.tip_sha(toplevel, ref)
    db_path = DbPath.path(toplevel)

    writer = Writer.open(db_path)

    try do
      Writer.set_meta(writer, "repo_path", toplevel)
      Writer.set_meta(writer, "ref", ref)

      last = Writer.get_meta(writer, "last_sha")
      incremental = not force and not is_nil(last)

      args =
        if incremental,
          do: Git.incremental_log_args(ref, last),
          else: Git.full_log_args(ref)

      port = Git.open_log(toplevel, args)

      case consume(port, writer, on_progress) do
        {:ok, total} ->
          # Pin to the exact tip we extracted to, then snapshot tracked files
          # with their current size + indentation metrics.
          Writer.set_meta(writer, "last_sha", tip)
          tracked = TreeScan.scan(toplevel, tip)
          Writer.replace_tracked_files(writer, tracked, tip)

          {:ok,
           %{
             db_path: db_path,
             toplevel: toplevel,
             mode: if(incremental, do: :incremental, else: :full),
             commits_written: total,
             tip_sha: tip,
             tracked_files: length(tracked)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Writer.close(writer)
    end
  end

  @doc "Whether stored data is behind the ref's current tip."
  @spec stale?(String.t(), keyword()) :: boolean()
  def stale?(repo_path, opts \\ []) do
    ref = Keyword.get(opts, :ref, "HEAD")
    toplevel = Git.toplevel(repo_path)
    tip = Git.tip_sha(toplevel, ref)
    db_path = DbPath.path(toplevel)

    writer = Writer.open(db_path)

    try do
      Writer.get_meta(writer, "last_sha") != tip
    after
      Writer.close(writer)
    end
  end

  ## Internals

  # Stream the port's stdout through the parser, flushing batches to storage.
  defp consume(port, writer, on_progress) do
    loop(port, writer, Parser.new(), [], 0, on_progress)
  end

  defp loop(port, writer, parser, pending, total, on_progress) do
    receive do
      {^port, {:data, data}} ->
        {parser, commits} = Parser.push(parser, data)
        {pending, total} = flush(writer, pending ++ commits, total, false, on_progress)
        loop(port, writer, parser, pending, total, on_progress)

      {^port, {:exit_status, 0}} ->
        commits = Parser.finish(parser)
        {_pending, total} = flush(writer, pending ++ commits, total, true, on_progress)
        {:ok, total}

      {^port, {:exit_status, code}} ->
        {:error, {:git_exit, code}}
    end
  end

  # Write full batches; when `force`, also write the remainder.
  defp flush(writer, pending, total, force, on_progress) do
    if length(pending) >= @batch_size or (force and pending != []) do
      {batch, rest} = Enum.split(pending, @batch_size)
      Writer.write_batch(writer, batch)
      total = total + length(batch)
      on_progress.(total)
      flush(writer, rest, total, force, on_progress)
    else
      {pending, total}
    end
  end
end
