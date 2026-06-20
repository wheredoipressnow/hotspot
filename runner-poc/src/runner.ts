import { resolveDbPath } from "./db-path.ts";
import {
  type GitLogProcess,
  lsTreeFiles,
  revParse,
  revParseToplevel,
  spawnFullLog,
  spawnIncrementalLog,
} from "./git.ts";
import { CommitStreamParser } from "./parser.ts";
import { openDb, Storage } from "./storage.ts";
import type { CommitRecord } from "./types.ts";

const BATCH_SIZE = 1000; // commits per transaction (HANDOFF §4)

export interface ExtractOptions {
  cwd: string;
  ref: string;
  db?: string;
  force?: boolean; // ignore last_sha and re-extract the whole history
}

export interface ExtractResult {
  dbPath: string;
  toplevel: string;
  mode: "full" | "incremental";
  commitsWritten: number;
  tipSha: string;
  trackedFiles: number;
}

/**
 * Extract a ref's history into the repo's SQLite db. Full (`--reverse`) on first run
 * or `force`; otherwise incremental over `last_sha..ref`. Streams git output through
 * the parser and writes in batched transactions.
 */
export async function extract(opts: ExtractOptions): Promise<ExtractResult> {
  const toplevel = revParseToplevel(opts.cwd);
  const tipSha = revParse(opts.cwd, opts.ref);
  const dbPath = resolveDbPath(toplevel, opts.db);

  const db = openDb(dbPath);
  try {
    const store = new Storage(db);
    store.setMeta("repo_path", toplevel);
    store.setMeta("ref", opts.ref);

    const lastSha = store.getMeta("last_sha");
    const incremental = !opts.force && lastSha !== undefined;
    const child = incremental
      ? spawnIncrementalLog(toplevel, lastSha as string, opts.ref)
      : spawnFullLog(toplevel, opts.ref);

    const commitsWritten = await consume(child, store);
    store.setMeta("last_sha", tipSha); // pin to the exact tip we extracted to

    const tracked = lsTreeFiles(toplevel, tipSha);
    store.replaceTrackedFiles(tracked, tipSha);

    return {
      dbPath,
      toplevel,
      mode: incremental ? "incremental" : "full",
      commitsWritten,
      tipSha,
      trackedFiles: tracked.length,
    };
  } finally {
    db.close();
  }
}

/** Stream the child's stdout through the parser, flushing batches to storage. */
function consume(child: GitLogProcess, store: Storage): Promise<number> {
  return new Promise((resolve, reject) => {
    const parser = new CommitStreamParser();
    const pending: CommitRecord[] = [];
    let total = 0;
    let stderr = "";

    const flush = (force: boolean) => {
      while (pending.length >= BATCH_SIZE || (force && pending.length > 0)) {
        const batch = pending.splice(0, BATCH_SIZE);
        store.writeBatch(batch);
        total += batch.length;
      }
    };

    child.stdout.on("data", (chunk: Buffer) => {
      pending.push(...parser.push(chunk));
      flush(false);
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`git exited with code ${code}: ${stderr.trim()}`));
        return;
      }
      try {
        pending.push(...parser.end());
        flush(true);
        resolve(total);
      } catch (err) {
        reject(err);
      }
    });
  });
}

/** Check whether stored data is behind the ref's current tip. */
export function isStale(opts: { cwd: string; ref: string; db?: string }): boolean {
  const toplevel = revParseToplevel(opts.cwd);
  const tipSha = revParse(opts.cwd, opts.ref);
  const dbPath = resolveDbPath(toplevel, opts.db);
  const db = openDb(dbPath);
  try {
    return new Storage(db).getMeta("last_sha") !== tipSha;
  } finally {
    db.close();
  }
}
