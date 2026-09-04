# Adopt an existing backend database — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a server refuse to start against a database migrated by a newer binary, adopt a
pre-existing populated database as a recorded decision rather than an inference from user count,
and let an operator list pending migrations tiered by whether they make rollback impossible.

**Architecture:** One fork-owned module, `packages/backend/server/src/core/db-compat/`, with all
judgement in two pure functions (`classify.ts`, `compat.ts`) and thin I/O around them. Two entry
points consume it: a CLI command group (`db status`, `db check`) running on a minimal Nest context,
and an `OnApplicationBootstrap` guard that refuses to listen. `scripts/self-host-predeploy.js`
calls `db check` before `prisma migrate deploy` — the k8s initContainer and the self-host compose
service both already invoke that script, so no infrastructure change is needed.

**Tech Stack:** TypeScript, NestJS 11, Prisma 6 (`$queryRaw` for `_prisma_migrations`),
commander 13, ava 7 for tests, oxfmt for formatting.

**Design:** [`DESIGN.md`](DESIGN.md) · Decisions: [`findings/decision-log.md`](findings/decision-log.md)
(D1–D14) · Grounding: [`findings/grounding.md`](findings/grounding.md) (G1–G10)

**Bead:** `affine-tc6`. Tasks T1–T6 here map to subtasks `affine-tc6.1`–`.6`.

---

## Before you start

Run every command from the repository root unless a step says otherwise.

**Toolchain.** This repo's server package uses yarn workspaces. The two command forms you need:

```bash
yarn affine @affine/server test <path-to-spec>
```

```bash
yarn affine @affine/server prisma migrate deploy
```

**Tests needing a database.** T2, T3, T4 and T5 include specs that talk to Postgres. The suite
expects a database named `affine` owned by a superuser `affine`, migrated to head. This mirrors
`.github/actions/server-test-env/action.yml`:

```bash
psql -h localhost -U postgres -c "CREATE DATABASE affine;"
```

```bash
psql -h localhost -U postgres -c "CREATE USER affine WITH PASSWORD 'affine'; ALTER USER affine WITH SUPERUSER;"
```

```bash
yarn affine @affine/server prisma generate && yarn affine @affine/server prisma migrate deploy && yarn affine @affine/server data-migration run
```

**`DATABASE_URL` must be exported in your shell.** CI supplies it as a job env var; locally it is
unset, and the config default (`postgresql://localhost:5432/affine`, no credentials) does **not**
connect. Verified: a bare `new PrismaClient()` fails without it.

```bash
export DATABASE_URL="postgresql://affine:affine@localhost:5432/affine"
```

**The development database may be shared with other work.** Do not assert absolute row counts
against it — a count that is stable today can change under you.

But do **not** "solve" that by deriving the expectation from the same call the code under test
makes. `t.is(state.populated, (await db.user.count()) > 0)` restates the implementation and cannot
fail; T2 shipped exactly that test and had to replace it. Instead **build a scratch schema with
known contents** and assert against what you put there — bind it with `?schema=` on the connection
URL (see T2's `db-state.spec.ts` for the pattern, including dropping the schema first so a run
after an abnormal exit is idempotent). That gives a falsifiable assertion and is immune to what
else is using the shared database.

T1 needs **no** database — it is pure functions over files on disk.

**Formatting.** `oxfmt` runs over staged files in the pre-commit hook, so no formatting step is
needed per task. If you want to check by hand: `yarn lint:format`.

**The manifest guard's category column is now enforced** (`affine-hn1.4`, merged in PR #4). Column
2 of the manifest table is load-bearing, not documentation: `--outbound` fails when a change set
touches a file whose row says **FORK-LOCAL CORE PATCH**, and an unrecognised category exits 2
rather than being assumed ADDITIVE. All three rows this plan adds are **ADDITIVE**, which is
correct — none of them changes upstream behaviour — so they are safe in both directions. If the
guard rejects a row you added, `scripts/woven-manifest-guard.sh --dump-rows` prints exactly what
the parser saw for each row.

**Two traps specific to this work:**

1. **`env.testing` must short-circuit the boot guard.** Seven existing test files import
   `AppModule` and call `module.init()`, which runs `onApplicationBootstrap`. A guard that queries
   the database there adds a failure mode to all seven. T5 Step 3 handles this; do not skip it.
2. **Never register these knobs with `defineModuleConfig`** (D13). `AFFINE_DEPLOYMENT_ID`,
   `AFFINE_DB_ADOPT` and `AFFINE_DB_COMPAT_SKIP` are read straight from `process.env`. A config
   item with an `env:` binding is _also_ settable from the `app_configs` table, which would let a
   database row switch off the guard that reads it.

## File Structure

**Create — all fork-owned, no manifest row needed:**

| Path                                                 | Responsibility                                                                           |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `src/core/db-compat/classify.ts`                     | Pure. SQL scrub → statements → tier + hits.                                              |
| `src/core/db-compat/migration-set.ts`                | Resolve the migrations dir; read names and `migration.sql`.                              |
| `src/core/db-compat/db-state.ts`                     | Read `_prisma_migrations` and the user count.                                            |
| `src/core/db-compat/identity.ts`                     | Read/write the `$deployment` stamp; evaluate identity.                                   |
| `src/core/db-compat/env.ts`                          | The three `process.env` reads, in one place.                                             |
| `src/core/db-compat/prisma-errors.ts`                | `isUndefinedTable` — shared by `db-state.ts` and `identity.ts` (T3).                     |
| `src/core/db-compat/compat.ts`                       | Pure. Inputs → `CompatReport` with a verdict.                                            |
| `src/core/db-compat/service.ts`                      | `DbCompatService`: `report()`, pure `check()`, `stamp()` (D17), and the pure `decide()`. |
| `src/core/db-compat/guard.ts`                        | `DbCompatGuard` — `OnApplicationBootstrap`, refuses to listen.                           |
| `src/core/db-compat/render.ts`                       | Format a `CompatReport` as operator-readable text.                                       |
| `src/core/db-compat/index.ts`                        | `DbCompatModule`, `DbCompatGuardModule`, public types.                                   |
| `src/core/db-compat/cli-module.ts`                   | `DbCompatCliModule` — the config+prisma-only context (T4).                               |
| `src/core/db-compat/__tests__/render.spec.ts`        | T4 — report formatting, incl. UNKNOWN vs POSSIBLE.                                       |
| `src/core/db-compat/README.md`                       | Operator-facing docs for the three env knobs (T6).                                       |
| `src/core/db-compat/__tests__/classify.spec.ts`      | T1 — rules, scrubbing, corpus anchors and totals.                                        |
| `src/core/db-compat/__tests__/migration-set.spec.ts` | T1 — dir resolution and reads.                                                           |
| `src/core/db-compat/__tests__/compat.spec.ts`        | T2 — the whole verdict table, pure.                                                      |
| `src/core/db-compat/__tests__/db-state.spec.ts`      | T2 — real Postgres.                                                                      |
| `src/core/db-compat/__tests__/identity.spec.ts`      | T3 — real Postgres; stamp round-trip, inertness.                                         |
| `src/core/db-compat/__tests__/service.spec.ts`       | T3 — adoption gate decisions.                                                            |
| `src/core/db-compat/__tests__/guard.spec.ts`         | T5 — guard refuses/permits/bypasses.                                                     |

**Modify — upstream-owned, each needs a `scripts/woven-patch-manifest.md` row:**

| Path                             | Change                                               | Task |
| -------------------------------- | ---------------------------------------------------- | ---- |
| `src/cli.ts`                     | `withMinimalApp` + the `db` command group            | T4   |
| `src/app.module.ts`              | import `DbCompatGuardModule` into `AppModule`        | T5   |
| `scripts/self-host-predeploy.js` | `db check` before migrations, `db stamp` after (D17) | T5   |

**Modify — fork-owned, no row needed:** `scripts/woven-patch-manifest.md` (T6).

---

## Task 1: Pure classifier and migration set

> **LANDED 2026-09-01 — the code blocks below are the PRE-REVIEW design; the committed source is
> the authority.** Review found five defects, two failing OPEN, and the fixes changed behaviour and
> one signature. Divergences (`5f2d539598` → `d41704f430` → `9acc70ca26` → `48f5de1aa8`):
>
> - `scrubSql` also blanks **double-quoted identifiers** and handles `''` / E-string escapes; the
>   dollar-tag pattern accepts digits. See G2d.
> - `DdlClassification` carries **`unterminated: boolean`**, which forces `BLOCKING` with a
>   synthetic `unparseable` hit (D4b).
> - `rename-table` is anchored to `ALTER TABLE`; `truncate` to the start of a statement.
> - `DdlHit.statement` is the **full** collapsed statement — `MAX_STATEMENT_DISPLAY` is gone, and
>   truncation moved to `render.ts`.
> - `MigrationSet.sql()` returns **`string | null`**; `resolveMigrationsDir` requires
>   `migration_lock.toml` as a discriminator and tries bundle-relative candidates first.
> - The corpus fixture is **17 / 14 / 86**, not 18 / 14 / 85 — a false positive was removed, not an
>   assertion relaxed. See the correction note in G2a.

**Files:**

- Create: `packages/backend/server/src/core/db-compat/classify.ts`
- Create: `packages/backend/server/src/core/db-compat/migration-set.ts`
- Test: `packages/backend/server/src/core/db-compat/__tests__/classify.spec.ts`
- Test: `packages/backend/server/src/core/db-compat/__tests__/migration-set.spec.ts`

No database. These are the two files everything else stands on, so they get tested hardest.

- [ ] **Step 1: Write the failing classifier tests**

Create `packages/backend/server/src/core/db-compat/__tests__/classify.spec.ts`:

```ts
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import test from 'ava';

import { classifyDdl, scrubSql, splitStatements } from '../classify';

test('additive DDL is EXPAND', t => {
  const { tier, hits } = classifyDdl(
    'CREATE TABLE "foo" ("id" TEXT NOT NULL);'
  );
  t.is(tier, 'EXPAND');
  t.deepEqual(hits, []);
});

test('DROP TABLE is BLOCKING', t => {
  const { tier, hits } = classifyDdl('DROP TABLE "foo";');
  t.is(tier, 'BLOCKING');
  t.is(hits.length, 1);
  t.is(hits[0].rule, 'drop-table');
  t.is(hits[0].line, 1);
});

test('DROP CONSTRAINT alone is DESTRUCTIVE, never BLOCKING', t => {
  const { tier, hits } = classifyDdl(
    'ALTER TABLE "foo" DROP CONSTRAINT "foo_bar_fkey";'
  );
  t.is(tier, 'DESTRUCTIVE');
  t.is(hits[0].rule, 'drop-constraint');
});

test('a BLOCKING hit wins over a DESTRUCTIVE one', t => {
  const { tier } = classifyDdl(
    'ALTER TABLE "foo" DROP CONSTRAINT "c";\nALTER TABLE "foo" DROP COLUMN "bar";'
  );
  t.is(tier, 'BLOCKING');
});

test('SET NOT NULL split across lines is still caught (G2c)', t => {
  const { tier, hits } = classifyDdl(
    'ALTER TABLE "foo" ALTER COLUMN "bar"\n  SET NOT NULL;'
  );
  t.is(tier, 'BLOCKING');
  t.is(hits[0].rule, 'set-not-null');
});

test('DDL inside a $$ function body is ignored (G2b)', t => {
  const sql = [
    'CREATE OR REPLACE FUNCTION purge() RETURNS void AS $$',
    'BEGIN',
    '  DELETE FROM "audit";',
    '  DROP TABLE "scratch";',
    'END;',
    '$$ LANGUAGE plpgsql;',
  ].join('\n');
  t.is(classifyDdl(sql).tier, 'EXPAND');
});

test('DDL inside a tagged dollar body is ignored', t => {
  const sql =
    'CREATE FUNCTION f() RETURNS void AS $body$ DROP TABLE "x"; $body$ LANGUAGE plpgsql;';
  t.is(classifyDdl(sql).tier, 'EXPAND');
});

test('commented-out DDL is ignored', t => {
  t.is(
    classifyDdl('-- DROP TABLE "foo";\nCREATE TABLE "foo" ("id" TEXT);').tier,
    'EXPAND'
  );
  t.is(
    classifyDdl('/* DROP TABLE "foo"; */ CREATE TABLE "foo" ("id" TEXT);').tier,
    'EXPAND'
  );
});

test('scrubSql preserves line count', t => {
  const sql = 'a\n-- b\n/* c\nd */\ne';
  t.is(scrubSql(sql).split('\n').length, sql.split('\n').length);
});

test('splitStatements reports the line each statement starts on', t => {
  const stmts = splitStatements('CREATE TABLE "a" ();\n\nDROP TABLE "b";');
  t.is(stmts.length, 2);
  t.is(stmts[0].line, 1);
  t.is(stmts[1].line, 3);
});

// --- corpus anchors and totals, measured in grounding G2a -------------------
// These are the regression fixtures the tiering exists for. Do not soften them
// to make a rule-set change pass; if a number here moves, re-measure and say so.
//
// 17/14/86 as of the quoted-identifier scrub. The earlier 18/14/85 included a
// false-positive BLOCKING on 20250203142831_standardize_features, where
// `retype-column` matched the quoted column name "type" in
// `ALTER COLUMN "type" SET DEFAULT 0` rather than a real TYPE keyword. That
// migration is purely additive, so EXPAND is correct. The fixture moved because
// a false positive was removed, NOT because the assertion was relaxed.

const MIGRATIONS_DIR = join(import.meta.dirname, '../../../../migrations');

const corpus = () =>
  readdirSync(MIGRATIONS_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .sort();

test('corpus tiers exactly as measured: 17 / 14 / 86 of 117', t => {
  const counts = { BLOCKING: 0, DESTRUCTIVE: 0, EXPAND: 0 };
  for (const name of corpus()) {
    const sql = readFileSync(
      join(MIGRATIONS_DIR, name, 'migration.sql'),
      'utf8'
    );
    counts[classifyDdl(sql).tier]++;
  }
  t.deepEqual(counts, { BLOCKING: 17, DESTRUCTIVE: 14, EXPAND: 86 });
});

test('anchor: drop_legacy_permission_and_subscription is BLOCKING', t => {
  const sql = readFileSync(
    join(
      MIGRATIONS_DIR,
      '20260714000001_drop_legacy_permission_and_subscription',
      'migration.sql'
    ),
    'utf8'
  );
  t.is(classifyDdl(sql).tier, 'BLOCKING');
});

test('anchor: converge_copilot_runtime is DESTRUCTIVE, not BLOCKING', t => {
  const sql = readFileSync(
    join(
      MIGRATIONS_DIR,
      '20260803095500_converge_copilot_runtime',
      'migration.sql'
    ),
    'utf8'
  );
  const { tier, hits } = classifyDdl(sql);
  t.is(tier, 'DESTRUCTIVE');
  t.deepEqual([...new Set(hits.map(h => h.rule))], ['drop-constraint']);
});

test('anchor: function-body-only DDL stays EXPAND', t => {
  for (const name of [
    '20260512133700_workspace_runtime_states',
    '20260514000000_entitlement_quota_states',
  ]) {
    const sql = readFileSync(
      join(MIGRATIONS_DIR, name, 'migration.sql'),
      'utf8'
    );
    t.is(classifyDdl(sql).tier, 'EXPAND', name);
  }
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/classify.spec.ts`

