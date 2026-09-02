import { basename } from 'node:path';

import { type INestApplicationContext, Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { Command, CommanderError } from 'commander';

import { DbCompatService, renderReport } from './core/db-compat';
import { DbCompatCliModule } from './core/db-compat/cli-module';
import { CliAppModule } from './data/app';
import { CreateCommand } from './data/commands/create';
import { ImportConfigCommand } from './data/commands/import';
import { RevertCommand, RunCommand } from './data/commands/run';

function getProgramName() {
  return process.env.npm_lifecycle_event ?? basename(process.argv[1] ?? 'cli');
}

async function withCliApp(
  logger: Logger,
  callback: (app: INestApplicationContext) => Promise<void>
) {
  const app = await NestFactory.createApplicationContext(CliAppModule, {
    logger,
  });

  try {
    await callback(app);
  } finally {
    await app.close();
  }
}

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

function buildProgram(logger: Logger) {
  const program = new Command();

  program
    .name(getProgramName())
    .description('AFFiNE server CLI')
    .showHelpAfterError()
    .showSuggestionAfterError();

  program
    .command('create [name]')
    .description('create a data migration script')
    .action(async name => {
      await withCliApp(logger, async app => {
        await app.get(CreateCommand).execute(name);
      });
    });

  program
    .command('run')
    .description('Run all pending data migrations')
    .action(async () => {
      await withCliApp(logger, async app => {
        await app.get(RunCommand).execute();
      });
    });

  program
    .command('revert [name]')
    .description('Revert one data migration with given name')
    .action(async name => {
      await withCliApp(logger, async app => {
        await app.get(RevertCommand).execute(name);
      });
    });

  program
    .command('import-config [path]')
    .description('import config from a file')
    .action(async path => {
      await withCliApp(logger, async app => {
        await app.get(ImportConfigCommand).execute(path);
      });
    });

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
    .description(
      'record the deployment stamp; run AFTER migrations. Idempotent.'
    )
    .option('--adopt', 'record the adoption as explicit rather than implicit')
    .action(async (options: { adopt?: boolean }) => {
      await withMinimalApp(logger, async app => {
        await app.get(DbCompatService).stamp({ adopt: options.adopt });
      });
    });

  return program;
}

export async function run() {
  const logger = new Logger('Cli');

  try {
    const program = buildProgram(logger);
    program.exitOverride();

    const argv =
      process.argv.length > 2 ? process.argv : [...process.argv, '--help'];
    await program.parseAsync(argv);
  } catch (error) {
    if (error instanceof CommanderError) {
      process.exitCode = error.exitCode;
      return;
    }

    if (error instanceof Error) {
      logger.error(error.message, error.stack);
    } else {
      logger.error(String(error));
    }
    process.exitCode = 1;
  }
}
