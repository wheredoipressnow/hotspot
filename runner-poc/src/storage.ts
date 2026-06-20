import Database from "better-sqlite3";
import type { CommitRecord } from "./types.ts";

// Schema from HANDOFF.md §3 — raw facts only, never derived scores.
const SCHEMA = `
CREATE TABLE IF NOT EXISTS commit_info (
  sha          TEXT PRIMARY KEY,
  committed_at INTEGER NOT NULL,
  author_name  TEXT NOT NULL,
  author_email TEXT NOT NULL,
  parent_count INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS file_change (
  commit_sha TEXT NOT NULL,
  path       TEXT NOT NULL,
  added      INTEGER,
  deleted    INTEGER,
  FOREIGN KEY (commit_sha) REFERENCES commit_info(sha)
);

CREATE TABLE IF NOT EXISTS rename_edge (
  commit_sha TEXT NOT NULL,
  old_path   TEXT NOT NULL,
  new_path   TEXT NOT NULL,
  similarity INTEGER,
  FOREIGN KEY (commit_sha) REFERENCES commit_info(sha)
);

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

-- Indexes serve the two real analysis query shapes (HANDOFF §5).
CREATE INDEX IF NOT EXISTS idx_file_change_commit ON file_change(commit_sha);
CREATE INDEX IF NOT EXISTS idx_file_change_path   ON file_change(path);
CREATE INDEX IF NOT EXISTS idx_commit_committed   ON commit_info(committed_at);
CREATE INDEX IF NOT EXISTS idx_rename_new         ON rename_edge(new_path);
CREATE INDEX IF NOT EXISTS idx_rename_old         ON rename_edge(old_path);
`;

export type DB = Database.Database;

/** Open (or create) a database, apply pragmas tuned for bulk load, and ensure schema. */
export function openDb(path: string): DB {
  const db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.pragma("foreign_keys = ON");
  db.exec(SCHEMA);
  return db;
}

export class Storage {
  private readonly db: DB;
  private readonly stmts: {
    delFiles: Database.Statement;
    delRenames: Database.Statement;
    insCommit: Database.Statement;
    insFile: Database.Statement;
    insRename: Database.Statement;
    setMeta: Database.Statement;
    getMeta: Database.Statement;
  };
  private readonly runBatch: (commits: CommitRecord[]) => void;

  constructor(db: DB) {
    this.db = db;
    this.stmts = {
      delFiles: db.prepare("DELETE FROM file_change WHERE commit_sha = ?"),
      delRenames: db.prepare("DELETE FROM rename_edge WHERE commit_sha = ?"),
      insCommit: db.prepare(
        `INSERT OR REPLACE INTO commit_info
           (sha, committed_at, author_name, author_email, parent_count)
         VALUES (@sha, @committedAt, @authorName, @authorEmail, @parentCount)`,
      ),
      insFile: db.prepare(
        "INSERT INTO file_change (commit_sha, path, added, deleted) VALUES (?, ?, ?, ?)",
      ),
      insRename: db.prepare(
        "INSERT INTO rename_edge (commit_sha, old_path, new_path, similarity) VALUES (?, ?, ?, ?)",
      ),
      setMeta: db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)"),
      getMeta: db.prepare("SELECT value FROM meta WHERE key = ?"),
    };

    // One transaction per batch. Per commit: delete-by-sha then insert (idempotent replay),
    // then advance last_sha to the newest commit written in this batch.
    this.runBatch = db.transaction((commits: CommitRecord[]) => {
      for (const c of commits) {
        this.stmts.delFiles.run(c.sha);
        this.stmts.delRenames.run(c.sha);
        this.stmts.insCommit.run(c);
        for (const f of c.files) {
          this.stmts.insFile.run(c.sha, f.path, f.added, f.deleted);
        }
        for (const r of c.renames) {
          this.stmts.insRename.run(c.sha, r.oldPath, r.newPath, r.similarity);
        }
      }
      const last = commits.at(-1);
      if (last) this.stmts.setMeta.run("last_sha", last.sha);
    });
  }

  /** Write a batch of commits atomically. Caller batches (e.g. N=1000) before calling. */
  writeBatch(commits: CommitRecord[]): void {
    if (commits.length === 0) return;
    this.runBatch(commits);
  }

  getMeta(key: string): string | undefined {
    const row = this.stmts.getMeta.get(key) as { value: string } | undefined;
    return row?.value;
  }

  setMeta(key: string, value: string): void {
    this.stmts.setMeta.run(key, value);
  }

  /** Row counts + last_sha, for verification/dump. */
  summary(): { commits: number; files: number; renames: number; lastSha?: string } {
    const count = (t: string) =>
      (this.db.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get() as { n: number }).n;
    return {
      commits: count("commit_info"),
      files: count("file_change"),
      renames: count("rename_edge"),
      lastSha: this.getMeta("last_sha"),
    };
  }
}