Expected: FAIL — every test errors on an unresolved import of `../classify`.

- [ ] **Step 3: Implement `classify.ts`**

Create `packages/backend/server/src/core/db-compat/classify.ts`:

```ts
export type DdlTier = 'BLOCKING' | 'DESTRUCTIVE' | 'EXPAND';
export type HitTier = Exclude<DdlTier, 'EXPAND'>;

export interface DdlHit {
  tier: HitTier;
  /** Stable rule name, e.g. `drop-table`. Reported to operators. */
  rule: string;
  /** 1-based line where the offending statement starts. */
  line: number;
  /** The collapsed statement text, truncated for display. */
  statement: string;
}

export interface DdlClassification {
  tier: DdlTier;
  hits: DdlHit[];
}

interface Rule {
  name: string;
  tier: HitTier;
  pattern: RegExp;
}

/**
 * BLOCKING = an older binary cannot read or write the result, so image rollback
 * across it is impossible. DESTRUCTIVE = data or a constraint is lost but an
 * older binary still runs. Only BLOCKING gates; see design D4.
 */
const RULES: Rule[] = [
  { name: 'drop-table', tier: 'BLOCKING', pattern: /\bDROP\s+TABLE\b/i },
  { name: 'drop-column', tier: 'BLOCKING', pattern: /\bDROP\s+COLUMN\b/i },
  { name: 'rename-table', tier: 'BLOCKING', pattern: /\bRENAME\s+TO\b/i },
  { name: 'rename-column', tier: 'BLOCKING', pattern: /\bRENAME\s+COLUMN\b/i },
  {
    name: 'retype-column',
    tier: 'BLOCKING',
    pattern: /\bALTER\s+COLUMN\b.*?\bTYPE\b/i,
  },
  {
    name: 'set-not-null',
    tier: 'BLOCKING',
    pattern: /\bALTER\s+COLUMN\b.*?\bSET\s+NOT\s+NULL\b/i,
  },
  {
    name: 'drop-constraint',
    tier: 'DESTRUCTIVE',
    pattern: /\bDROP\s+CONSTRAINT\b/i,
  },
  { name: 'drop-index', tier: 'DESTRUCTIVE', pattern: /\bDROP\s+INDEX\b/i },
  { name: 'truncate', tier: 'DESTRUCTIVE', pattern: /\bTRUNCATE\b/i },
  { name: 'delete-from', tier: 'DESTRUCTIVE', pattern: /\bDELETE\s+FROM\b/i },
];

const MAX_STATEMENT_DISPLAY = 160;

/**
 * Blank out comments, dollar-quoted bodies and string literals, preserving the
 * total line count so reported line numbers stay accurate.
 *
 * Dollar-quote handling is load-bearing, not defensive: three migrations in the
 * corpus contain DROP/DELETE inside a `$$` function body that the migration
 * itself never executes. See grounding G2b.
 */
export function scrubSql(sql: string): string {
  let out = '';
  let i = 0;

  const blank = (from: number, to: number) => {
    for (let k = from; k < to; k++) {
      out += sql[k] === '\n' ? '\n' : ' ';
    }
  };

  while (i < sql.length) {
    if (sql.startsWith('--', i)) {
      const end = sql.indexOf('\n', i);
      const stop = end === -1 ? sql.length : end;
      blank(i, stop);
      i = stop;
      continue;
    }

    if (sql.startsWith('/*', i)) {
      const end = sql.indexOf('*/', i + 2);
      const stop = end === -1 ? sql.length : end + 2;
      blank(i, stop);
      i = stop;
      continue;
    }

    const dollar = /^\$[A-Za-z_]*\$/.exec(sql.slice(i));
    if (dollar) {
      const tag = dollar[0];
      const end = sql.indexOf(tag, i + tag.length);
      const stop = end === -1 ? sql.length : end + tag.length;
      blank(i, stop);
      i = stop;
      continue;
    }

    if (sql[i] === "'") {
      let k = i + 1;
      while (k < sql.length && sql[k] !== "'") {
        k++;
      }
      const stop = Math.min(k + 1, sql.length);
      blank(i, stop);
      i = stop;
      continue;
    }

    out += sql[i];
    i++;
  }

  return out;
}

export interface SqlStatement {
  /** Whitespace-collapsed statement text, without the trailing semicolon. */
  text: string;
  /** 1-based line the statement starts on. */
  line: number;
}

/**
 * Split scrubbed SQL into statements. Statement-level rather than per-line so a
 * clause split across lines still matches; see grounding G2c.
 */
export function splitStatements(sql: string): SqlStatement[] {
  const scrubbed = scrubSql(sql);
  const statements: SqlStatement[] = [];

  let start = 0;
  let line = 1;
  let startLine = 1;
  let seenText = false;

  const push = (raw: string) => {
    const text = raw.replace(/\s+/g, ' ').trim();
    if (text) {
      statements.push({ text, line: startLine });
    }
  };

  for (let i = 0; i < scrubbed.length; i++) {
    const ch = scrubbed[i];

    if (!seenText && !/\s/.test(ch)) {
      startLine = line;
      seenText = true;
    }

    if (ch === '\n') {
      line++;
    }

    if (ch === ';') {
      push(scrubbed.slice(start, i));
      start = i + 1;
      seenText = false;
    }
  }

  push(scrubbed.slice(start));

  return statements;
}

export function classifyDdl(sql: string): DdlClassification {
  const hits: DdlHit[] = [];

  for (const statement of splitStatements(sql)) {
    for (const rule of RULES) {
      if (rule.pattern.test(statement.text)) {
        hits.push({
          tier: rule.tier,
          rule: rule.name,
          line: statement.line,
          statement: statement.text.slice(0, MAX_STATEMENT_DISPLAY),
        });
      }
    }
  }

  const tier: DdlTier = hits.some(hit => hit.tier === 'BLOCKING')
    ? 'BLOCKING'
    : hits.length > 0
      ? 'DESTRUCTIVE'
      : 'EXPAND';

  return { tier, hits };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/classify.spec.ts`

Expected: PASS, 14 tests. If `corpus tiers exactly as measured` fails, **do not adjust the
expected numbers** — re-run the grounding measurement and reconcile, because a change there means
either a rule regressed or migrations were added since 2026-09-01.

- [ ] **Step 5: Commit**

```bash
git add packages/backend/server/src/core/db-compat/classify.ts packages/backend/server/src/core/db-compat/__tests__/classify.spec.ts && git commit -m "feat(woven): tiered destructive-DDL classifier for migrations (affine-tc6.1)"
```

- [ ] **Step 6: Write the failing migration-set tests**

Create `packages/backend/server/src/core/db-compat/__tests__/migration-set.spec.ts`:

```ts
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import test from 'ava';

import { loadMigrationSet, resolveMigrationsDir } from '../migration-set';

const fixture = () => {
  const root = mkdtempSync(join(tmpdir(), 'db-compat-'));
  const dir = join(root, 'migrations');
  mkdirSync(join(dir, '20240101000000_a'), { recursive: true });
  mkdirSync(join(dir, '20240102000000_b'), { recursive: true });
  writeFileSync(
    join(dir, '20240101000000_a', 'migration.sql'),
    'CREATE TABLE "a" ();'
  );
  writeFileSync(
    join(dir, '20240102000000_b', 'migration.sql'),
    'DROP TABLE "a";'
  );
  writeFileSync(join(dir, 'migration_lock.toml'), 'provider = "postgresql"');
  return { root, dir };
};

test('resolveMigrationsDir finds migrations/ under the given root', t => {
  const { root, dir } = fixture();
  t.is(resolveMigrationsDir([root]), dir);
});

test('resolveMigrationsDir returns null when no candidate has one', t => {
  t.is(resolveMigrationsDir([mkdtempSync(join(tmpdir(), 'empty-'))]), null);
});

test('loadMigrationSet lists directories only, sorted, skipping the lock file', t => {
  const { dir } = fixture();
  const set = loadMigrationSet(dir);
  t.truthy(set);
  t.deepEqual(set!.names, ['20240101000000_a', '20240102000000_b']);
});

test('loadMigrationSet reads migration.sql by name', t => {
  const { dir } = fixture();
  t.is(loadMigrationSet(dir)!.sql('20240102000000_b'), 'DROP TABLE "a";');
});

test('loadMigrationSet returns empty sql for an unknown name rather than throwing', t => {
  const { dir } = fixture();
  t.is(loadMigrationSet(dir)!.sql('nope'), '');
});

test('the real repository migrations directory resolves and has 117 entries', t => {
  const dir = resolveMigrationsDir();
  t.truthy(dir);
  t.is(loadMigrationSet(dir!)!.names.length, 117);
});
```

- [ ] **Step 7: Run to verify failure**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/migration-set.spec.ts`

Expected: FAIL — unresolved import of `../migration-set`.

- [ ] **Step 8: Implement `migration-set.ts`**

Create `packages/backend/server/src/core/db-compat/migration-set.ts`:

```ts
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const MIGRATIONS_DIRNAME = 'migrations';

/**
 * Candidate roots, in priority order.
 *
 * In the published image cwd is `/app` and the directory is `/app/migrations`;
 * in development cwd is `packages/backend/server`. The bundle-relative
 * fallbacks cover `node dist/main.js` invoked from somewhere else. See
 * grounding G5 — the directory demonstrably ships, because
 * `prisma migrate deploy` needs it at runtime.
 */
function defaultCandidates(): string[] {
  const here = import.meta.dirname;
  return [
    process.cwd(),
    resolve(here, '..', '..', '..'),
    resolve(dirname(process.argv[1] ?? process.cwd()), '..'),
  ];
}

export function resolveMigrationsDir(
  candidates: string[] = defaultCandidates()
): string | null {
  for (const candidate of candidates) {
    const dir = join(candidate, MIGRATIONS_DIRNAME);
    if (existsSync(dir) && statSync(dir).isDirectory()) {
      return dir;
    }
  }
  return null;
}

export interface MigrationSet {
  dir: string;
  /** Migration directory names, lexicographically sorted — prisma's own order. */
  names: string[];
  /** Contents of `<name>/migration.sql`, or '' when absent. */
  sql(name: string): string;
}

