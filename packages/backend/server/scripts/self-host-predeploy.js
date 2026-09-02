import { execSync } from 'node:child_process';
import { generateKeyPairSync } from 'node:crypto';
import fs from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const SELF_HOST_CONFIG_DIR = `${homedir()}/.affine/config`;

function generatePrivateKey() {
  const key = generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
  }).privateKey.export({
    type: 'sec1',
    format: 'pem',
  });

  if (key instanceof Buffer) {
    return key.toString('utf-8');
  }

  return key;
}

/**
 * @type {Array<{ to: string; generator: () => string }>}
 */
const files = [{ to: 'private.key', generator: generatePrivateKey }];

function prepare() {
  fs.mkdirSync(SELF_HOST_CONFIG_DIR, { recursive: true });

  for (const { to, generator } of files) {
    const targetFilePath = path.join(SELF_HOST_CONFIG_DIR, to);
    if (!fs.existsSync(targetFilePath)) {
      console.log(`creating config file [${targetFilePath}].`);
      fs.writeFileSync(targetFilePath, generator(), 'utf-8');
    }
  }
}

function runPrismaMigrations() {
  console.log('running prisma migrations.');
  execSync('yarn prisma migrate deploy', {
    encoding: 'utf-8',
    env: process.env,
    stdio: 'inherit',
  });
}

function runDataMigrations() {
  console.log('running data migrations.');
  execSync('yarn cli run', {
    encoding: 'utf-8',
    env: process.env,
    stdio: 'inherit',
  });
}

function fixFailedMigrations() {
  console.log('fixing failed migrations.');
  const maybeFailedMigrations = [
    '20250521083048_fix_workspace_embedding_chunk_primary_key',
  ];
  for (const migration of maybeFailedMigrations) {
    try {
      execSync(`yarn prisma migrate resolve --rolled-back ${migration}`, {
        encoding: 'utf-8',
        env: process.env,
        stdio: 'pipe',
      });
      console.log(`migration [${migration}] has been rolled back.`);
    } catch (err) {
      if (
        err.message.includes(
          'cannot be rolled back because it is not in a failed state'
        ) ||
        err.message.includes(
          'cannot be rolled back because it was never applied'
        ) ||
        err.message.includes(
          'called markMigrationRolledBack on a database without migrations table'
        )
      ) {
        // migration has been rolled back, skip it
        continue;
      }
      // ignore other errors
      console.log(
        `migration [${migration}] rolled back failed. ${err.message}`
      );
    }
  }
}

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

prepare();
// Must run BEFORE the gate, not after: `compat.ts` excludes rolled-back rows
// from `failed`, so gating first would return MIGRATION_FAILED on exactly the
// databases this repair exists to heal, wedging those upgrades permanently.
// It can write `rolled_back_at` onto a `_prisma_migrations` row, but that is
// bookkeeping, not schema — no CREATE/ALTER/DROP runs until
// `runPrismaMigrations()` below.
fixFailedMigrations();
// Gate before any SCHEMA-mutating migration runs (fixFailedMigrations above
// only marks bookkeeping rows, never DDL). `execSync` throws on a non-zero
// exit, so a refusal aborts this script: the k8s initContainer wedges in Init
// and the old fleet keeps serving, and the compose one-shot fails before the
// server starts.
runCompatGate();
runPrismaMigrations();
runDataMigrations();
// Record AFTER, because the stamp lives in `app_configs`, which does not exist
// on a fresh install until `prisma migrate deploy` has run — `writeStamp` throws
// Prisma P2021 against it (measured; design D17). The gate cannot move later:
// refusing after a contracting migration has already been applied is useless.
// So the two steps have to sit on opposite sides of the migration. `db stamp`
// is idempotent, and declines to stamp if the verdict refuses.
//
// A `db stamp` failure here (e.g. a transient write error against
// `app_configs`) aborts this script and wedges the deploy — deliberately.
// On compose there is no retry (`affine_migration` has no `restart:` policy,
// and the server gates on `service_completed_successfully`), so a migrated
// database with no deployment stamp yet leaves the server down until the
// operator reruns predeploy. That is a fail-closed, accepted availability
// cost, not an oversight to fix here.
recordAdoption();
