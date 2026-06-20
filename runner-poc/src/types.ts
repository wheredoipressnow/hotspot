/** One file touched in one commit. `added`/`deleted` are null for binary files. */
export interface FileChange {
  path: string;
  added: number | null;
  deleted: number | null;
}

/** A rename detected by `git log -M` at a given commit. similarity is null under -z. */
export interface RenameEdge {
  oldPath: string;
  newPath: string;
  similarity: number | null;
}

/** One commit's raw facts. parentCount: 0 root, 1 normal, 2+ merge. */
export interface CommitRecord {
  sha: string;
  committedAt: number; // unix epoch (author timestamp, %at)
  authorName: string; // mailmap-respecting (%aN)
  authorEmail: string; // %aE
  parentCount: number;
  files: FileChange[]; // empty for merges / empty commits
  renames: RenameEdge[];
}

/** Thrown by the parser when the byte stream does not match the expected framing. */
export class ParseError extends Error {
  override name = "ParseError";
}