export function loadMigrationSet(
  dir: string | null = resolveMigrationsDir()
): MigrationSet | null {
  if (!dir || !existsSync(dir)) {
    return null;
  }

  const names = readdirSync(dir, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => entry.name)
    .sort();

  return {
    dir,
    names,
    sql(name: string) {
      const file = join(dir, name, 'migration.sql');
      return existsSync(file) ? readFileSync(file, 'utf8') : '';
    },
  };
}
```

- [ ] **Step 9: Run to verify pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/migration-set.spec.ts`

Expected: PASS, 6 tests.

- [ ] **Step 10: Commit**

```bash
git add packages/backend/server/src/core/db-compat/migration-set.ts packages/backend/server/src/core/db-compat/__tests__/migration-set.spec.ts && git commit -m "feat(woven): resolve and read the shipped prisma migration set (affine-tc6.1)"
```

---

## Task 2: Database state and the verdict engine

> **LANDED 2026-09-01 — and the code blocks below are the PRE-REVIEW design. The committed source
> is the authority.** Code review found three fail-opens and the fixes changed the interfaces, so
> re-executing this section verbatim would reintroduce them. Divergences, all in
> `fa3fc57ca1` → `df878c1adb` → `0e4882363a` → the wording follow-up:
>
> - `populated` is **`boolean | null`** in `DbState`, `CompatInput` and `CompatReport`; `null` means
>   undetermined, never empty (D15).
> - There is a **ninth verdict, `SCHEMA_INCOMPLETE`** (`populated === null && hasMigrationsTable`),
>   in `REFUSING_VERDICTS`, sitting between `DB_AHEAD` and `VIRGIN`. `VIRGIN`'s condition became
>   `!hasMigrationsTable && (populated === false || populated === null)`.
> - `rollbackPossible` is **`null` for `EQUAL`** and the **computed value for `VIRGIN`** (D16).
> - `migrations.sql()` is called inside a `try`/`catch`, because Task 1's implementation throws on
>   EACCES rather than returning null.
> - `isUndefinedTable` also matches a top-level `code === 'P2021'` (G6a) and no longer message-matches.
> - `DbState` no longer carries `applied`/`failed` — `buildReport` derives them from `rows`, which is
>   now `ORDER BY migration_name`.
>
> Tasks 3-6 below are written against the **post-fix** interfaces and are safe to execute as given.

**Files:**

- Create: `packages/backend/server/src/core/db-compat/db-state.ts`
- Create: `packages/backend/server/src/core/db-compat/compat.ts`
- Test: `packages/backend/server/src/core/db-compat/__tests__/compat.spec.ts`
- Test: `packages/backend/server/src/core/db-compat/__tests__/db-state.spec.ts`

`compat.ts` is pure, so the whole verdict table is tested without a database. `db-state.ts` is the
only part needing Postgres.

- [ ] **Step 1: Write the failing verdict tests**

Create `packages/backend/server/src/core/db-compat/__tests__/compat.spec.ts`:

```ts
import test from 'ava';

import { buildReport, type CompatInput } from '../compat';

const base: CompatInput = {
  migrations: {
    dir: '/app/migrations',
    names: ['m1', 'm2'],
    sql: (name: string) =>
      name === 'm2' ? 'DROP TABLE "x";' : 'CREATE TABLE "x" ();',
  },
  hasMigrationsTable: true,
  appliedRows: [
    { name: 'm1', finishedAt: new Date(), rolledBackAt: null },
    { name: 'm2', finishedAt: new Date(), rolledBackAt: null },
  ],
  populated: true,
  stamp: null,
  configuredDeploymentId: null,
};

test('EQUAL when applied matches known', t => {
  const report = buildReport(base);
  t.is(report.verdict, 'EQUAL');
  t.deepEqual(report.pending, []);
  t.true(report.rollbackPossible);
});

test('UNREADABLE when the migration set is missing', t => {
  const report = buildReport({ ...base, migrations: null });
  t.is(report.verdict, 'UNREADABLE');
  t.is(report.rollbackPossible, null);
});

test('VIRGIN when there is no migrations table and no data', t => {
  const report = buildReport({
    ...base,
    hasMigrationsTable: false,
    appliedRows: [],
    populated: false,
  });
  t.is(report.verdict, 'VIRGIN');
});

test('DB_BEHIND lists pending migrations with tiers', t => {
  const report = buildReport({
    ...base,
    appliedRows: [{ name: 'm1', finishedAt: new Date(), rolledBackAt: null }],
  });
  t.is(report.verdict, 'DB_BEHIND');
  t.deepEqual(
    report.pending.map(p => [p.name, p.tier]),
    [['m2', 'BLOCKING']]
  );
  t.false(report.rollbackPossible);
});

test('DB_BEHIND with only additive pending keeps rollback possible', t => {
  const report = buildReport({
    ...base,
    migrations: { ...base.migrations!, sql: () => 'CREATE TABLE "y" ();' },
    appliedRows: [{ name: 'm1', finishedAt: new Date(), rolledBackAt: null }],
  });
  t.is(report.verdict, 'DB_BEHIND');
  t.true(report.rollbackPossible);
});

test('an UNREADABLE pending migration fails closed, not open', t => {
  const report = buildReport({
    ...base,
    migrations: { ...base.migrations!, sql: () => null },
    appliedRows: [{ name: 'm1', finishedAt: new Date(), rolledBackAt: null }],
  });
  t.is(report.verdict, 'DB_BEHIND');
  t.is(report.pending[0].tier, 'BLOCKING');
  t.is(report.pending[0].hits[0].rule, 'unreadable-migration');
  // The whole point: a migration we cannot read must never report as safe.
  t.false(report.rollbackPossible);
});

test('DB_AHEAD when the database has migrations this binary lacks', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      ...base.appliedRows,
      { name: 'm3', finishedAt: new Date(), rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'DB_AHEAD');
  t.deepEqual(report.ahead, ['m3']);
});

test('DIVERGED when each side has what the other lacks', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      { name: 'm1', finishedAt: new Date(), rolledBackAt: null },
      { name: 'mX', finishedAt: new Date(), rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'DIVERGED');
  t.deepEqual(report.ahead, ['mX']);
  t.deepEqual(
    report.pending.map(p => p.name),
    ['m2']
  );
});

test('a rolled-back row does not count as applied and does not make the DB ahead', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      ...base.appliedRows,
      { name: 'm3', finishedAt: null, rolledBackAt: new Date() },
    ],
  });
  t.is(report.verdict, 'EQUAL');
  t.deepEqual(report.ahead, []);
});

test('MIGRATION_FAILED when a row is unfinished and not rolled back', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      { name: 'm1', finishedAt: new Date(), rolledBackAt: null },
      { name: 'm2', finishedAt: null, rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'MIGRATION_FAILED');
  t.deepEqual(report.failed, ['m2']);
});

test('IDENTITY_MISMATCH when the stamp names another deployment', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: 'prod-a',
    stamp: {
      deploymentId: 'prod-b',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'explicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
  });
  t.is(report.verdict, 'IDENTITY_MISMATCH');
  t.is(report.identity.kind, 'mismatch');
});

test('a matching stamp is EQUAL and reports identity match', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: 'prod-a',
    stamp: {
      deploymentId: 'prod-a',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'explicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
  });
  t.is(report.verdict, 'EQUAL');
  t.is(report.identity.kind, 'match');
});

test('a stamp with no configured id is unchecked, not a mismatch', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: null,
    stamp: {
      deploymentId: 'minted-uuid',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'implicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
  });
  t.is(report.verdict, 'EQUAL');
  t.is(report.identity.kind, 'unchecked');
});

test('identity mismatch outranks DB_AHEAD — the wrong database is the better message', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: 'prod-a',
    stamp: {
      deploymentId: 'prod-b',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'explicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
    appliedRows: [
      ...base.appliedRows,
      { name: 'm9', finishedAt: new Date(), rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'IDENTITY_MISMATCH');
});
```

- [ ] **Step 2: Run to verify failure**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/compat.spec.ts`

Expected: FAIL — unresolved import of `../compat`.

- [ ] **Step 3: Implement `identity.ts` types plus `compat.ts`**

First create `packages/backend/server/src/core/db-compat/identity.ts` with the types and the pure
evaluator only. The Prisma reads and writes are added in Task 3.

```ts
/**
 * `app_configs` id for the deployment stamp.
 *
 * The `$` prefix is deliberate and load-bearing. `ServerService.loadDbOverrides()`
 * merges every `app_configs` row into the runtime config tree, but `override()`
 * ignores unknown config modules — so an id whose first segment can never match
 * a registered module name is inert. See grounding G3 and design D6. Do not
 * change this to a dotted, module-shaped id.
 */
export const DEPLOYMENT_STAMP_ID = '$deployment';

export type AdoptionMode = 'fresh-install' | 'implicit' | 'explicit';

export interface BuildRef {
  version: string;
  buildSha: string;
}

export interface DeploymentStamp {
  deploymentId: string;
  adoptedAt: string;
  adoptionMode: AdoptionMode;
  adoptedBy: BuildRef;
  lastMigratedBy?: BuildRef & { at: string };
}

export type IdentityState =
  | { kind: 'absent' }
  | { kind: 'unchecked'; stamp: DeploymentStamp }
  | { kind: 'match'; stamp: DeploymentStamp }
  | { kind: 'mismatch'; stamp: DeploymentStamp; configured: string };

export function evaluateIdentity(
  stamp: DeploymentStamp | null,
  configured: string | null
): IdentityState {
  if (!stamp) {
    return { kind: 'absent' };
  }
  if (!configured) {
    return { kind: 'unchecked', stamp };
  }
  return stamp.deploymentId === configured
    ? { kind: 'match', stamp }
    : { kind: 'mismatch', stamp, configured };
}
```

At this point `identity.ts` is **pure** — types plus one function, no Prisma import. Task 3 adds
`readStamp` / `writeStamp` and the `@prisma/client` import then, so nothing here needs a stub.

Then create `packages/backend/server/src/core/db-compat/compat.ts`:

```ts
import { classifyDdl, type DdlHit, type DdlTier } from './classify';
import {
  evaluateIdentity,
  type DeploymentStamp,
  type IdentityState,
} from './identity';
import type { MigrationSet } from './migration-set';

export type Verdict =
  | 'VIRGIN'
  | 'EQUAL'
  | 'DB_BEHIND'
  | 'DB_AHEAD'
  | 'DIVERGED'
  | 'IDENTITY_MISMATCH'
  | 'MIGRATION_FAILED'
  | 'UNREADABLE';

export interface MigrationRow {
  name: string;
  finishedAt: Date | null;
  rolledBackAt: Date | null;
}

export interface PendingMigration {
  name: string;
  tier: DdlTier;
  hits: DdlHit[];
}

export interface CompatInput {
  migrations: MigrationSet | null;
  hasMigrationsTable: boolean;
  appliedRows: MigrationRow[];
  populated: boolean;
  stamp: DeploymentStamp | null;
  configuredDeploymentId: string | null;
}

export interface CompatReport {
  verdict: Verdict;
  reason: string;
  known: string[];
  applied: string[];
  pending: PendingMigration[];
  ahead: string[];
  failed: string[];
  /** null when the question does not apply (UNREADABLE, VIRGIN, refusals). */
  rollbackPossible: boolean | null;
  populated: boolean;
  identity: IdentityState;
}

/** Verdicts that must never proceed, at either enforcement point. */
export const REFUSING_VERDICTS: ReadonlySet<Verdict> = new Set<Verdict>([
  'DB_AHEAD',
  'DIVERGED',
  'IDENTITY_MISMATCH',
  'MIGRATION_FAILED',
]);

