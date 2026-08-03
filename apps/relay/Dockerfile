FROM oven/bun:1.3.10-alpine AS build

WORKDIR /src
COPY package.json pnpm-lock.yaml ./
COPY apps/cli/package.json apps/cli/package.json
COPY apps/relay/package.json apps/relay/package.json
COPY apps/web/package.json apps/web/package.json
COPY packages/protocol/package.json packages/protocol/package.json
COPY packages/quota-model/package.json packages/quota-model/package.json
COPY packages/provider/package.json packages/provider/package.json
COPY packages/relay-core/package.json packages/relay-core/package.json
RUN bun install --production
COPY apps/relay/migrations apps/relay/migrations
COPY apps/relay/src apps/relay/src
COPY packages/protocol/src packages/protocol/src
COPY packages/relay-core/src packages/relay-core/src
RUN bun build --compile --minify --outfile /out/QuotaRelay apps/relay/src/self-hosted.ts

FROM alpine:3.22

RUN apk add --no-cache libgcc libstdc++ \
    && addgroup -S quota && adduser -S -G quota quota \
    && mkdir -p /var/lib/quota \
    && chown -R quota:quota /var/lib/quota
COPY --from=build /out/QuotaRelay /usr/local/bin/QuotaRelay

USER quota
ENV HOST=0.0.0.0
ENV PORT=8080
ENV QUOTA_RELAY_DATABASE_PATH=/var/lib/quota/quota-relay.db
VOLUME ["/var/lib/quota"]
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/QuotaRelay"]
