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