export function buildReport(input: CompatInput): CompatReport {
  const { migrations, hasMigrationsTable, appliedRows, populated, stamp } =
    input;
  const identity = evaluateIdentity(stamp, input.configuredDeploymentId);

  const known = migrations ? [...migrations.names] : [];
  const applied = appliedRows
    .filter(row => !row.rolledBackAt)
    .map(row => row.name)
    .sort();
  const failed = appliedRows
    .filter(row => !row.finishedAt && !row.rolledBackAt)
    .map(row => row.name)
    .sort();

  const knownSet = new Set(known);
  const appliedSet = new Set(applied);

  const ahead = applied.filter(name => !knownSet.has(name));
  const behind = known.filter(name => !appliedSet.has(name));

  const pending: PendingMigration[] = migrations
    ? behind.map(name => {
        const sql = migrations.sql(name);

        // `sql()` returns null when the file is absent or unreadable. Fail
        // CLOSED: a migration we cannot read must not be reported as additive,
        // which is what treating it as an empty string would do. `classifyDdl`
        // applies the same rule to SQL it cannot parse (its `unterminated`
        // flag forces BLOCKING), so both unreadable cases gate consistently.
        if (sql === null) {
          return {
            name,
            tier: 'BLOCKING' as const,
            hits: [
              {
                tier: 'BLOCKING' as const,
                rule: 'unreadable-migration',
                line: 0,
                statement: `${name}/migration.sql is missing or unreadable`,
              },
            ],
          };
        }

        const { tier, hits } = classifyDdl(sql);
        return { name, tier, hits };
      })
    : [];

  const rollbackPossible = pending.every(item => item.tier !== 'BLOCKING');

  const report = (
    verdict: Verdict,
    reason: string,
    rollback: boolean | null
  ): CompatReport => ({
    verdict,
    reason,
    known,
    applied,
    pending,
    ahead,
    failed,
    rollbackPossible: rollback,
    populated,
    identity,
  });

  // Order matters: the most specific and most actionable message wins.
  if (!migrations) {
    return report(
      'UNREADABLE',
      'the migrations directory could not be located, so compatibility cannot be determined',
      null
    );
  }

  if (failed.length > 0) {
    return report(
      'MIGRATION_FAILED',
      `a previous migration did not finish and was not rolled back: ${failed.join(', ')}`,
      null
    );
  }

  if (identity.kind === 'mismatch') {
    return report(
      'IDENTITY_MISMATCH',
      `this database belongs to deployment "${identity.stamp.deploymentId}" but this server is configured as "${identity.configured}"`,
      null
    );
  }

  if (ahead.length > 0 && behind.length > 0) {
    return report(
      'DIVERGED',
      `migration history has branched: the database has ${ahead.join(', ')} which this binary lacks, and is missing ${behind.join(', ')}`,
      null
    );
  }

  if (ahead.length > 0) {
    return report(
      'DB_AHEAD',
      `the database was migrated by a NEWER binary and carries ${ahead.join(', ')}; refusing to downgrade`,
      null
    );
  }

  if (!hasMigrationsTable && !populated) {
    return report(
      'VIRGIN',
      'no migration history and no data — a fresh install',
      null
    );
  }

  if (pending.length > 0) {
    return report(
      'DB_BEHIND',
      `${pending.length} migration(s) pending`,
      rollbackPossible
    );
  }

  return report('EQUAL', 'the database matches this binary', true);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/compat.spec.ts`

Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/backend/server/src/core/db-compat/compat.ts packages/backend/server/src/core/db-compat/identity.ts packages/backend/server/src/core/db-compat/__tests__/compat.spec.ts && git commit -m "feat(woven): database compatibility verdict engine (affine-tc6.2)"
```

- [ ] **Step 6: Write the failing db-state test**

Create `packages/backend/server/src/core/db-compat/__tests__/db-state.spec.ts`:

```ts
import { PrismaClient } from '@prisma/client';
import test from 'ava';

import { readDbState } from '../db-state';

const db = new PrismaClient();

test.before(async () => {
  await db.$connect();
});

test.after.always(async () => {
  await db.$disconnect();
});

test('readDbState reports the real migration history', async t => {
  const state = await readDbState(db);
  t.true(state.hasMigrationsTable);
  t.true(state.rows.length > 0);
  t.true(state.applied.length > 0);
  t.deepEqual(state.failed, []);
});

test('readDbState surfaces a missing table as hasMigrationsTable false, not a throw', async t => {
  // Bind an EMPTY schema via the connection URL's `?schema=`, not via
  // `SET search_path`. Prisma pools connections, so a bare SET may land on a
  // different session than the query that follows it — a flaky test. `?schema=`
  // is applied per connection, so it holds for every query this client makes.
  const SCRATCH = 'db_compat_scratch';
  await db.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${SCRATCH}"`);

  const url = new URL(process.env.DATABASE_URL as string);
  url.searchParams.set('schema', SCRATCH);
  const scratch = new PrismaClient({
    datasources: { db: { url: url.toString() } },
  });

  try {
    const state = await readDbState(scratch);
    // Neither _prisma_migrations nor users exists in the empty schema, so both
    // reads must degrade rather than throw.
    t.false(state.hasMigrationsTable);
    t.deepEqual(state.rows, []);
    t.false(state.populated);
  } finally {
    await scratch.$disconnect();
    await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCRATCH}" CASCADE`);
  }
});

test('readDbState reports populated from the user count', async t => {
  const state = await readDbState(db);
  const users = await db.user.count();
  t.is(state.populated, users > 0);
});
```

- [ ] **Step 7: Run to verify failure**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/db-state.spec.ts`

Expected: FAIL — unresolved import of `../db-state`.

- [ ] **Step 8: Implement `db-state.ts`**

Create `packages/backend/server/src/core/db-compat/db-state.ts`:

```ts
import type { PrismaClient } from '@prisma/client';

import type { MigrationRow } from './compat';

export interface DbState {
  hasMigrationsTable: boolean;
  rows: MigrationRow[];
  applied: string[];
  failed: string[];
  populated: boolean;
}

interface RawMigrationRow {
  migration_name: string;
  finished_at: Date | null;
  rolled_back_at: Date | null;
}

const UNDEFINED_TABLE = '42P01';

/**
 * Prisma Client's own error code for "the model's table does not exist", thrown
 * by model-based calls like `db.user.count()`. Distinct from the Postgres
 * SQLSTATE above, which is what a raw `$queryRaw` failure carries.
 *
 * Both shapes are needed, and this bit the first implementation: a `$queryRaw`
 * failure arrives with `meta.code === '42P01'`, but `user.count()` throws
 * `PrismaClientKnownRequestError` with a TOP-LEVEL `code === 'P2021'` and
 * `meta: { modelName, table }` — no `meta.code` at all. Handling only the
 * SQLSTATE makes the second path rethrow instead of degrading.
 */
const PRISMA_TABLE_NOT_FOUND = 'P2021';

function isUndefinedTable(error: unknown): boolean {
  if (!error || typeof error !== 'object') {
    return false;
  }
  if ((error as { code?: unknown }).code === PRISMA_TABLE_NOT_FOUND) {
    return true;
  }
  const meta = (error as { meta?: { code?: unknown } }).meta;
  if (meta && String(meta.code) === UNDEFINED_TABLE) {
    return true;
  }
  return String((error as { message?: unknown }).message ?? '').includes(
    UNDEFINED_TABLE
  );
}

/**
 * `_prisma_migrations` is Prisma's own bookkeeping table and has no model in
 * schema.prisma, so it can only be read raw. It is absent on a virgin database,
 * which is a normal state and must not throw. See grounding G6.
 */
export async function readDbState(db: PrismaClient): Promise<DbState> {
  let rows: MigrationRow[] = [];
  let hasMigrationsTable = true;

  try {
    const raw = await db.$queryRaw<RawMigrationRow[]>`
      SELECT migration_name, finished_at, rolled_back_at FROM _prisma_migrations
    `;
    rows = raw.map(row => ({
      name: row.migration_name,
      finishedAt: row.finished_at,
      rolledBackAt: row.rolled_back_at,
    }));
  } catch (error) {
    if (!isUndefinedTable(error)) {
      throw error;
    }
    hasMigrationsTable = false;
  }

  // A populated database is one with real content. User count is the same
  // signal `ServerService.initialized()` uses, kept deliberately so the two
  // agree about what "pre-existing" means (grounding G7).
  let populated = false;
  try {
    populated = (await db.user.count()) > 0;
  } catch (error) {
    if (!isUndefinedTable(error)) {
      throw error;
    }
  }

  return {
    hasMigrationsTable,
    rows,
    applied: rows
      .filter(row => !row.rolledBackAt)
      .map(row => row.name)
      .sort(),
    failed: rows
      .filter(row => !row.finishedAt && !row.rolledBackAt)
      .map(row => row.name)
      .sort(),
    populated,
  };
}
```

- [ ] **Step 9: Run to verify pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/db-state.spec.ts`

Expected: PASS, 3 tests. Requires the database from **Before you start**.

- [ ] **Step 10: Commit**

```bash
git add packages/backend/server/src/core/db-compat/db-state.ts packages/backend/server/src/core/db-compat/__tests__/db-state.spec.ts && git commit -m "feat(woven): read prisma migration history and populated state (affine-tc6.2)"
```

---

## Task 3: Identity stamp, env knobs, and the adoption gate

> **LANDED 2026-09-01 — the code blocks below are the PRE-REVIEW design; the committed source is
> the authority.** Review found a **showstopper**: the gate crashed on every fresh install, because
> it runs before `prisma migrate deploy` and `readStamp`/`writeStamp` both throw `P2021` against a
> database with no `app_configs`. Divergences (`c318be0684` → `e2a03f3045` → `9e72b37cdc` →
> `54935b778b`):
>
> - **`check()` is pure and a new `stamp()` records, run after migrations** (D17). `check()` no
>   longer takes a `mutate` option.
> - New shared `prisma-errors.ts` (`isUndefinedTable`, lifted out of `db-state.ts`); `readStamp`
>   degrades a missing `app_configs` to "no stamp".
> - `readStamp` returns **`{ stamp, corrupt }`**, `IdentityState` gains a `corrupt` arm, and
>   `CompatInput` gains an optional `stampCorrupt` — an unreadable stamp REFUSES rather than being
>   overwritten (D18).
> - `parseStamp` validates every field, not just two.
> - `decide()` treats `populated === false` as `fresh-install` (D19) and returns
>   `bootMayContinue` (D20).
> - `flag()` trims and lowercases; the adopt contract is `options.adopt === true || adoptRequested()`.

**Files:**

- Create: `packages/backend/server/src/core/db-compat/env.ts`
- Modify: `packages/backend/server/src/core/db-compat/identity.ts` (add the Prisma reads/writes)
- Create: `packages/backend/server/src/core/db-compat/service.ts`
- Create: `packages/backend/server/src/core/db-compat/index.ts`
- Test: `packages/backend/server/src/core/db-compat/__tests__/identity.spec.ts`
- Test: `packages/backend/server/src/core/db-compat/__tests__/service.spec.ts`

- [ ] **Step 1: Write the failing identity tests**

Create `packages/backend/server/src/core/db-compat/__tests__/identity.spec.ts`:

```ts
import { PrismaClient } from '@prisma/client';
import test from 'ava';
import { set } from 'lodash-es';

import { override } from '../../../base/config/register';
import {
  DEPLOYMENT_STAMP_ID,
  type DeploymentStamp,
  evaluateIdentity,
  readStamp,
  writeStamp,
} from '../identity';

const db = new PrismaClient();

test.before(async () => {
  await db.$connect();
});

test.beforeEach(async () => {
  await db.appConfig.deleteMany({ where: { id: DEPLOYMENT_STAMP_ID } });
});

test.after.always(async () => {
  await db.appConfig.deleteMany({ where: { id: DEPLOYMENT_STAMP_ID } });
  await db.$disconnect();
});

const stamp = (deploymentId: string): DeploymentStamp => ({
  deploymentId,
  adoptedAt: '2026-01-01T00:00:00.000Z',
  adoptionMode: 'explicit',
  adoptedBy: { version: '0.27.0', buildSha: 'abc1234' },
});

test('readStamp returns null when absent', async t => {
  t.is(await readStamp(db), null);
});

test('writeStamp then readStamp round-trips', async t => {
  await writeStamp(db, stamp('prod-a'));
  const read = await readStamp(db);
  t.is(read?.deploymentId, 'prod-a');
  t.is(read?.adoptionMode, 'explicit');
});

test('writeStamp is an upsert, not a duplicate-key error', async t => {
  await writeStamp(db, stamp('prod-a'));
  await writeStamp(db, { ...stamp('prod-a'), adoptionMode: 'implicit' });
  t.is((await readStamp(db))?.adoptionMode, 'implicit');
  t.is(await db.appConfig.count({ where: { id: DEPLOYMENT_STAMP_ID } }), 1);
});

test('readStamp returns null rather than throwing on a malformed row', async t => {
  await db.appConfig.create({
    data: { id: DEPLOYMENT_STAMP_ID, value: { nope: true } },
  });
  t.is(await readStamp(db), null);
});

// Tests the ACTUAL mechanism from grounding G3 rather than booting a module and
// hoping loadDbOverrides() ran — an assertion that could pass vacuously.
// `override()` ignores unknown config modules, which is the single property that
// makes a `$`-prefixed app_configs id inert. If this breaks, D6 is invalid and
// the stamp is leaking into runtime config.
test('override() ignores the $deployment key entirely (grounding G3)', t => {
  const config = { auth: { allowSignup: true } } as unknown as AppConfig;

  override(config, {
    [DEPLOYMENT_STAMP_ID]: { deploymentId: 'prod-a' },
  } as unknown as DeepPartial<AppConfig>);

  t.false(
    DEPLOYMENT_STAMP_ID in (config as unknown as Record<string, unknown>)
  );
  t.deepEqual(config, { auth: { allowSignup: true } } as unknown as AppConfig);
});

