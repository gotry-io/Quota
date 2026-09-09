# QuotaRelay Node runtime. Both stages are bookworm-slim. better-sqlite3's
# install script still runs node-gyp, so each stage that `pnpm install`s it
# needs python3/make/g++. The native module is installed in the runtime stage
# on this platform, not copied from builder.
FROM node:22-bookworm-slim AS builder

WORKDIR /app

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  npm_config_engine_strict=false \
  npm_config_build_from_source=false

RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY apps/relay/package.json apps/relay/package.json
COPY apps/web/package.json apps/web/package.json
COPY packages/protocol/package.json packages/protocol/package.json
COPY packages/quota-model/package.json packages/quota-model/package.json
COPY packages/relay-core/package.json packages/relay-core/package.json
COPY scripts/install-git-hooks.sh scripts/install-git-hooks.sh

RUN chmod +x scripts/install-git-hooks.sh \
  && corepack prepare pnpm@10.23.0 --activate \
  && pnpm install --frozen-lockfile

COPY apps/relay apps/relay
COPY apps/web apps/web
COPY packages/protocol packages/protocol
COPY packages/quota-model packages/quota-model
COPY packages/relay-core packages/relay-core
COPY packages/provider packages/provider

RUN pnpm --filter @gotry-io/quota-web build \
  && pnpm --filter @gotry-io/quota-relay build:node

FROM node:22-bookworm-slim AS runtime

WORKDIR /app

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  npm_config_engine_strict=false \
  npm_config_build_from_source=false \
  PORT=8787 \
  RELAY_SQLITE_PATH=/data/relay.sqlite \
  RELAY_STATIC_DIR=apps/web/.svelte-kit/output/client

RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && mkdir -p /data \
  && chown node:node /data

COPY --from=builder /app/package.json /app/pnpm-lock.yaml /app/pnpm-workspace.yaml ./
COPY --from=builder /app/apps/relay/package.json apps/relay/package.json
COPY --from=builder /app/apps/web/package.json apps/web/package.json
COPY --from=builder /app/packages/protocol/package.json packages/protocol/package.json
COPY --from=builder /app/packages/quota-model/package.json packages/quota-model/package.json
COPY --from=builder /app/packages/relay-core/package.json packages/relay-core/package.json
COPY --from=builder /app/scripts/install-git-hooks.sh scripts/install-git-hooks.sh

RUN corepack enable \
  && corepack prepare pnpm@10.23.0 --activate \
  && chmod +x scripts/install-git-hooks.sh \
  && pnpm install --frozen-lockfile --prod --filter @gotry-io/quota-relay \
  && apt-get purge -y python3 make g++ \
  && apt-get autoremove -y --purge \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder --chown=node:node /app/apps/relay/dist/node/server.mjs apps/relay/dist/node/server.mjs
COPY --from=builder --chown=node:node /app/apps/web/.svelte-kit/output/client apps/web/.svelte-kit/output/client
COPY --from=builder --chown=node:node /app/apps/relay/migrations apps/relay/migrations

VOLUME /data
EXPOSE 8787

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||'8787')+'/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

CMD ["node", "apps/relay/dist/node/server.mjs"]
