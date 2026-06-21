defmodule HotspotRunner.Git do
  @moduledoc """
  Builds and runs the Git commands.

  The long `git log` is streamed through a `Port` (chunked binary output) so the
  whole history is never buffered in memory. The small metadata queries
  (`rev-parse`, `ls-tree`) use `System.cmd/3`.
  """

  # Leading NUL, then NUL-delimited SHA / author-epoch / name / email / parents.
  @pretty "format:%x00%H%x00%at%x00%aN%x00%aE%x00%P"
  @common ["-z", "--numstat", "-M", "--no-color", "--pretty=" <> @pretty]

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

  defp run(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{String.trim(out)}"
    end
  end
end
