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
