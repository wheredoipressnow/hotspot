import { parseArgs } from "node:util";
import { resolveDbPath } from "./db-path.ts";
import { revParseToplevel } from "./git.ts";
import { extract } from "./runner.ts";
import { openDb, Storage } from "./storage.ts";

async function main(argv: string[]): Promise<void> {
  const command = argv[0];
  const rest = argv.slice(1);

  if (command === "extract") {
    const { values } = parseArgs({
      args: rest,
      options: {
        ref: { type: "string", default: "HEAD" },
        db: { type: "string" },
        force: { type: "boolean", default: false },
      },
    });
    const res = await extract({
      cwd: process.cwd(),
      ref: values.ref as string,
      db: values.db,
      force: values.force,
    });
    console.log(
      `[${res.mode}] wrote ${res.commitsWritten} commits for ${values.ref}\n` +
      `  repo: ${res.toplevel}\n  db:   ${res.dbPath}\n  tip:  ${res.tipSha}`,
    );
    return;
  }

  if (command === "dump") {
    const { values } = parseArgs({
      args: rest,
      options: { db: { type: "string" } },
    });
    const toplevel = revParseToplevel(process.cwd());
    const dbPath = resolveDbPath(toplevel, values.db);
    const db = openDb(dbPath);
    try {
      const s = new Storage(db).summary();
      console.log(
        `db: ${dbPath}\ncommits: ${s.commits}\nfile_changes: ${s.files}\n` +
        `renames: ${s.renames}\nlast_sha: ${s.lastSha ?? "(none)"}`,
      );
    } finally {
      db.close();
    }
    return;
  }

  console.error("usage: cli.ts <extract|dump> [--ref HEAD] [--db PATH] [--force]");
  process.exitCode = 2;
}

main(process.argv.slice(2)).catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exitCode = 1;
});