test('a real loadDbOverrides pass leaves the stamp out of the config tree', async t => {
  await writeStamp(db, stamp('prod-a'));

  // Mirrors ServerService.loadDbOverrides(): read every row, set() it by id,
  // then hand the result to override().
  const rows = await db.appConfig.findMany();
  t.true(
    rows.some(row => row.id === DEPLOYMENT_STAMP_ID),
    'stamp row must exist'
  );

  const overrides: Record<string, unknown> = {};
  for (const row of rows) {
    set(overrides, row.id, row.value);
  }
  const config = { auth: { allowSignup: true } } as unknown as AppConfig;
  override(config, overrides as DeepPartial<AppConfig>);

  t.false(
    DEPLOYMENT_STAMP_ID in (config as unknown as Record<string, unknown>)
  );
});

test('evaluateIdentity classifies absent, unchecked, match and mismatch', t => {
  t.is(evaluateIdentity(null, 'prod-a').kind, 'absent');
  t.is(evaluateIdentity(stamp('prod-a'), null).kind, 'unchecked');
  t.is(evaluateIdentity(stamp('prod-a'), 'prod-a').kind, 'match');
  t.is(evaluateIdentity(stamp('prod-a'), 'prod-b').kind, 'mismatch');
});
```

- [ ] **Step 2: Run to verify failure**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/identity.spec.ts`

Expected: FAIL — `readStamp` / `writeStamp` are not exported implementations.

- [ ] **Step 3: Implement `env.ts` and finish `identity.ts`**

Create `packages/backend/server/src/core/db-compat/env.ts`:

```ts
/**
 * These three knobs are read from `process.env` DIRECTLY and are deliberately
 * NOT registered with `defineModuleConfig` (design D13).
 *
 * A config item with an `env:` binding is also overridable from the
 * `app_configs` table. For a safety control that is backwards: a database row
 * could switch off the guard whose whole job is to judge that database. Direct
 * env reads also keep the boot guard independent of config load order.
 *
 * Consequence, intended: these do not appear in the admin UI and cannot be
 * changed at runtime.
 */

function flag(name: string): boolean {
  const value = process.env[name];
  return value === '1' || value?.toLowerCase() === 'true';
}

/** Externally-asserted deployment identity. Without it, identity is unchecked. */
export function configuredDeploymentId(): string | null {
  const value = process.env.AFFINE_DEPLOYMENT_ID?.trim();
  return value ? value : null;
}

/** Operator asserts a pre-existing database is intended, even across a contract. */
export function adoptRequested(): boolean {
  return flag('AFFINE_DB_ADOPT');
}

/**
 * Incident bypass. Skips the BOOT guard only — never the predeploy gate — and
 * every skipped boot logs at ERROR (design D11).
 */
export function bootGuardBypassed(): boolean {
  return flag('AFFINE_DB_COMPAT_SKIP');
}

export function buildRef(): { version: string; buildSha: string } {
  return {
    version: env.version,
    buildSha: process.env.GITHUB_SHA ?? 'unknown',
  };
}
```

Now edit `identity.ts` — it is pure types plus `evaluateIdentity` after Task 2. Add the Prisma
import at the top and append the real implementations:

```ts
import { type Prisma, type PrismaClient } from '@prisma/client';
```

```ts
function parseStamp(value: unknown): DeploymentStamp | null {
  if (!value || typeof value !== 'object') {
    return null;
  }
  const candidate = value as Partial<DeploymentStamp>;
  if (typeof candidate.deploymentId !== 'string' || !candidate.deploymentId) {
    return null;
  }
  if (typeof candidate.adoptedAt !== 'string') {
    return null;
  }
  return candidate as DeploymentStamp;
}

export async function readStamp(
  db: PrismaClient
): Promise<DeploymentStamp | null> {
  const row = await db.appConfig.findUnique({
    where: { id: DEPLOYMENT_STAMP_ID },
  });
  return row ? parseStamp(row.value) : null;
}

export async function writeStamp(
  db: PrismaClient,
  stamp: DeploymentStamp
): Promise<void> {
  const value = stamp as unknown as Prisma.InputJsonValue;
  await db.appConfig.upsert({
    where: { id: DEPLOYMENT_STAMP_ID },
    update: { value },
    create: { id: DEPLOYMENT_STAMP_ID, value },
  });
}
```

- [ ] **Step 4: Run to verify pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/identity.spec.ts`

Expected: PASS, 7 tests. The two inertness tests are the important ones — if either fails, the
`$` prefix has been changed or `override()` no longer ignores unknown config modules, and D6 needs
revisiting before anything else proceeds.

- [ ] **Step 5: Commit**

```bash
git add packages/backend/server/src/core/db-compat/env.ts packages/backend/server/src/core/db-compat/identity.ts packages/backend/server/src/core/db-compat/__tests__/identity.spec.ts && git commit -m "feat(woven): deployment identity stamp and env knobs (affine-tc6.3)"
```

- [ ] **Step 6: Write the failing service tests**

Create `packages/backend/server/src/core/db-compat/__tests__/service.spec.ts`:

```ts
import test from 'ava';

import { decide } from '../service';
import type { CompatReport } from '../compat';

// `rollbackPossible: null` for EQUAL is the real contract (D16): the engine
// classifies only PENDING migrations, so it has no basis to claim rollback
// safety when nothing is pending.
const report = (over: Partial<CompatReport>): CompatReport => ({
  verdict: 'EQUAL',
  reason: 'ok',
  known: ['m1'],
  applied: ['m1'],
  pending: [],
  ahead: [],
  failed: [],
  rollbackPossible: null,
  populated: true,
  identity: { kind: 'absent' },
  ...over,
});

test('EQUAL with no stamp on a populated database auto-adopts implicitly', t => {
  const decision = decide(report({}), { adopt: false });
  t.true(decision.ok);
  t.is(decision.adopt, 'implicit');
});

test('VIRGIN adopts as a fresh install', t => {
  const decision = decide(report({ verdict: 'VIRGIN', populated: false }), {
    adopt: false,
  });
  t.true(decision.ok);
  t.is(decision.adopt, 'fresh-install');
});

test('DB_BEHIND with only additive pending auto-adopts', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'EXPAND', hits: [] }],
      rollbackPossible: true,
    }),
    { adopt: false }
  );
  t.true(decision.ok);
  t.is(decision.adopt, 'implicit');
});

test('DB_BEHIND with a BLOCKING pending migration REFUSES without the flag', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'BLOCKING', hits: [] }],
      rollbackPossible: false,
    }),
    { adopt: false }
  );
  t.false(decision.ok);
  t.regex(decision.refusal!, /AFFINE_DB_ADOPT/);
});

test('the same case PROCEEDS with the flag, recorded as explicit', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'BLOCKING', hits: [] }],
      rollbackPossible: false,
    }),
    { adopt: true }
  );
  t.true(decision.ok);
  t.is(decision.adopt, 'explicit');
});

test('an already-stamped database needs no adoption', t => {
  const decision = decide(
    report({
      identity: {
        kind: 'match',
        stamp: {
          deploymentId: 'prod-a',
          adoptedAt: '2026-01-01T00:00:00.000Z',
          adoptionMode: 'explicit',
          adoptedBy: { version: '0.27.0', buildSha: 'abc' },
        },
      },
    }),
    { adopt: false }
  );
  t.true(decision.ok);
  t.is(decision.adopt, null);
});

test('a BLOCKING pending migration on an ALREADY-adopted database does not re-gate', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'BLOCKING', hits: [] }],
      rollbackPossible: false,
      identity: {
        kind: 'unchecked',
        stamp: {
          deploymentId: 'minted',
          adoptedAt: '2026-01-01T00:00:00.000Z',
          adoptionMode: 'implicit',
          adoptedBy: { version: '0.27.0', buildSha: 'abc' },
        },
      },
    }),
    { adopt: false }
  );
  t.true(decision.ok);
  t.is(decision.adopt, null);
});

// Every member of REFUSING_VERDICTS, including the ninth verdict added in T2.
// Keep this list in sync with `REFUSING_VERDICTS` in compat.ts — a verdict that
// refuses there but is missing here is an untested refusal path.
for (const verdict of [
  'DB_AHEAD',
  'DIVERGED',
  'IDENTITY_MISMATCH',
  'MIGRATION_FAILED',
  'SCHEMA_INCOMPLETE',
] as const) {
  test(`${verdict} always refuses, flag or not`, t => {
    t.false(decide(report({ verdict }), { adopt: false }).ok);
    t.false(decide(report({ verdict }), { adopt: true }).ok);
  });
}

test('UNREADABLE refuses when mutating and is reported as undetermined', t => {
  const decision = decide(
    report({ verdict: 'UNREADABLE', rollbackPossible: null }),
    {
      adopt: false,
    }
  );
  t.false(decision.ok);
});
```

- [ ] **Step 7: Run to verify failure**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/service.spec.ts`

Expected: FAIL — unresolved import of `../service`.

- [ ] **Step 8: Implement `service.ts` and `index.ts`**

Create `packages/backend/server/src/core/db-compat/service.ts`:

```ts
import { randomUUID } from 'node:crypto';

import { Injectable, Logger } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';

import {
  buildReport,
  type CompatReport,
  REFUSING_VERDICTS,
  type Verdict,
} from './compat';
import { readDbState } from './db-state';
import { adoptRequested, buildRef, configuredDeploymentId } from './env';
import {
  type AdoptionMode,
  type DeploymentStamp,
  readStamp,
  writeStamp,
} from './identity';
import { loadMigrationSet } from './migration-set';

export interface CompatDecision {
  report: CompatReport;
  ok: boolean;
  refusal: string | null;
  /** The adoption to record, or null when nothing needs recording. */
  adopt: AdoptionMode | null;
}

/**
 * Pure decision function over a report. Separated from the service so the whole
 * adoption gate is testable without a database.
 */
export function decide(
  report: CompatReport,
  options: { adopt: boolean }
): CompatDecision {
  const verdict: Verdict = report.verdict;

  if (REFUSING_VERDICTS.has(verdict)) {
    return { report, ok: false, refusal: report.reason, adopt: null };
  }

  if (verdict === 'UNREADABLE') {
    return { report, ok: false, refusal: report.reason, adopt: null };
  }

  const alreadyStamped = report.identity.kind !== 'absent';
  if (alreadyStamped) {
    return { report, ok: true, refusal: null, adopt: null };
  }

  if (verdict === 'VIRGIN') {
    return { report, ok: true, refusal: null, adopt: 'fresh-install' };
  }

  // Unstamped and populated: this is the adoption decision (design D3).
  const blocking = report.pending.filter(item => item.tier === 'BLOCKING');
  if (blocking.length > 0 && !options.adopt) {
    return {
      report,
      ok: false,
      refusal:
        `refusing to adopt a pre-existing database across ${blocking.length} CONTRACTING migration(s) ` +
        `(${blocking.map(item => item.name).join(', ')}) — applying them makes image rollback ` +
        `impossible. Confirm with AFFINE_DB_ADOPT=1 (or --adopt) once a VERIFIED-RESTORABLE ` +
        `backup exists.`,
      adopt: null,
    };
  }

  return {
    report,
    ok: true,
    refusal: null,
    adopt: options.adopt ? 'explicit' : 'implicit',
  };
}

@Injectable()
export class DbCompatService {
  private readonly logger = new Logger(DbCompatService.name);

  constructor(private readonly db: PrismaClient) {}

  async report(): Promise<CompatReport> {
    const migrations = loadMigrationSet();
    const state = await readDbState(this.db);
    const stamp = await readStamp(this.db);

    return buildReport({
      migrations,
      hasMigrationsTable: state.hasMigrationsTable,
      appliedRows: state.rows,
      populated: state.populated,
      stamp,
      configuredDeploymentId: configuredDeploymentId(),
    });
  }

  /**
   * Classify, and when `mutate` is set, record the adoption decision.
   * `mutate: false` is the read-only boot path.
   */
  async check(options: {
    mutate: boolean;
    adopt?: boolean;
  }): Promise<CompatDecision> {
    const report = await this.report();
    const decision = decide(report, {
      adopt: options.adopt ?? adoptRequested(),
    });

    if (decision.ok && decision.adopt && options.mutate) {
      await this.recordAdoption(decision.adopt);
    }

    return decision;
  }

  private async recordAdoption(mode: AdoptionMode): Promise<void> {
    const configured = configuredDeploymentId();
    const deploymentId = configured ?? randomUUID();
    const ref = buildRef();
    const now = new Date().toISOString();

    const stamp: DeploymentStamp = {
      deploymentId,
      adoptedAt: now,
      adoptionMode: mode,
      adoptedBy: ref,
      lastMigratedBy: { ...ref, at: now },
    };

    await writeStamp(this.db, stamp);

    if (mode === 'fresh-install') {
      this.logger.log(
        `initialized a fresh database as deployment ${deploymentId}`
      );
    } else {
      this.logger.warn(
        `ADOPTING pre-existing database (${mode}) as deployment ${deploymentId}`
      );
    }

    if (!configured) {
      this.logger.warn(
        `deployment identity minted as ${deploymentId}; set AFFINE_DEPLOYMENT_ID=${deploymentId} ` +
          `to enable wrong-database detection`
      );
    }
  }
}
```

