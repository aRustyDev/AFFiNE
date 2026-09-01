/**
 * See .claude/plans/adopt-existing-database/DESIGN.md and PLAN.md for the
 * D4 / G2a / G2b / G2c groundings cited below.
 */

export type DdlTier = 'BLOCKING' | 'DESTRUCTIVE' | 'EXPAND';
export type HitTier = Exclude<DdlTier, 'EXPAND'>;

export interface DdlHit {
  tier: HitTier;
  /** Stable rule name, e.g. `drop-table`. Reported to operators. */
  rule: string;
  /** 1-based line where the offending statement starts. */
  line: number;
  /** The full collapsed statement text. Windowing for display is the renderer's job. */
  statement: string;
}

export interface DdlClassification {
  tier: DdlTier;
  hits: DdlHit[];
  /**
   * True when the SQL contained a comment, dollar-quoted body, string literal
   * or quoted identifier that never found its closing delimiter. Unparseable
   * SQL cannot be judged, so this always forces `tier: 'BLOCKING'` (see the
   * synthetic `unparseable` hit) rather than silently falling through to
   * EXPAND — a migration this malformed would fail in prisma anyway.
   */
  unterminated: boolean;
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
  {
    // Anchored to ALTER TABLE so `ALTER INDEX ... RENAME TO` (Prisma's output
    // for an `@@index(map:)` change, invisible to an older binary) doesn't
    // false-alarm into the tier that gates rollback.
    name: 'rename-table',
    tier: 'BLOCKING',
    pattern: /\bALTER\s+TABLE\b.*?\bRENAME\s+TO\b/i,
  },
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
  {
    // Anchored to the start of the (already-trimmed) statement: TRUNCATE is
    // always statement-leading in Postgres, and an unanchored match fires on
    // a quoted identifier/column named "truncate".
    name: 'truncate',
    tier: 'DESTRUCTIVE',
    pattern: /^TRUNCATE\b/i,
  },
  { name: 'delete-from', tier: 'DESTRUCTIVE', pattern: /\bDELETE\s+FROM\b/i },
];

/** Cap on the synthetic `unparseable` hit's statement preview only — real
 * hits keep their full text (issue 7); this one previews the remainder of a
 * possibly-huge blanked-to-EOF file. */
const UNTERMINATED_PREVIEW_LEN = 200;

/**
 * A discriminated union so the "unterminated implies a location" invariant is
 * enforced by the type checker rather than by convention: there is no way to
 * construct the `unterminated: true` branch without also supplying `at`, so a
 * caller (classifyDdl) can never end up with `unterminated: true` and nothing
 * to build the synthetic `unparseable` hit from.
 */
type ScrubResult =
  | { text: string; unterminated: false }
  | { text: string; unterminated: true; at: { line: number; index: number } };

/**
 * Blank out comments, dollar-quoted bodies, string literals and double-quoted
 * identifiers, preserving the total line count so reported line numbers stay
 * accurate.
 *
 * Dollar-quote handling is load-bearing, not defensive: three migrations in the
 * corpus contain DROP/DELETE inside a `$$` function body that the migration
 * itself never executes. See grounding G2b.
 *
 * Any of the four constructs above can run to end-of-input without finding
 * its closing delimiter (an unterminated string, a stray apostrophe inside a
 * quoted identifier that the old scanner mistook for a string start, etc).
 * That is reported via `unterminated`/`at` rather than silently blanking the
 * remainder of the file and letting classification fall through to EXPAND.
 */
