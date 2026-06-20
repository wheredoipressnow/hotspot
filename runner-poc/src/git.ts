import { type ChildProcessByStdio, execFileSync, spawn } from "node:child_process";
import type { Readable } from "node:stream";

/** What `spawn` returns with stdin ignored and stdout/stderr piped. */
export type GitLogProcess = ChildProcessByStdio<null, Readable, Readable>;

// The pretty format: leading NUL, then NUL-delimited SHA / author-epoch / name / email / parents.
const PRETTY = "format:%x00%H%x00%at%x00%aN%x00%aE%x00%P";

const COMMON = ["-z", "--numstat", "-M", "--no-color", `--pretty=${PRETTY}`];

/** Resolve the repository top-level directory (so subdir invocation maps to one db). */
export function revParseToplevel(cwd: string): string {
  return run(cwd, ["rev-parse", "--show-toplevel"]).trim();
}

/** Current tip SHA of a ref (for staleness checks). */
export function revParse(cwd: string, ref: string): string {
  return run(cwd, ["rev-parse", "--verify", `${ref}^{commit}`]).trim();
}

/**
 * Spawn a full-history extraction: oldest->newest (`--reverse`) so meta.last_sha
 * advances monotonically and an interrupted run can safely resume. Rename detection
 * limit is unlimited so large reorg commits never silently drop renames.
 */
export function spawnFullLog(cwd: string, ref: string): GitLogProcess {
  return spawnGit(cwd, [
    "-c",
    "diff.renameLimit=0",
    "-c",
    "core.quotePath=false",
    "log",
    ref,
    "--reverse",
    ...COMMON,
  ]);
}

/** Spawn an incremental extraction over `last_sha..ref` (newest-first; small range). */
export function spawnIncrementalLog(
  cwd: string,
  lastSha: string,
  ref: string,
): GitLogProcess {
  return spawnGit(cwd, ["-c", "core.quotePath=false", "log", `${lastSha}..${ref}`, ...COMMON]);
}

function spawnGit(cwd: string, args: string[]): GitLogProcess {
  return spawn("git", args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
}

function run(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}