Create `packages/backend/server/src/core/db-compat/index.ts`.

**Grow this file incrementally — do not stub what does not exist yet.** `render.ts` arrives in
Task 4 and `guard.ts` in Task 5; each adds its own export then. Creating empty stubs and commenting
out imports would leave dead code in the tree between tasks, and commented-out code is the kind of
thing that survives by accident.

```ts
import { Module } from '@nestjs/common';

import { DbCompatService } from './service';

/**
 * Service only — safe to import anywhere, including the minimal CLI context.
 *
 * The boot guard deliberately lives in a SEPARATE module added in Task 5
 * (`DbCompatGuardModule`), which only `AppModule` may import. See design
 * D10/D14: the CLI imports `FunctionalityModules`, so a guard reachable from
 * there would make `db check` refuse to run in exactly the situation it exists
 * for.
 */
@Module({
  providers: [DbCompatService],
  exports: [DbCompatService],
})
export class DbCompatModule {}

export { classifyDdl, type DdlTier } from './classify';
export { type CompatReport, type Verdict } from './compat';
export { type CompatDecision, DbCompatService } from './service';
```

- [ ] **Step 9: Run to verify pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/service.spec.ts`

Expected: PASS, 13 tests (the `for` loop contributes 5, one per refusing verdict).

- [ ] **Step 10: Commit**

```bash
git add packages/backend/server/src/core/db-compat/ && git commit -m "feat(woven): adoption gate and db-compat service (affine-tc6.3)"
```

---

## Task 4: The CLI — `db status` and `db check`

**Files:**

- Create: `packages/backend/server/src/core/db-compat/render.ts`
- Create: `packages/backend/server/src/core/db-compat/cli-module.ts`
- Create: `packages/backend/server/src/core/db-compat/__tests__/render.spec.ts`
- Modify: `packages/backend/server/src/core/db-compat/index.ts` (one added export)
- Modify: `packages/backend/server/src/cli.ts`
- Modify: `scripts/woven-patch-manifest.md` (first row)

- [ ] **Step 1: Write the failing render test**

Create `packages/backend/server/src/core/db-compat/__tests__/render.spec.ts`:

```ts
import test from 'ava';

import type { CompatReport } from '../compat';
import { renderReport } from '../render';

// `rollbackPossible: null` on EQUAL is the real contract (D16) — the engine
// classifies only pending migrations, so with nothing pending it has no basis
// for a claim either way.
const report = (over: Partial<CompatReport>): CompatReport => ({
  verdict: 'EQUAL',
  reason: 'the database matches this binary',
  known: ['m1'],
  applied: ['m1'],
  pending: [],
  ahead: [],
  failed: [],
  rollbackPossible: null,
  populated: true,
  identity: { kind: 'absent' },
  ...over,
});

test('renders the verdict and the rollback answer explicitly', t => {
  const text = renderReport(report({}));
  t.regex(text, /verdict:\s+EQUAL/);
  t.regex(text, /rollback after applying:\s+UNKNOWN/);
});

test('VIRGIN reports N/A rather than a computed IMPOSSIBLE', t => {
  // On a fresh install every migration is pending and some are BLOCKING, so the
  // computed answer is always false — but there is no prior deployment to roll
  // back to, and printing IMPOSSIBLE on the one unambiguously safe path is
  // alarming and useless.
  const text = renderReport(
    report({
      verdict: 'VIRGIN',
      populated: false,
      rollbackPossible: false,
      pending: [{ name: 'm1', tier: 'BLOCKING', hits: [] }],
    })
  );
  t.regex(text, /verdict:\s+VIRGIN/);
  t.regex(text, /rollback after applying:\s+N\/A/);
  t.notRegex(text, /IMPOSSIBLE/);
});

test('names each pending migration with its tier', t => {
  const text = renderReport(
    report({
      verdict: 'DB_BEHIND',
      rollbackPossible: false,
      pending: [
        {
          name: 'm2',
          tier: 'BLOCKING',
          hits: [
            {
              tier: 'BLOCKING',
              rule: 'drop-table',
              line: 3,
              statement: 'DROP TABLE "x"',
            },
          ],
        },
        { name: 'm3', tier: 'EXPAND', hits: [] },
      ],
    })
  );
  t.regex(text, /BLOCKING\s+m2/);
  t.regex(text, /EXPAND\s+m3/);
  t.regex(text, /drop-table/);
  t.regex(text, /rollback after applying:\s+IMPOSSIBLE/);
});

test('reports an undetermined rollback answer as UNKNOWN, never as POSSIBLE', t => {
  const text = renderReport(
    report({ verdict: 'DB_AHEAD', rollbackPossible: null, ahead: ['m9'] })
  );
  t.regex(text, /rollback after applying:\s+UNKNOWN/);
  t.notRegex(text, /POSSIBLE/);
});

test('states when identity is unchecked', t => {
  const text = renderReport(report({}));
  t.regex(text, /identity:\s+not stamped/);
});

test('a corrupt stamp renders as unreadable, never as "not stamped"', t => {
  // D18: a stamp row that exists but cannot be parsed refuses rather than being
  // silently overwritten. Rendering it as "not stamped" would tell the operator
  // the opposite of what happened.
  const text = renderReport(
    report({ verdict: 'IDENTITY_MISMATCH', identity: { kind: 'corrupt' } })
  );
  t.regex(text, /identity:\s+PRESENT BUT UNREADABLE/);
  t.notRegex(text, /not stamped/);
});

test('a long statement is excerpted and says how much was dropped', t => {
  const long = `ALTER TABLE "t" ${'DROP COLUMN "c", '.repeat(40)}DROP COLUMN "last"`;
  const text = renderReport(
    report({
      verdict: 'DB_BEHIND',
      rollbackPossible: false,
      pending: [
        {
          name: 'm2',
          tier: 'BLOCKING',
          hits: [
            { tier: 'BLOCKING', rule: 'drop-column', line: 3, statement: long },
          ],
        },
      ],
    })
  );
  t.regex(text, /\+\d+ chars/);
  // The classifier keeps the full statement; truncation must not be silent.
  t.false(text.includes(long));
});
```

- [ ] **Step 2: Run to verify failure**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/render.spec.ts`

Expected: FAIL — unresolved import of `../render` (the file does not exist yet).

- [ ] **Step 3: Implement `render.ts`**

Create `packages/backend/server/src/core/db-compat/render.ts`:

```ts
import type { CompatReport } from './compat';

const EXCERPT_WIDTH = 160;

/**
 * Trim a statement for display.
 *
 * `DdlHit.statement` carries the FULL collapsed statement — the classifier
 * deliberately does not truncate, because a blind head-slice can cut off the
 * very DDL that matched (measured: one corpus migration reports `retype-column`
 * while its first 160 chars show only `DROP COLUMN`s). Display width is this
 * module's concern, so keep the head but always say how much was dropped.
 */
function excerpt(statement: string): string {
  if (statement.length <= EXCERPT_WIDTH) {
    return statement;
  }
  const dropped = statement.length - EXCERPT_WIDTH;
  return `${statement.slice(0, EXCERPT_WIDTH)}… (+${dropped} chars)`;
}

/**
 * `VIRGIN` deserves different wording. On a fresh install every migration is
 * pending, and 17 of this repo's 117 are BLOCKING, so the computed answer is
 * always `false` — the renderer would print "rollback IMPOSSIBLE" on the one
 * path that is unambiguously safe. That is honest (an older image genuinely
 * cannot read the resulting schema) but alarming and useless, since there is no
 * prior deployment to roll back TO.
 */
function rollbackLine(report: CompatReport): string {
  if (report.verdict === 'VIRGIN') {
    return 'N/A (fresh install — nothing to roll back to)';
  }
  if (report.rollbackPossible === null) {
    return 'UNKNOWN';
  }
  return report.rollbackPossible ? 'POSSIBLE' : 'IMPOSSIBLE';
}

/**
 * All FIVE `IdentityState` arms. `corrupt` was added in T3 (D18) — a stamp row
 * that exists but cannot be parsed refuses rather than reading as absent, so it
 * must render as its own thing and never be confused with "not stamped".
 */
function identityLine(report: CompatReport): string {
  const identity = report.identity;
  switch (identity.kind) {
    case 'absent':
      return 'not stamped';
    case 'corrupt':
      return 'PRESENT BUT UNREADABLE — refusing rather than overwriting it';
    case 'unchecked':
      return `${identity.stamp.deploymentId} (unchecked — AFFINE_DEPLOYMENT_ID is not set)`;
    case 'match':
      return `${identity.stamp.deploymentId} (matches AFFINE_DEPLOYMENT_ID)`;
    case 'mismatch':
      return `${identity.stamp.deploymentId} != configured ${identity.configured}`;
  }
}

export function renderReport(report: CompatReport): string {
  const lines: string[] = [
    `verdict:                  ${report.verdict}`,
    `reason:                   ${report.reason}`,
    `migrations known:         ${report.known.length}`,
    `migrations applied:       ${report.applied.length}`,
    `identity:                 ${identityLine(report)}`,
    `rollback after applying:  ${rollbackLine(report)}`,
  ];

  if (report.ahead.length > 0) {
    lines.push(
      '',
      `in database but NOT in this binary (${report.ahead.length}):`
    );
    for (const name of report.ahead) {
      lines.push(`  ${name}`);
    }
  }

  if (report.failed.length > 0) {
    lines.push('', `unfinished, not rolled back (${report.failed.length}):`);
    for (const name of report.failed) {
      lines.push(`  ${name}`);
    }
  }

  if (report.pending.length > 0) {
    lines.push('', `pending (${report.pending.length}):`);
    for (const item of report.pending) {
      lines.push(`  ${item.tier.padEnd(11)} ${item.name}`);
      for (const hit of item.hits) {
        lines.push(`    L${hit.line} ${hit.rule}: ${excerpt(hit.statement)}`);
      }
    }
  }

  return lines.join('\n');
}
```

- [ ] **Step 4: Run to verify pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/render.spec.ts`

Expected: PASS, 7 tests.

- [ ] **Step 5: Add the `renderReport` export to `index.ts`**

`index.ts` grows one export per task; nothing was stubbed. Append:

```ts
export { renderReport } from './render';
```

- [ ] **Step 6: Add `withMinimalApp` and the `db` command group to `cli.ts`**

First create the module the minimal context boots, at
`packages/backend/server/src/core/db-compat/cli-module.ts`:

```ts
import { Module } from '@nestjs/common';

import { ConfigModule } from '../../base/config';
import { PrismaModule } from '../../base/prisma';
import { DbCompatModule } from './index';

/**
 * A deliberately tiny context: config + prisma + the compat service.
 *
 * `CliAppModule` pulls in all of `FunctionalityModules` plus `IndexerModule`, so
 * a safety gate standing on it could fail for Redis or Manticore reasons and
 * mask a database verdict. See design D7 and grounding G8. Note this imports
 * `DbCompatModule` (service only), never `DbCompatGuardModule` — D14.
 */
@Module({ imports: [ConfigModule, PrismaModule, DbCompatModule] })
export class DbCompatCliModule {}
```

Now in `packages/backend/server/src/cli.ts`, add these imports beside the existing ones:

```ts
import { DbCompatService, renderReport } from './core/db-compat';
import { DbCompatCliModule } from './core/db-compat/cli-module';
```

Add this helper directly after the existing `withCliApp` function — it is the same shape as
`withCliApp`, differing only in which module it boots:

```ts
async function withMinimalApp(
  logger: Logger,
  callback: (app: INestApplicationContext) => Promise<void>
) {
  const app = await NestFactory.createApplicationContext(DbCompatCliModule, {
    logger,
  });

  try {
    await callback(app);
  } finally {
    await app.close();
  }
}
```

Then register the commands inside `buildProgram`, before `return program;`:

```ts
const dbCommand = program
  .command('db')
  .description('database compatibility and adoption');

dbCommand
  .command('status')
  .description(
    'report migration compatibility, pending migrations and rollback safety'
  )
  .option('--json', 'emit the raw report as JSON')
  .action(async (options: { json?: boolean }) => {
    await withMinimalApp(logger, async app => {
      const report = await app.get(DbCompatService).report();
      // Written to stdout, not the logger: this is a report an operator reads
      // or a machine parses, not a log line.
      process.stdout.write(
        (options.json
          ? JSON.stringify(report, null, 2)
          : renderReport(report)) + '\n'
      );
    });
  });

