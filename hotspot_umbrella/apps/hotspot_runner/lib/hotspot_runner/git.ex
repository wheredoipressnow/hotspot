defmodule HotspotRunner.Git do
  @moduledoc """
  Builds and runs the Git commands.

  The long `git log` is streamed through a `Port` (chunked binary output) so the
  whole history is never buffered in memory. The small metadata queries
  (`rev-parse`, `ls-tree`) use `System.cmd/3`.
  """

  # Leading NUL, then NUL-delimited SHA / author-epoch / name / email / parents /
  # subject. Subject is the last header field (single line, no NUL of its own).
  @pretty "format:%x00%H%x00%at%x00%aN%x00%aE%x00%P%x00%s"
  @common ["-z", "--numstat", "-M", "--no-color", "--pretty=" <> @pretty]

  # X-Ray single-file log: RS-prefixed header, US-delimited fields. RS (0x1e) /
  # US (0x1f) are control bytes that can't appear in patch text, so commit
  # headers stay unambiguous against the interleaved `git log -p` output.
  @xray_pretty "format:%x1e%H%x1f%at%x1f%aN%x1f%aE%x1f%P"

  @doc "Resolve the repository top-level dir (so a subdir invocation maps to one db)."
  @spec toplevel(String.t()) :: String.t()
  def toplevel(cwd) do
    cwd |> run(["rev-parse", "--show-toplevel"]) |> String.trim()
  end

  @doc "Current tip SHA of a ref (for staleness checks)."
  @spec tip_sha(String.t(), String.t()) :: String.t()
  def tip_sha(cwd, ref) do
    cwd |> run(["rev-parse", "--verify", "#{ref}^{commit}"]) |> String.trim()
  end

  @doc "Files tracked at `ref`, via `git ls-tree`."
  @spec tracked_files(String.t(), String.t()) :: [String.t()]
  def tracked_files(cwd, ref) do
    cwd
    |> run(["-c", "core.quotePath=false", "ls-tree", "-r", "--name-only", "-z", ref])
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Args for a full-history extraction: oldest->newest (`--reverse`) so
  `meta.last_sha` advances monotonically and an interrupted run can resume.
  `diff.renameLimit=0` (unlimited) so large reorg commits never silently drop
  renames.
  """
  @spec full_log_args(String.t()) :: [String.t()]
  def full_log_args(ref) do
    ["-c", "diff.renameLimit=0", "-c", "core.quotePath=false", "log", ref, "--reverse"] ++ @common
  end

  @doc "Args for an incremental extraction over `last_sha..ref` (newest-first, small range)."
  @spec incremental_log_args(String.t(), String.t()) :: [String.t()]
  def incremental_log_args(ref, last_sha) do
    ["-c", "core.quotePath=false", "log", "#{last_sha}..#{ref}"] ++ @common
  end

  @doc """
  Open a streaming `git log` Port in `cwd`. Emits `{port, {:data, binary}}` and a
  final `{port, {:exit_status, code}}`.
  """
  @spec open_log(String.t(), [String.t()]) :: port()
  def open_log(cwd, args) do
    git = System.find_executable("git") || raise "git executable not found on PATH"

    Port.open(
      {:spawn_executable, git},
      [:binary, :exit_status, :use_stdio, {:args, args}, {:cd, to_charlist(cwd)}]
    )
  end

  @doc "Blob `{sha, path}` pairs tracked at `ref` (skips trees and submodules)."
  @spec tree_blobs(String.t(), String.t()) :: [{String.t(), String.t()}]
  def tree_blobs(cwd, ref) do
    cwd
    |> run(["-c", "core.quotePath=false", "ls-tree", "-r", "-z", ref])
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn entry ->
      with [meta, path] <- String.split(entry, "\t", parts: 2),
           [_mode, "blob", sha] <- String.split(meta, " ") do
        [{sha, path}]
      else
        _ -> []
      end
    end)
  end

  @doc """
  Read the given blob `shas` via one `git cat-file --batch` process, returning a
  `%{sha => content}` map. Buffers the whole tree's content (a single snapshot,
  not history), so it is for HEAD-tree scans, not the streaming history path.
  """
  @spec read_blobs(String.t(), [String.t()]) :: %{String.t() => binary}
  def read_blobs(_cwd, []), do: %{}

  def read_blobs(cwd, shas) do
    git = System.find_executable("git") || raise "git executable not found on PATH"

    port =
      Port.open(
        {:spawn_executable, git},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:args, ["cat-file", "--batch"]},
          {:cd, to_charlist(cwd)}
        ]
      )

    Port.command(port, Enum.map_join(shas, "", &(&1 <> "\n")))
    blobs = collect_blobs(port, length(shas), <<>>, %{})
    Port.close(port)
    blobs
  end

  # Parse the `--batch` stream: "<oid> <type> <size>\n<content>\n" per object.
  defp collect_blobs(_port, 0, _buf, acc), do: acc

  defp collect_blobs(port, remaining, buf, acc) do
    case parse_blob(buf) do
      {:ok, sha, content, rest} ->
        collect_blobs(port, remaining - 1, rest, Map.put(acc, sha, content))

      :more ->
        receive do
          {^port, {:data, data}} -> collect_blobs(port, remaining, buf <> data, acc)
          {^port, {:exit_status, _}} -> acc
        end
    end
  end

  defp parse_blob(buf) do
    case :binary.split(buf, "\n") do
      [header, rest] ->
        case String.split(header, " ") do
          [sha, _type, size] ->
            size = String.to_integer(size)
            # content (size bytes) + trailing newline
            if byte_size(rest) >= size + 1 do
              <<content::binary-size(^size), _nl::binary-size(1), tail::binary>> = rest
              {:ok, sha, content, tail}
            else
              :more
            end

          _ ->
            :more
        end

      [_] ->
        :more
    end
  end

  @doc """
  Args for the X-Ray single-file patch log: full history of one `path`,
  following renames (`--follow -M`), with zero-context patches (`-p
  --unified=0`). Each hunk header keeps its section heading (the enclosing
  region, computed by git's diff drivers at that revision), which the parser
  attributes churn to. Counts come from the `@@` ranges, not the body.
  """
  @spec file_log_args(String.t(), String.t()) :: [String.t()]
  def file_log_args(ref, path) do
    [
      "-c",
      "core.quotePath=false",
      # Low-priority driver map so hunk headings track real definitions where git
      # has a built-in driver; a target repo's own .gitattributes still overrides.
      "-c",
      "core.attributesFile=" <> attrs_path(),
      "log",
      ref,
      "--follow",
      "-M",
      "--no-color",
      "-p",
      "--unified=0",
      "--pretty=" <> @xray_pretty,
      "--",
      path
    ]
  end

  @doc """
  Run the X-Ray single-file patch log in `cwd`, returning raw stdout. A single
  file's history is small enough to buffer (unlike full extraction), so this
  uses `System.cmd`. stderr is kept separate so it never corrupts the patch
  stream.
  """
  @spec file_log(String.t(), String.t(), String.t()) :: {:ok, binary} | {:error, String.t()}
  def file_log(cwd, ref, path) do
    case System.cmd("git", file_log_args(ref, path), cd: cwd, stderr_to_stdout: false) do
      {out, 0} -> {:ok, out}
      {_out, code} -> {:error, "git log -p for #{path} failed (#{code})"}
    end
  end

  @doc """
  Args for a per-line blame of `path` at `ref`. `--line-porcelain` repeats the
  full commit info (incl. `summary`, the change reason) on every line, so each
  line is self-describing and easy to parse.
  """
  @spec blame_args(String.t(), String.t()) :: [String.t()]
  def blame_args(ref, path) do
    ["-c", "core.quotePath=false", "blame", "--line-porcelain", ref, "--", path]
  end

  @doc """
  Run `git blame --line-porcelain` in `cwd`, returning raw stdout. stderr is kept
  separate so a failure (binary file, path absent at `ref`) doesn't corrupt the
  output.
  """
  @spec blame(String.t(), String.t(), String.t()) :: {:ok, binary} | {:error, String.t()}
  def blame(cwd, ref, path) do
    case System.cmd("git", blame_args(ref, path), cd: cwd, stderr_to_stdout: false) do
      {out, 0} -> {:ok, out}
      {_out, code} -> {:error, "git blame for #{path} failed (#{code})"}
    end
  end

  # Bundled extension->driver map shipped in priv (see priv/xray.gitattributes).
  defp attrs_path, do: Application.app_dir(:hotspot_runner, "priv/xray.gitattributes")

  defp run(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{String.trim(out)}"
    end
  end
end
