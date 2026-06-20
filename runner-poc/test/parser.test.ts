import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { CommitStreamParser, parseCommits } from "../src/parser.ts";

const fixture = readFileSync(
  fileURLToPath(new URL("./fixtures/full_history.bin", import.meta.url)),
);
const shaOrder = readFileSync(
  fileURLToPath(new URL("./fixtures/full_history.shas.txt", import.meta.url)),
  "utf8",
)
  .trim()
  .split("\n");

describe("parseCommits on captured git -z output", () => {
  const commits = parseCommits(fixture);
  const bySha = new Map(commits.map((c) => [c.sha, c]));

  it("parses every commit in --reverse order", () => {
    expect(commits.map((c) => c.sha)).toEqual(shaOrder);
  });

  it("root commit has parentCount 0 and multiple files", () => {
    const root = commits[0];
    expect(root?.parentCount).toBe(0);
    expect(root?.authorName).toBe("Ada Lovelace");
    expect(root?.authorEmail).toBe("ada@example.com");
    expect(root?.files).toEqual([
      { path: "a.txt", added: 2, deleted: 0 },
      { path: "src/main.ts", added: 1, deleted: 0 },
    ]);
  });

  it("stores binary files with NULL added/deleted", () => {
    const c = bySha.get("9541eedb35e8aca7cd575135d89949b03d0d3a88");
    expect(c?.files).toEqual([{ path: "logo.bin", added: null, deleted: null }]);
  });

  it("records a rename edge and attributes the change to the new path", () => {
    const c = bySha.get("d851f9721dee5e57d3ba8733a19b6e255a4ed8d9");
    expect(c?.renames).toEqual([
      { oldPath: "src/main.ts", newPath: "src/app.ts", similarity: null },
    ]);
    expect(c?.files).toEqual([{ path: "src/app.ts", added: 1, deleted: 0 }]);
  });

  it("preserves multibyte paths", () => {
    const c = bySha.get("73b005760327e2952ac4eaa8acc5ff86cbb600d4");
    expect(c?.files).toEqual([{ path: "café ☕.txt", added: 1, deleted: 0 }]);
  });

  it("stores empty commits with no file changes", () => {
    const c = bySha.get("ca780decd798066f6d56117dd3aa043217dbebf0");
    expect(c?.parentCount).toBe(1);
    expect(c?.files).toEqual([]);
    expect(c?.renames).toEqual([]);
  });

  it("stores merge commits as parentCount 2 with no file rows", () => {
    const merge = commits.at(-1);
    expect(merge?.parentCount).toBe(2);
    expect(merge?.files).toEqual([]);
  });
});

describe("CommitStreamParser", () => {
  it("yields the same commits regardless of chunk boundaries", () => {
    const expected = parseCommits(fixture);
    for (const size of [1, 7, 64, 256, 100000]) {
      const parser = new CommitStreamParser();
      const got = [];
      for (let i = 0; i < fixture.length; i += size) {
        got.push(...parser.push(fixture.subarray(i, i + size)));
      }
      got.push(...parser.end());
      expect(got.map((c) => c.sha)).toEqual(expected.map((c) => c.sha));
      // spot-check the rename commit survived chunking
      const ren = got.find((c) => c.renames.length > 0);
      expect(ren?.renames[0]?.newPath).toBe("src/app.ts");
    }
  });
});
