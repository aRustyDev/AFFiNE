# syntax=docker/dockerfile:1.7
#
# woven.Dockerfile — build a runnable AFFiNE server image for the FORK entirely
# FROM SOURCE. This sidesteps the host cross-arch problem of the shipped
# packaging-only Dockerfile (.github/deployment/node/Dockerfile), which expects
# prebuilt dist + node_modules and a per-arch server-native .node produced by CI.
#
# BUILT BY CI ONLY. .github/workflows/woven-publish-image.yml is the sole
# consumer: it builds this file for linux/amd64 and pushes
# ghcr.io/${owner}/affine:woven-<sha> plus the floating :woven. The
# infrastructure repo pins the resulting DIGEST. There is no local build path.
#
# NOTE: this from-source build is heavy (10-30 min, >=8 GB RAM, network).
ARG NODE_IMAGE=node:22-bookworm-slim

# ---- builder: full toolchain, build frontend + rust + server ---------------
FROM ${NODE_IMAGE} AS builder
WORKDIR /app
ARG BUILD_TYPE=stable
ARG APP_VERSION=0.0.0-woven
# GITHUB_SHA short-circuits html-plugin.ts gitShortHash() (tools/cli), so the
# frontend build does NOT need a .git dir in the context — the committed root
# .dockerignore drops .git. Without this the rspack build throws
# "Failed to open git repo" (swallowed as exit 0), leaving empty dist dirs.
ENV BUILD_TYPE=${BUILD_TYPE} HUSKY=0 ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CARGO_TERM_COLOR=never \
    GITHUB_SHA=${APP_VERSION}

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake clang perl pkg-config libssl-dev git python3 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Rust 1.96 (matches rust-toolchain.toml)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.96.0
ENV PATH="/root/.cargo/bin:${PATH}"

COPY . .
RUN corepack enable
# Build native rust for THIS platform (linux/arm64), then frontend + server.
# napi emits only server-native.node for this arch; the @affine/server rspack
# bundle statically resolves index.js's per-arch fallbacks (arm64/armv7/x64), so
# all three names must exist at bundle time. This is an arm64-only image, so the
# extra names are copies of the arm64 binary; docker-clean (assets stage) prunes
# every name except server-native.<TARGETARCH>.node (= server-native.arm64.node).
RUN rm -f packages/backend/native/server-native*.node \
    && corepack yarn install --immutable \
    && corepack yarn workspace @affine/server-native build \
    && ( cd packages/backend/native && for a in arm64 armv7 x64; do cp -f server-native.node "server-native.$a.node"; done ) \
    && corepack yarn affine @affine/web build \
    && corepack yarn affine @affine/admin build \
    && corepack yarn affine @affine/mobile build \
    && corepack yarn workspace @affine/server build \
    && for d in packages/frontend/apps/web/dist packages/frontend/admin/dist \
                packages/frontend/apps/mobile/dist packages/backend/server/dist; do \
         [ -d "$d" ] || { echo "FATAL: build produced no $d (swallowed rspack error above?)"; exit 1; }; \
       done
# Production node_modules focused on the server, then folded into the server pkg
# (mirrors CI build-images.yml). The yarn CPU arch derives from TARGETARCH so this
# file builds for both amd64 (ds-cleaner cluster) and arm64 (local) — docker-clean
# already maps amd64->x64 for the server-native binary name.
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) YARN_CPU=x64 ;; \
      arm64) YARN_CPU=arm64 ;; \
      arm)   YARN_CPU=arm ;; \
      *) echo "woven.Dockerfile: unsupported TARGETARCH='$TARGETARCH'" >&2; exit 1 ;; \
    esac \
    && corepack yarn config set --json supportedArchitectures.cpu "[\"$YARN_CPU\"]" \
    && corepack yarn config set --json supportedArchitectures.libc '["glibc"]' \
    && corepack yarn workspaces focus @affine/server --production \
    && corepack yarn workspace @affine/server prisma generate \
    && mv node_modules packages/backend/server/node_modules

# ---- assets: assemble the /app layout the runtime expects ------------------
FROM ${NODE_IMAGE} AS assets
WORKDIR /app
COPY --from=builder /app/packages/backend/server /app
COPY --from=builder /app/packages/frontend/apps/web/dist /app/static
COPY --from=builder /app/packages/frontend/admin/dist /app/static/admin
COPY --from=builder /app/packages/frontend/apps/mobile/dist /app/static/mobile
ARG TARGETARCH
ARG TARGETVARIANT
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && AFFINE_DOCKER_CLEAN=1 TARGETARCH="${TARGETARCH}" TARGETVARIANT="${TARGETVARIANT}" node ./scripts/docker-clean.mjs

# ---- runtime (mirrors .github/deployment/node/Dockerfile stage 2) ----------
FROM ${NODE_IMAGE}
WORKDIR /app
COPY --from=assets /app /app
RUN apt-get update && apt-get install -y --no-install-recommends openssl libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*
ENV LD_PRELOAD=libjemalloc.so.2
EXPOSE 3010
CMD ["node", "./dist/main.js"]