dbCommand
  .command('check')
  .description(
    'gate: exit non-zero unless this database is safe for this binary to migrate'
  )
  .option(
    '--adopt',
    'confirm a pre-existing database is intended, even across a contract'
  )
  .action(async (options: { adopt?: boolean }) => {
    await withMinimalApp(logger, async app => {
      const decision = await app
        .get(DbCompatService)
        .check({ adopt: options.adopt });

      process.stdout.write(renderReport(decision.report) + '\n');

      if (!decision.ok) {
        logger.error(
          `database compatibility check FAILED: ${decision.refusal}`
        );
        process.exitCode = 1;
        return;
      }

      logger.log(
        `database compatibility check passed (${decision.report.verdict})`
      );
    });
  });

// Separate from `check` because the stamp lives in `app_configs`, which does not
// exist on a fresh install until `prisma migrate deploy` has run — and the gate
// must run BEFORE that to be worth anything. See D17. Idempotent, so the
// predeploy script can call it unconditionally on every deploy.
dbCommand
  .command('stamp')
  .description('record the deployment stamp; run AFTER migrations. Idempotent.')
  .option('--adopt', 'record the adoption as explicit rather than implicit')
  .action(async (options: { adopt?: boolean }) => {
    await withMinimalApp(logger, async app => {
      await app.get(DbCompatService).stamp({ adopt: options.adopt });
    });
  });
```

Two deliberate asymmetries with `check`:

- **`--adopt` is accepted here too**, using the same `options.adopt === true || adoptRequested()`
  contract as `check`. The automated caller is the predeploy initContainer, which reaches
  `AFFINE_DB_ADOPT` through the chart's `extraEnv` and cannot be given argv — but an operator
  running `db check --adopt` manually must not have their consent recorded as `implicit`. That
  record is the bead's central ask, so the flag has to reach the command that writes it.
- **No exit-code handling.** `stamp()` declines to write when the verdict refuses and logs why.
  It does not need to gate anything, because `check` already did — before any migration ran.

- [ ] **Step 7: Verify the CLI end to end against the real database**

The `data-migration` script is just `cross-env NODE_ENV=development SERVER_FLAVOR=script r ./src/index.ts`
— the dev entry point to the same CLI. Its name is historical; it takes any subcommand. Using it
avoids a full rspack bundle build, which the `cli` script would require.

Run: `yarn workspace @affine/server data-migration db status`

Expected: a report whose verdict is `EQUAL` against a migrated development database, an
`identity: not stamped` line on first run, and `rollback after applying: UNKNOWN` — **not**
`POSSIBLE`. `EQUAL` reports `null` by design (D16): with nothing pending, the engine has no basis
to claim rollback safety, and it never classifies already-applied migrations.

Run: `yarn workspace @affine/server data-migration db check`

Expected: exit code 0 and **no adoption warnings at all** — `check` writes nothing since D17.
Confirm the exit code and that the stamp was not created:

```bash
yarn workspace @affine/server data-migration db check; echo "exit=$?"
```

```bash
docker exec affine_dev_services-postgres-1 psql -U affine -d affine -tAc "SELECT count(*) FROM app_configs WHERE id = '\$deployment';"
```

Expected: `exit=0` and a count of **0**. A non-zero count means `check` is mutating, which breaks
its contract.

Now the recording step:

```bash
yarn workspace @affine/server data-migration db stamp
```

Expected on the first run: an `ADOPTING pre-existing database (implicit)` warning and a
`deployment identity minted as <uuid>` warning. Run it a second time — expected: **neither
warning**, because the stamp exists and `decide()` returns `adopt: null`; only `lastMigratedBy`
moves. That idempotency is what lets the initContainer call it unconditionally on every deploy.

Verify the id in the log matches the id in the database (D22 — the loser of a concurrent stamp
used to log an id the database did not hold, and following that log bricked the deployment):

```bash
docker exec affine_dev_services-postgres-1 psql -U affine -d affine -tAc "SELECT value->>'deploymentId', value->>'adoptionMode' FROM app_configs WHERE id = '\$deployment';"
```

Clean up so the shared development database is left as you found it:

```bash
docker exec affine_dev_services-postgres-1 psql -U affine -d affine -c "DELETE FROM app_configs WHERE id = '\$deployment';"
```

- [ ] **Step 8: Add the `cli.ts` manifest row**

In `scripts/woven-patch-manifest.md`, add a row to the "Diverged upstream-owned files" table:

| File                                 | Category     | Why                                                                                                                                                                                                                                                                                                                                                                | Delete when                                         |
| ------------------------------------ | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------- |
| `packages/backend/server/src/cli.ts` | **ADDITIVE** | Adds a `db` command group (`db status`, `db check`, `db stamp`) and a `withMinimalApp` helper that boots a config+prisma-only context, for the `affine-tc6` database-compatibility gate. Pure addition — no existing command or the shared `withCliApp` is touched, so it is low-conflict on upstream merges. Fork-owned logic all lives in `src/core/db-compat/`. | upstream grows its own migration-compatibility gate |

- [ ] **Step 9: Verify the manifest guard is clean**

Run: `scripts/woven-manifest-guard.sh`

Expected: exit 0. If it names `src/cli.ts`, the row's path does not match exactly.

- [ ] **Step 10: Commit**

```bash
git add packages/backend/server/src/core/db-compat/ packages/backend/server/src/cli.ts scripts/woven-patch-manifest.md && git commit -m "feat(woven): db status/check CLI on a minimal context (affine-tc6.4)"
```

---

## Task 5: Enforcement — boot guard and predeploy gate

**Files:**

- Create: `packages/backend/server/src/core/db-compat/guard.ts`
- Modify: `packages/backend/server/src/app.module.ts`
- Modify: `packages/backend/server/scripts/self-host-predeploy.js`
- Modify: `scripts/woven-patch-manifest.md` (two more rows)
- Test: `packages/backend/server/src/core/db-compat/__tests__/guard.spec.ts`

- [ ] **Step 1: Write the failing guard tests**

Create `packages/backend/server/src/core/db-compat/__tests__/guard.spec.ts`:

```ts
import { Logger } from '@nestjs/common';
import test from 'ava';

import type { CompatDecision } from '../service';
import { enforce } from '../guard';

// `bootMayContinue` is the field the guard keys on (D20). It is true for every
// `ok` decision and, uniquely among refusals, for UNREADABLE.
const decision = (
  ok: boolean,
  verdict = 'DB_AHEAD',
  bootMayContinue = ok
): CompatDecision => ({
  ok,
  refusal: ok ? null : 'the database was migrated by a NEWER binary',
  adopt: null,
  bootMayContinue,
  report: {
    verdict: verdict as never,
    reason: 'r',
    known: [],
    applied: [],
    pending: [],
    ahead: ['m9'],
    failed: [],
    rollbackPossible: null,
    populated: true,
    identity: { kind: 'absent' },
  },
});

const collect = () => {
  const errors: string[] = [];
  const logger = {
    error: (m: string) => errors.push(m),
    log: () => {},
  } as unknown as Logger;
  return { logger, errors };
};

test('a passing decision does not throw', t => {
  const { logger } = collect();
  t.notThrows(() => enforce(decision(true), { bypassed: false, logger }));
});

test('a refusing decision throws, so the port is never bound', t => {
  const { logger } = collect();
  t.throws(() => enforce(decision(false), { bypassed: false, logger }), {
    message: /NEWER binary/,
  });
});

test('UNREADABLE at boot logs an error but does NOT throw (design D9)', t => {
  const { logger, errors } = collect();
  t.notThrows(() =>
    enforce(decision(false, 'UNREADABLE', true), { bypassed: false, logger })
  );
  t.true(errors.some(m => /UNREADABLE/.test(m)));
});

test('the guard keys on bootMayContinue, not on the verdict string (D20)', t => {
  // If a future verdict is given boot-continue semantics, the guard must honour
  // it without being edited. Conversely a refusal with bootMayContinue false
  // must throw even if someone mislabels the verdict.
  const { logger } = collect();
  t.notThrows(() =>
    enforce(decision(false, 'SOME_FUTURE_VERDICT', true), {
      bypassed: false,
      logger,
    })
  );
  t.throws(() =>
    enforce(decision(false, 'UNREADABLE', false), { bypassed: false, logger })
  );
});

test('the bypass suppresses the throw and logs at ERROR every time', t => {
  const { logger, errors } = collect();
  t.notThrows(() => enforce(decision(false), { bypassed: true, logger }));
  t.true(errors.some(m => /AFFINE_DB_COMPAT_SKIP/.test(m)));
  t.true(errors.some(m => /DB_AHEAD/.test(m)));
});
```

- [ ] **Step 2: Run to verify failure**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/guard.spec.ts`

Expected: FAIL — unresolved import of `../guard` (the file does not exist yet).

- [ ] **Step 3: Implement `guard.ts`**

Create `packages/backend/server/src/core/db-compat/guard.ts`:

```ts
import {
  Injectable,
  Logger,
  type OnApplicationBootstrap,
} from '@nestjs/common';

import { bootGuardBypassed } from './env';
import { renderReport } from './render';
import { type CompatDecision, DbCompatService } from './service';

export class DatabaseIncompatibleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DatabaseIncompatibleError';
  }
}

/**
 * Pure enforcement, separated so it is testable without booting Nest.
 *
 * Keys on `decision.bootMayContinue` (D20), NOT on the verdict string. The
 * asymmetry it encodes: refusing to BOOT over a packaging fault would take the
 * fleet down for a non-safety reason, and because the migration initContainer
 * shares this pod and image, the predeploy gate has already refused in that
 * case (D9). Putting that judgement in a named field rather than a verdict
 * comparison means a future verdict inherits the right behaviour instead of
 * silently falling into "throw".
 */
export function enforce(
  decision: CompatDecision,
  context: { bypassed: boolean; logger: Pick<Logger, 'error' | 'log'> }
): void {
  const { report } = decision;

  if (decision.ok) {
    return;
  }

  if (decision.bootMayContinue) {
    context.logger.error(
      `database compatibility could not be verified (${report.verdict}) — ` +
        `continuing, because "cannot verify" is not "verified bad". ` +
        `Reason: ${report.reason}`
    );
    return;
  }

  if (context.bypassed) {
    context.logger.error(
      `AFFINE_DB_COMPAT_SKIP is set — SUPPRESSING a ${report.verdict} refusal and starting ` +
        `anyway. This is an incident bypass, not a setting; unset it once resolved. ` +
        `Reason: ${decision.refusal}`
    );
    return;
  }

  context.logger.error(
    `refusing to start: ${decision.refusal}\n${renderReport(report)}`
  );
  throw new DatabaseIncompatibleError(`refusing to start: ${decision.refusal}`);
}

@Injectable()
export class DbCompatGuard implements OnApplicationBootstrap {
  private readonly logger = new Logger(DbCompatGuard.name);

  constructor(private readonly service: DbCompatService) {}

  async onApplicationBootstrap(): Promise<void> {
    // Seven existing test files import AppModule and call module.init(), which
    // runs bootstrap hooks. The guard has its own unit tests; running it there
    // would add a database query and a failure mode to all of them.
    if (env.testing) {
      return;
    }

    // `check()` is pure since D17 — it writes nothing. Recording adoption is
    // `db stamp`'s job, run by the predeploy script after migrations; the
    // server must never stamp.
    const decision = await this.service.check();

    enforce(decision, { bypassed: bootGuardBypassed(), logger: this.logger });
  }
}
```

- [ ] **Step 4: Add `DbCompatGuardModule` to `index.ts`**

`index.ts` grows one addition per task; nothing was stubbed. Add the import and the second module
alongside the existing `DbCompatModule`:

```ts
import { DbCompatGuard } from './guard';

/**
 * Adds the boot guard. ONLY `AppModule` may import this (design D10/D14): the
 * CLI imports `FunctionalityModules`, and a guard reachable from there would
 * make `db check` refuse to run in exactly the situation it exists for.
 */
@Module({
  imports: [DbCompatModule],
  providers: [DbCompatGuard],
})
export class DbCompatGuardModule {}
```

- [ ] **Step 5: Run to verify pass**

Run: `yarn affine @affine/server test src/core/db-compat/__tests__/guard.spec.ts`

Expected: PASS, 5 tests.

- [ ] **Step 6: Wire `DbCompatGuardModule` into `AppModule`**

In `packages/backend/server/src/app.module.ts`, add the import beside the other `core/*` imports:

```ts
import { DbCompatGuardModule } from './core/db-compat';
```