function scrubDetailed(sql: string): ScrubResult {
  let out = '';
  let i = 0;
  let unterminated = false;
  let at: { line: number; index: number } | null = null;

  const blank = (from: number, to: number) => {
    for (let k = from; k < to; k++) {
      out += sql[k] === '\n' ? '\n' : ' ';
    }
  };

  const lineAt = (index: number): number => {
    let n = 1;
    for (let k = 0; k < index; k++) {
      if (sql[k] === '\n') {
        n++;
      }
    }
    return n;
  };

  const markUnterminated = (startIndex: number) => {
    if (!unterminated) {
      unterminated = true;
      at = { line: lineAt(startIndex), index: startIndex };
    }
  };

  while (i < sql.length) {
    if (sql.startsWith('--', i)) {
      // A line comment reaching EOF with no trailing newline is valid SQL,
      // not a parse failure — unlike the other four constructs, it has no
      // closing delimiter to fail to find, so this branch never calls
      // markUnterminated.
      const end = sql.indexOf('\n', i);
      const stop = end === -1 ? sql.length : end;
      blank(i, stop);
      i = stop;
      continue;
    }

    if (sql.startsWith('/*', i)) {
      const start = i;
      const end = sql.indexOf('*/', i + 2);
      const stop = end === -1 ? sql.length : end + 2;
      blank(i, stop);
      if (end === -1) {
        markUnterminated(start);
      }
      i = stop;
      continue;
    }

    // Postgres dollar-quote tags follow identifier rules: a letter or
    // underscore, then letters/digits/underscores. `$1$` (a positional
    // parameter, not a tag) must still be rejected.
    const dollar = /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i));
    if (dollar) {
      const start = i;
      const tag = dollar[0];
      const end = sql.indexOf(tag, i + tag.length);
      const stop = end === -1 ? sql.length : end + tag.length;
      blank(i, stop);
      if (end === -1) {
        markUnterminated(start);
      }
      i = stop;
      continue;
    }

    if (sql[i] === "'") {
      const start = i;
      // Backslash is only an escape character inside an E-prefixed literal
      // (E'...'). With standard_conforming_strings = on — the default since
      // Postgres 9.1 — a plain '...' literal treats \ as an ordinary
      // character, so 'a\' is already a complete, terminated string. Treating
      // backslash as an escape unconditionally made the scanner consume the
      // closing quote and run to EOF on ordinary content like a Windows path
      // default ('C:\'), a false `unparseable` alarm in the tier that gates.
      const before = sql[start - 1];
      const beforeThat = sql[start - 2];
      const isEscapeString =
        (before === 'E' || before === 'e') &&
        !/[A-Za-z0-9_]/.test(beforeThat ?? '');
      let k = i + 1;
      let closed = false;
      while (k < sql.length) {
        if (isEscapeString && sql[k] === '\\' && k + 1 < sql.length) {
          k += 2;
          continue;
        }
        if (sql[k] === "'" && sql[k + 1] === "'") {
          // Doubled quote escapes a literal quote in both literal forms.
          k += 2;
          continue;
        }
        if (sql[k] === "'") {
          closed = true;
          k += 1;
          break;
        }
        k++;
      }
      blank(start, k);
      if (!closed) {
        markUnterminated(start);
      }
      i = k;
      continue;
    }

    if (sql[i] === '"') {
      const start = i;
      let k = i + 1;
      let closed = false;
      while (k < sql.length) {
        if (sql[k] === '"' && sql[k + 1] === '"') {
          // Doubled quote escapes a literal quote in an identifier.
          k += 2;
          continue;
        }
        if (sql[k] === '"') {
          closed = true;
          k += 1;
          break;
        }
        k++;
      }
      blank(start, k);
      if (!closed) {
        markUnterminated(start);
      }
      i = k;
      continue;
    }

    out += sql[i];
    i++;
  }

  // `at` is always set together with `unterminated` inside markUnterminated,
  // so this check never actually diverges from `unterminated` alone — it's
  // written as a narrowing check rather than a non-null assertion so the
  // return type stays the enforced discriminated union above.
  return unterminated && at
    ? { text: out, unterminated: true, at }
    : { text: out, unterminated: false };
}

export function scrubSql(sql: string): string {
  return scrubDetailed(sql).text;
}

export interface SqlStatement {
  /** Whitespace-collapsed statement text, without the trailing semicolon. */
  text: string;
  /** 1-based line the statement starts on. */
  line: number;
}

function splitScrubbedStatements(scrubbed: string): SqlStatement[] {
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

/**
 * Scrub then split raw SQL into statements. Statement-level rather than
 * per-line so a clause split across lines still matches; see grounding G2c.
 *
 * This intentionally does not surface `unterminated` — a caller that needs it
 * for a safety decision must call `classifyDdl`, the entry point for that.
 * Exported here only because the tests use it directly for line attribution.
 */
export function splitStatements(sql: string): SqlStatement[] {
  return splitScrubbedStatements(scrubDetailed(sql).text);
}

export function classifyDdl(sql: string): DdlClassification {
  const scrubbed = scrubDetailed(sql);
  const hits: DdlHit[] = [];

  for (const statement of splitScrubbedStatements(scrubbed.text)) {
    for (const rule of RULES) {
      if (rule.pattern.test(statement.text)) {
        hits.push({
          tier: rule.tier,
          rule: rule.name,
          line: statement.line,
          statement: statement.text,
        });
      }
    }
  }

  if (scrubbed.unterminated) {
    // The discriminated union guarantees `scrubbed.at` exists here — see
    // ScrubResult — so this can never silently skip the synthetic hit and
    // leave `unterminated: true` paired with a non-BLOCKING tier.
    const remainder = sql.slice(scrubbed.at.index).replace(/\s+/g, ' ').trim();
    hits.push({
      tier: 'BLOCKING',
      rule: 'unparseable',
      line: scrubbed.at.line,
      statement: remainder.slice(0, UNTERMINATED_PREVIEW_LEN),
    });
  }

  const tier: DdlTier = hits.some(hit => hit.tier === 'BLOCKING')
    ? 'BLOCKING'
    : hits.length > 0
      ? 'DESTRUCTIVE'
      : 'EXPAND';

  return { tier, hits, unterminated: scrubbed.unterminated };
}
