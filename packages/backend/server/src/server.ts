import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import cookieParser from 'cookie-parser';
import graphqlUploadExpress from 'graphql-upload/graphqlUploadExpress.mjs';

import {
  AFFiNELogger,
  buildCorsAllowedOrigins,
  CacheInterceptor,
  CloudThrottlerGuard,
  Config,
  CORS_ALLOWED_HEADERS,
  CORS_ALLOWED_METHODS,
  CORS_EXPOSED_HEADERS,
  corsOriginCallback,
  GlobalExceptionFilter,
  URLHelper,
} from './base';
import { SocketIoAdapter } from './base/websocket';
import { AuthGuard } from './core/auth';
import { assertDatabaseCompatible } from './core/db-compat';
import { TelemetryService } from './core/telemetry/service';
import { serverTimingAndCache } from './middleware/timing';

const OneMB = 1024 * 1024;

export async function run() {
  const { AppModule } = await import('./app.module');

  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    cors: false,
    rawBody: true,
    bodyParser: true,
    bufferLogs: true,
  });

  app.useBodyParser('raw', { limit: 100 * OneMB });

  const logger = app.get(AFFiNELogger);
  app.useLogger(logger);

  // affine-tc6: refuse to serve traffic against an incompatible database.
  // Deliberately placed here rather than as a module `OnApplicationBootstrap`
  // hook: `NestFactory.create()` runs no lifecycle hooks at all, so this
  // strictly precedes every one of them — including the native migration
  // runners in `BackendRuntimeProvider` and `StorageRuntimeProvider`, which
  // would otherwise mutate the database before a module-hook-based guard
  // could ever refuse. It also means this throw happens before
  // `app.listen()`'s callback would flush the `bufferLogs: true` buffer
  // above, which is why the refusal's full report travels in the thrown
  // Error's message rather than relying on the logger (see `guard.ts`).
  await assertDatabaseCompatible(app, logger);

  const config = app.get(Config);
  const url = app.get(URLHelper);
  let telemetry: TelemetryService | null = null;
  try {
    telemetry = app.get(TelemetryService, { strict: false });
  } catch {
    telemetry = null;
  }

  const defaultAllowedOrigins = buildCorsAllowedOrigins(url);

  app.enableCors((req, callback) => {
    const requestPath = req.path ?? req.url ?? '';
    const appendedOrigins = telemetry?.getAllowedOrigins(requestPath) ?? [];
    const finalAllowedOrigins = appendedOrigins.length
      ? new Set([...defaultAllowedOrigins, ...appendedOrigins])
      : defaultAllowedOrigins;

    callback(null, {
      origin: (origin, originCallback) => {
        corsOriginCallback(
          origin,
          finalAllowedOrigins,
          blockedOrigin => {
            if (!appendedOrigins.length) {
              logger.warn(
                `Blocked CORS request from origin: ${blockedOrigin}`,
                { requestPath }
              );
            }
          },
          originCallback
        );
      },
      credentials: true,
      methods: CORS_ALLOWED_METHODS,
      allowedHeaders: CORS_ALLOWED_HEADERS,
      exposedHeaders: CORS_EXPOSED_HEADERS,
      maxAge: 86400,
      optionsSuccessStatus: 204,
    });
  });

  if (config.server.path) {
    app.setGlobalPrefix(config.server.path);
  }

  app.use(serverTimingAndCache);

  app.use(
    graphqlUploadExpress({
      maxFileSize: 100 * OneMB,
      maxFiles: 32,
    })
  );

  app.useGlobalGuards(app.get(AuthGuard), app.get(CloudThrottlerGuard));
  app.useGlobalInterceptors(app.get(CacheInterceptor));
  app.useGlobalFilters(new GlobalExceptionFilter(app.getHttpAdapter()));
  app.use(cookieParser());
  // only enable shutdown hooks in production
  // https://docs.nestjs.com/fundamentals/lifecycle-events#application-shutdown
  if (env.prod) {
    app.enableShutdownHooks();
  }

  const adapter = new SocketIoAdapter(app);
  app.useWebSocketAdapter(adapter);

  if (env.dev) {
    const { SwaggerModule, DocumentBuilder } = await import('@nestjs/swagger');
    // Swagger API Docs
    const docConfig = new DocumentBuilder()
      .setTitle('AFFiNE API')
      .setDescription(`AFFiNE Server ${env.version} API documentation`)
      .setVersion(`${env.version}`)
      .build();
    const documentFactory = () => SwaggerModule.createDocument(app, docConfig);
    SwaggerModule.setup('/api/docs', app, documentFactory, {
      useGlobalPrefix: true,
      swaggerOptions: { persistAuthorization: true },
    });
  }

  await app.listen(config.server.port, config.server.listenAddr);

  const formattedAddr = config.server.listenAddr.includes(':')
    ? `[${config.server.listenAddr}]`
    : config.server.listenAddr;

  logger.log(`AFFiNE Server is running in [${env.DEPLOYMENT_TYPE}] mode`);
  logger.log(`Listening on http://${formattedAddr}:${config.server.port}`);
  logger.log(`And the public server should be recognized as ${url.baseUrl}`);
}