Then add `DbCompatGuardModule` to `AppModule`'s own `imports` array. **Do not add it to
`FunctionalityModules`** — that array is shared with `CliAppModule`, and a guard reachable from
the CLI would make `db check` unable to run when it is most needed (design D10/D14).

- [ ] **Step 7: Verify the existing AppModule-importing tests still pass**

Run: `yarn affine @affine/server test src/__tests__/version.spec.ts src/__tests__/nestjs/throttler.spec.ts`

Expected: PASS. These import `AppModule`; if they fail, the `env.testing` short-circuit in
`guard.ts` is missing or misspelled.

- [ ] **Step 8: Add the predeploy gate**

In `packages/backend/server/scripts/self-host-predeploy.js`, add this function after
`fixFailedMigrations()`:

```js
function runCompatGate() {
  console.log('checking database compatibility.');
  execSync('yarn cli db check', {
    encoding: 'utf-8',
    env: process.env,
    stdio: 'inherit',
  });
}

function recordAdoption() {
  console.log('recording the deployment stamp.');
  execSync('yarn cli db stamp', {
    encoding: 'utf-8',
    env: process.env,
    stdio: 'inherit',
  });
}
```

Then change the call sequence at the bottom of the file from:

```js
prepare();
fixFailedMigrations();
runPrismaMigrations();
runDataMigrations();
```

to:

```js
prepare();
fixFailedMigrations();
// Gate BEFORE any migration runs. `execSync` throws on a non-zero exit, so a
// refusal aborts this script: the k8s initContainer wedges in Init and the old
// fleet keeps serving, and the compose one-shot fails before the server starts.
runCompatGate();
runPrismaMigrations();
runDataMigrations();
// Record AFTER, because the stamp lives in `app_configs`, which does not exist
// on a fresh install until `prisma migrate deploy` has run — `writeStamp` throws
// Prisma P2021 against it (measured; design D17). The gate cannot move later:
// refusing after a contracting migration has already been applied is useless.
// So the two steps have to sit on opposite sides of the migration. `db stamp`
// is idempotent, and declines to stamp if the verdict refuses.
recordAdoption();
```

- [ ] **Step 9: Verify the gate actually refuses a DB_AHEAD database**

This is the bead's second acceptance clause, so prove it rather than assume it. Insert a migration
name the binary cannot know, run the gate, then clean up:

```bash
psql "postgresql://affine:affine@localhost:5432/affine" -c "INSERT INTO _prisma_migrations (id, checksum, migration_name, finished_at, applied_steps_count) VALUES (gen_random_uuid()::text, 'x', '29990101000000_from_the_future', now(), 1);"
```

```bash
yarn workspace @affine/server data-migration db check; echo "exit=$?"
```

Expected: `exit=1`, a `DB_AHEAD` verdict, and `29990101000000_from_the_future` listed under
"in database but NOT in this binary".

```bash
psql "postgresql://affine:affine@localhost:5432/affine" -c "DELETE FROM _prisma_migrations WHERE migration_name = '29990101000000_from_the_future';"
```

Expected after cleanup: `yarn workspace @affine/server data-migration db check` exits 0 again.

- [ ] **Step 10: Add the two remaining manifest rows**

Append to the "Diverged upstream-owned files" table in `scripts/woven-patch-manifest.md`:

| File                                                     | Category     | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Delete when                                                 |
| -------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `packages/backend/server/src/app.module.ts`              | **ADDITIVE** | One added import: `DbCompatGuardModule` in `AppModule`'s `imports`, for the `affine-tc6` boot-time compatibility guard. Deliberately NOT added to `FunctionalityModules`, which `CliAppModule` shares — a guard reachable from the CLI would stop `db check` from running when it is most needed. One line, low-conflict.                                                                                                                                                                                                   | upstream grows its own boot-time schema-compatibility check |
| `packages/backend/server/scripts/self-host-predeploy.js` | **ADDITIVE** | Adds `runCompatGate()` (`yarn cli db check`) before `runPrismaMigrations()`, so a DB_AHEAD or wrong-deployment database is refused before anything mutates, plus `recordAdoption()` (`yarn cli db stamp`) after the migrations — the stamp lives in `app_configs`, which does not exist on a fresh install until they have run (D17). Both real deployment paths already invoke this script — the k8s initContainer and the self-host compose one-shot — which is why the `affine-tc6` gate needs no infrastructure change. | upstream's predeploy grows an equivalent guard              |

- [ ] **Step 11: Verify the manifest guard and the full db-compat suite**

Run: `scripts/woven-manifest-guard.sh`

Expected: exit 0.

Run: `yarn affine @affine/server test src/core/db-compat/`

Expected: PASS, all specs.

- [ ] **Step 12: Commit**

```bash
git add packages/backend/server/src/core/db-compat/ packages/backend/server/src/app.module.ts packages/backend/server/scripts/self-host-predeploy.js scripts/woven-patch-manifest.md && git commit -m "feat(woven): refuse to start or migrate against an incompatible database (affine-tc6.5)"
```

---

## Task 6: Docs, merge-checklist rewire, and cluster verification

**Files:**

- Modify: `scripts/woven-patch-manifest.md` (merge-checklist step 2)
- Create: `packages/backend/server/src/core/db-compat/README.md`
- Modify: `.claude/plans/adopt-existing-database/findings/open-questions.md` (record the outcome)

- [ ] **Step 1: Rewrite merge-checklist step 2**

In `scripts/woven-patch-manifest.md`, replace step 2 of the "Merge-time checklist" section. Its
current text (verify before editing — it opens
`2. **Audit incoming migrations for destructive DDL**`) tells the reader to audit
`packages/backend/server/migrations/` and `src/data/migrations/` by hand and cites `affine-tc6` for
the absence of a guard. The bead's own notes call that "a prompt to a human, not the guard item 1
asks for"; this task is what retires the prompt. Replace with:

````markdown
2. **Audit incoming migrations for destructive DDL — now mechanical.** Run:

   ```bash
   yarn workspace @affine/server data-migration db status
   ```
````

It lists every pending migration with a tier and answers `rollback after applying:` directly.
`BLOCKING` means an older binary cannot read the result, so **image rollback across it is
impossible**; `DESTRUCTIVE` means data or a constraint is lost but an older binary still runs.
Require a **verified-restorable** backup before deploying across a `BLOCKING` one.

This replaced a hand audit when `affine-tc6` shipped. The guard now also enforces it at
deploy time: `scripts/self-host-predeploy.js` runs `db check`, which refuses a database
migrated by a newer binary and refuses to adopt an unstamped populated database across a
`BLOCKING` migration without `AFFINE_DB_ADOPT=1`.

````

- [ ] **Step 2: Write the operator README**

Create `packages/backend/server/src/core/db-compat/README.md`:

```markdown
# Database compatibility and adoption (`affine-tc6`)

Fork-owned. Refuses to start or migrate when the database does not match this binary, records
adoption of a pre-existing database as a durable decision, and reports whether rollback will be
possible.

Design: `.claude/plans/adopt-existing-database/DESIGN.md`.

## Operator commands

Two invocation forms, same CLI:

| Where                              | Form                                                    |
| ---------------------------------- | ------------------------------------------------------- |
| **In the image / a built server**  | `yarn cli db status` (cwd `/app`) — runs `dist/main.js`  |
| **A source checkout (no bundle)**  | `yarn workspace @affine/server data-migration db status` |

The `data-migration` script is `cross-env NODE_ENV=development SERVER_FLAVOR=script r ./src/index.ts`
— the dev entry point to the same CLI. Its name is historical and it accepts any subcommand; use it
to avoid a full rspack build when auditing a merge locally.

`db status` reports the verdict, pending migrations by tier, the identity stamp, and
`rollback after applying:` — `POSSIBLE`, `IMPOSSIBLE` or `UNKNOWN`. Always exits 0. `--json` for
machine use.

`db check` is the gate: it exits non-zero with a precise reason, and is run automatically by
`scripts/self-host-predeploy.js` before any migration.

## Environment variables

Read directly from `process.env` and **not** registered as app config, so they cannot be
overridden from the `app_configs` table and do not appear in the admin UI. This is deliberate: a
database row must not be able to switch off the guard that judges that database.

| Variable                  | Effect                                                                                                                             |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `AFFINE_DEPLOYMENT_ID`    | Asserts which deployment this is. When set and the stamp names another, the server refuses. Unset ⇒ identity unchecked.            |
| `AFFINE_DB_ADOPT=1`       | Confirms a pre-existing, unstamped, populated database is intended even across a `BLOCKING` migration.                             |
| `AFFINE_DB_COMPAT_SKIP=1` | **Incident bypass.** Suppresses the boot refusal only — never the predeploy gate — and logs at ERROR on every boot. Not a setting. |

## Enabling wrong-database detection

On first adoption with no `AFFINE_DEPLOYMENT_ID`, a UUID is minted, stored and logged:

```
deployment identity minted as <uuid>; set AFFINE_DEPLOYMENT_ID=<uuid> to enable wrong-database detection
```

Pin that value in the chart's `extraEnv` (values-only; no template change). Until it is set,
`IDENTITY_MISMATCH` cannot fire — the DB_AHEAD guard is unaffected and always active.

## What this does not protect

An image built before `affine-tc6` shipped cannot refuse anything. Rollback across
`20260714000001_drop_legacy_permission_and_subscription`, already inside the pinned image, stays
unprotected; a verified-restorable backup is the only net for it.

````

- [ ] **Step 3: Commit the docs**

```bash
git add scripts/woven-patch-manifest.md packages/backend/server/src/core/db-compat/README.md && git commit -m "docs(woven): operator docs and mechanical migration audit (affine-tc6.6)"
```

- [ ] **Step 4: Run the full server lint and the broader suite**

Run: `yarn lint:format` and `scripts/woven-manifest-guard.sh`

Expected: both clean.

Run: `yarn affine @affine/server test src/core/db-compat/ src/__tests__/version.spec.ts src/core/config/__tests__/service.spec.ts`

Expected: PASS. `core/config/__tests__/service.spec.ts` is included on purpose — it exercises
`loadDbOverrides()`, the mechanism the `$deployment` stamp relies on staying inert.

- [ ] **Step 5: Cluster verification against a restored database**

This is the bead's stated acceptance condition and the only step needing an environment outside
this repo. Follow `infrastructure/docs/src/operations/affine-pg-restore-drill.md` (bead
`infra-zptb.6`) to recover `affine-pg` into the scratch cluster in the `agents` namespace, then
against the **restored** database record:

1. `db status` — expect `EQUAL` (the restore carries the same migration history) and an identity
   line reflecting whatever the source database was stamped with.
2. `db check` — expect exit 0, and **no** adoption warning if the source was already stamped.
   A restored copy inherits the stamp, so if `AFFINE_DEPLOYMENT_ID` is set to the _scratch_
   deployment's id, expect `IDENTITY_MISMATCH` and a refusal — that is the wrong-database
   detection working, not a bug. Record which of the two you exercised.
3. Bring a server up against it and confirm it reaches ready.

Write the measured outcome into
`.claude/plans/adopt-existing-database/findings/open-questions.md` under OQ-2, and answer the
question left open there: whether the drill runbook itself should gain a "bring a server up
against the restored database" step. If yes, file an infra-repo bead — it is a cross-repo change
and needs an owner there.

- [ ] **Step 6: Close out**

```bash
bd update affine-tc6 --claim
```

Record the verification evidence on the bead, then close it:

```bash
bd close affine-tc6 --reason "Compatibility check, ADOPT mode, tiered dry-run report and deployment identity shipped; verified against a restored database per the infra restore-drill runbook"
```

Do **not** run `bd dolt push` — the shared Dolt server has no configured remote.

---

## Coverage against the design

| Design element                                     | Task        |
| -------------------------------------------------- | ----------- |
| `classify.ts`, tiers, `$$` scrubbing, corpus       | T1          |
| `migration-set.ts`, dir resolution                 | T1          |
| `db-state.ts`, `_prisma_migrations`, missing table | T2          |
| `compat.ts`, all 9 verdicts, precedence            | T2          |
| `identity.ts`, `$deployment` inertness             | T3          |
| Env knobs read from `process.env` (D13)            | T3          |
| Adoption gate, minted-UUID ratchet (D3, D5)        | T3          |
| `db status` / `db check`, minimal context (D7)     | T4          |
| Local rehearsal path (D12)                         | T4 (Step 7) |
| Boot guard, `UNREADABLE` asymmetry (D9)            | T5          |
| `AFFINE_DB_COMPAT_SKIP` bypass (D11)               | T5          |
| Two-module split (D14), `env.testing` inertness    | T5          |
| Predeploy gate                                     | T5          |
| Three manifest rows                                | T4, T5      |
| Merge-checklist rewire                             | T6          |
| CNPG restore-drill verification                    | T6          |
