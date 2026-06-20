import Database from "better-sqlite3";
import { beforeEach, describe, expect, it } from "vitest";
import { Storage } from "../src/storage.ts";
import type { CommitRecord } from "../src/types.ts";

function freshDb() {
  const db = new Database(":memory:");
  db.pragma("foreign_keys = ON");
  db.exec(`
    CREATE TABLE commit_info (sha TEXT PRIMARY KEY, committed_at INTEGER NOT NULL,
      author_name TEXT NOT NULL, author_email TEXT NOT NULL, parent_count INTEGER NOT NULL);
    CREATE TABLE file_change (commit_sha TEXT NOT NULL, path TEXT NOT NULL,
      added INTEGER, deleted INTEGER);
    CREATE TABLE rename_edge (commit_sha TEXT NOT NULL, old_path TEXT NOT NULL,
      new_path TEXT NOT NULL, similarity INTEGER);
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE tracked_file (path TEXT PRIMARY KEY);
  `);
  return db;
}

function commit(sha: string, over: Partial<CommitRecord> = {}): CommitRecord {
  return {
    sha,
    committedAt: 1700000000,
    authorName: "Ada",
    authorEmail: "ada@example.com",
    parentCount: 1,
    files: [{ path: "a.ts", added: 3, deleted: 1 }],
    renames: [],
    ...over,
  };
}

describe("Storage", () => {
  let db: Database.Database;
  let store: Storage;

  beforeEach(() => {
    db = freshDb();
    store = new Storage(db);
  });

  it("writes commits, files, renames and advances last_sha", () => {
    store.writeBatch([
      commit("aaa"),
      commit("bbb", {
        parentCount: 1,
        files: [{ path: "new.ts", added: 5, deleted: 0 }],
        renames: [{ oldPath: "old.ts", newPath: "new.ts", similarity: null }],
      }),
    ]);
    const s = store.summary();
    expect(s.commits).toBe(2);
    expect(s.files).toBe(2);
    expect(s.renames).toBe(1);
    expect(s.lastSha).toBe("bbb");
  });

  it("stores binary changes as NULL, not 0", () => {
    store.writeBatch([commit("aaa", { files: [{ path: "img.png", added: null, deleted: null }] })]);
    const row = db.prepare("SELECT added, deleted FROM file_change WHERE path = 'img.png'").get();
    expect(row).toEqual({ added: null, deleted: null });
  });

  it("stores merge commits with no file rows but keeps parent_count", () => {
    store.writeBatch([commit("merge", { parentCount: 2, files: [], renames: [] })]);
    const s = store.summary();
    expect(s.commits).toBe(1);
    expect(s.files).toBe(0);
    const pc = db.prepare("SELECT parent_count AS p FROM commit_info WHERE sha='merge'").get();
    expect(pc).toEqual({ p: 2 });
  });

  it("is idempotent on replay; no duplicate file_change rows", () => {
    const batch = [commit("aaa", { files: [{ path: "a.ts", added: 3, deleted: 1 }] })];
    store.writeBatch(batch);
    store.writeBatch(batch); // replay same commit (crash/overlap)
    const s = store.summary();
    expect(s.commits).toBe(1);
    expect(s.files).toBe(1); // not 2
  });

  it("round-trips meta values", () => {
    store.setMeta("ref", "refs/heads/main");
    expect(store.getMeta("ref")).toBe("refs/heads/main");
    expect(store.getMeta("missing")).toBeUndefined();
  });

  it("replaces the tracked_file snapshot wholesale and pins tracked_sha", () => {
    store.replaceTrackedFiles(["a.ts", "lib/b.ts"], "aaa");
    expect(store.summary().tracked).toBe(2);
    expect(store.getMeta("tracked_sha")).toBe("aaa");

    store.replaceTrackedFiles(["lib/b.ts", "c.ts"], "bbb");
    const paths = db
      .prepare("SELECT path FROM tracked_file ORDER BY path")
      .all()
      .map((r) => (r as { path: string }).path);
    expect(paths).toEqual(["c.ts", "lib/b.ts"]);
    expect(store.getMeta("tracked_sha")).toBe("bbb");
  });
});
