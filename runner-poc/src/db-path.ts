import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Resolve the SQLite file for a repo: one db per repo, keyed by the repo's
 * top-level path under the XDG data dir. Keeps the analyzed repo clean (no
 * stray db file, survives `git clean`). Pass `override` for an explicit path.
 */
export function resolveDbPath(toplevel: string, override?: string): string {
  if (override) return override;
  const base = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  const dir = join(base, "hotspot");
  mkdirSync(dir, { recursive: true });
  const hash = createHash("sha256").update(toplevel).digest("hex");
  return join(dir, `${hash}.db`);
}
