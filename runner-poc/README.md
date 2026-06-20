# Git Hotspot Analyzer — Runner + Storage PoC (TypeScript)

Proof of concept for the riskiest layer of the Git Hotspot Analyzer (see top-level
`HANDOFF.md`): extract a repo's history with `git log`, parse every numstat edge case,
and write raw facts to SQLite — durably, incrementally, idempotently.

**In scope:** git runner, numstat parser, SQLite storage (schema, batching, incremental
refresh). **Out of scope:** analysis/metrics, CLI ranking tables, web/treemap.

## Run

Run inside the devenv shell (provides Node, pnpm, sqlite, and `biome`). On NixOS the
npm-distributed Biome binary cannot run, so Biome comes from `devenv.nix` (`pkgs.biome`),
not from `node_modules`.

```sh
pnpm install
pnpm test            # parser + storage suites (vitest)
pnpm check           # biome format + lint (uses the devenv-provided biome)

pnpm extract --ref HEAD          # extract this repo into the default db
pnpm extract --ref main --db /tmp/x.db --force
pnpm dump --db /tmp/x.db         # row counts + last_sha
```

## Build a runnable bundle (plain `node`, no `--experimental-strip-types`)

```sh
pnpm build           # esbuild -> dist/cli.js (better-sqlite3 stays external)

# run against ANY repo: cd into it (repo is resolved from cwd), point node at dist/cli.js
cd /path/to/other/repo
node /abs/path/to/runner-poc/dist/cli.js extract --ref main --db /tmp/other.db
node /abs/path/to/runner-poc/dist/cli.js dump --db /tmp/other.db
```

`better-sqlite3` is a native module, so it is kept external — `dist/cli.js` still needs the
package's `node_modules` next to it (not a fully standalone binary). The `bin` field maps
`hotspot` -> `dist/cli.js`, so `pnpm link --global` (after `build`) gives a `hotspot` command.

## Database location

One SQLite file per repo, keyed by the repo's top-level path:

```
$XDG_DATA_HOME/hotspot/<sha256(toplevel)>.db
# falls back to ~/.local/share/hotspot/... when XDG_DATA_HOME is unset
```

Override with `--db <path>`. Repo identity is resolved via `git rev-parse --show-toplevel`,
so invoking from a subdirectory maps to the same database.

## Extraction model (the binding decisions)

- Single streamed `git log` over the whole ref — never one command per file.
- `-z` framing with `%x00` field delimiters; `core.quotePath=false` (paths arrive unquoted).
- `-M` rename detection is **always on** (lossy if skipped — only re-extraction recovers it).
- Full extraction runs with **`diff.renameLimit=0` (unlimited)** so large reorg commits do not
  silently drop renames. Cost: rename detection on a pathological huge commit (initial import,
  mass move) can be slow — seconds to low-minutes, one-time, full-extraction only.
- Binary files store `added`/`deleted` as **NULL**, never 0.
- Merge commits store `commit_info` only (no `file_change` rows) — avoids double-counting churn
  already recorded on the branch commits. `parent_count` is kept so analysis can still
  include/exclude merges later.
- Inserts are idempotent (per-commit delete-by-sha then insert), so an interrupted extraction
  can be safely re-run.

## Refresh / incremental

`meta.last_sha` records the last fully-written commit. Full extraction uses `--reverse`
(oldest→newest) so `last_sha` advances monotonically and a crash can resume from `last_sha..ref`.
Incremental refresh extracts only `last_sha..ref`.

## Note on `better-sqlite3`

Native module. Prebuilt binaries normally resolve under Node 22. If a source build is triggered
in your environment, ensure a C/C++ toolchain + Python are available (the devenv shell provides
gcc/make; add `pkgs.python3` to `devenv.nix` packages if needed).
