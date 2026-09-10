# QuotaRelay Node runtime. The builder installs the workspace and compiles better-sqlite3
# (its install script runs node-gyp, hence python3/make/g++ there); the runtime stage copies
# the bundle and that one module and installs nothing.
FROM node:24-bookworm-slim AS builder

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

# The one module the bundle leaves external. Its npm package carries prebuilt binaries for
# linux-arm64 and linux-x64, and `lib/binding.js` loads the one for this platform when there is
# no local build, so the runtime needs its JavaScript, its manifest, and those two files.
RUN mkdir -p /app/runtime-modules/better-sqlite3/prebuilds \
  && cd "$(readlink -f apps/relay/node_modules/better-sqlite3)" \
  && cp -r lib package.json /app/runtime-modules/better-sqlite3/ \
  && cp prebuilds/linux-arm64.node prebuilds/linux-x64.node /app/runtime-modules/better-sqlite3/prebuilds/

FROM node:24-bookworm-slim AS runtime

WORKDIR /app

ENV PORT=8787 \
  RELAY_SQLITE_PATH=/data/relay.sqlite \
  RELAY_STATIC_DIR=apps/web/.svelte-kit/output/client

RUN mkdir -p /data && chown node:node /data

# `build:node` bundles every dependency but better-sqlite3 into server.mjs, so the runtime
# carries the bundle, the website's client output, the migrations, and that one native module
# — its prebuilt binary — and nothing else: no package manager, no compiler, no second install.
COPY --from=builder --chown=node:node /app/apps/relay/dist/node/server.mjs apps/relay/dist/node/server.mjs
COPY --from=builder --chown=node:node /app/apps/web/.svelte-kit/output/client apps/web/.svelte-kit/output/client
COPY --from=builder --chown=node:node /app/apps/relay/migrations apps/relay/migrations
COPY --from=builder --chown=node:node /app/runtime-modules/better-sqlite3 node_modules/better-sqlite3

VOLUME /data
EXPOSE 8787

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||'8787')+'/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

CMD ["node", "apps/relay/dist/node/server.mjs"]
