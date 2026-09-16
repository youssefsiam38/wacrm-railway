# syntax=docker/dockerfile:1
#
# wacrm for Railway.
#
# Upstream publishes no image: its Dockerfile is built by each deployer, with the Supabase URL and
# anon key passed as build arguments, because Next.js inlines NEXT_PUBLIC_* values into the bundle at
# build time. A one-click template cannot rebuild per deploy with values that do not exist yet (the
# gateway's domain, a key derived from a generated secret), so this image is built once, from a
# pinned upstream commit, with unmistakable placeholder values, and the entrypoint writes the real
# values into the built files at start-up.
#
# One upstream file is patched, and the build fails if the patch stops applying: the signup page
# also sends the invitation token it already holds, as user metadata, so that the database can admit
# invited people while refusing everyone else. See images/app/gate.sql.
ARG NODE_IMAGE=docker.io/library/node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293
ARG WACRM_COMMIT=80c3f9a1aecdaf21b98311f230fdaaaec7d85f7d

# ---------------------------------------------------------------------------------------------
# Upstream source at an exact commit. Fetching by commit id makes git verify the content.
# ---------------------------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS source
ARG WACRM_COMMIT
RUN apk add --no-cache git \
    && git init -q /src \
    && git -C /src fetch -q --depth 1 https://github.com/ArnasDon/wacrm.git "${WACRM_COMMIT}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test "$(git -C /src rev-parse HEAD)" = "${WACRM_COMMIT}" \
    && rm -rf /src/.git
COPY images/app/patch-signup.mjs /tmp/patch-signup.mjs
RUN node /tmp/patch-signup.mjs /src/src/app/\(auth\)/signup/page.tsx

# ---------------------------------------------------------------------------------------------
# Dependencies and build, as upstream's own Dockerfile does them.
# ---------------------------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY --from=source /src/package.json /src/package-lock.json ./
RUN npm ci

FROM ${NODE_IMAGE} AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=source /src/ ./
# Placeholders, replaced at start-up by images/app/fill-public-env.mjs. URL-shaped where the build may
# parse them; `.invalid` is reserved and can never resolve.
#
# The UI language cannot be a placeholder: the bundler resolves messages/<locale>.json at build time
# and prerenders pages with that catalogue, so the image is built in English (upstream's default).
ENV NEXT_PUBLIC_SUPABASE_URL=https://wacrm-railway-supabase-url.invalid \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=wacrm-railway-placeholder-supabase-anon-key \
    NEXT_PUBLIC_SITE_URL=https://wacrm-railway-site-url.invalid \
    NEXT_PUBLIC_APP_LOCALE=en \
    NEXT_TELEMETRY_DISABLED=1
RUN npm run build
# Record every built file that carries a placeholder, and keep a pristine copy of each, so that the
# values can be written again on every start rather than only on the first.
COPY images/app/fill-public-env.mjs /tmp/fill-public-env.mjs
RUN node /tmp/fill-public-env.mjs --index /app/.next /opt/wacrm/pristine

# ---------------------------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runner
ARG WACRM_COMMIT
ARG WACRM_VERSION=0.8.0
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    WACRM_COMMIT=${WACRM_COMMIT}

# psql applies the migrations; upstream expects the Supabase CLI on the operator's machine for that.
RUN apk add --no-cache postgresql17-client \
    && psql --version \
    && addgroup -S nextjs && adduser -S nextjs -G nextjs

COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nextjs /app/public ./public
COPY --from=builder --chown=nextjs:nextjs /opt/wacrm/pristine /opt/wacrm/pristine
COPY --from=source /src/supabase/migrations /opt/wacrm/migrations
COPY --from=source /src/supabase/ci/verify-schema.sql /opt/wacrm/verify-schema.sql
COPY lib/mint-supabase-keys.mjs /opt/wacrm/mint-supabase-keys.mjs
COPY images/app/fill-public-env.mjs /opt/wacrm/fill-public-env.mjs
COPY images/app/bootstrap-owner.mjs /opt/wacrm/bootstrap-owner.mjs
COPY images/app/gate.sql /opt/wacrm/gate.sql
COPY --chmod=0755 images/app/migrate.sh /opt/wacrm/migrate.sh
COPY --chmod=0755 images/app/entrypoint.sh /usr/local/bin/wacrm-app-entrypoint
COPY licenses/ /usr/share/licenses/wacrm-railway/

# The standalone server and the prebuilt static chunks must both carry the placeholders, or the
# substitution would silently do nothing.
RUN test -s /opt/wacrm/pristine/.index \
    && grep -q 'static/' /opt/wacrm/pristine/.index \
    && ls /opt/wacrm/migrations/001_initial_schema.sql

USER nextjs

LABEL org.opencontainers.image.title="wacrm-railway-app" \
      org.opencontainers.image.description="wacrm, the WhatsApp CRM, built for the Railway template: migrations, invite-only signup and the owner account handled at start-up. Not affiliated with the wacrm project." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/wacrm-railway" \
      org.opencontainers.image.url="https://github.com/youssefsiam38/wacrm-railway" \
      org.opencontainers.image.documentation="https://github.com/youssefsiam38/wacrm-railway#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.wacrm-railway.upstream.commit="${WACRM_COMMIT}" \
      io.wacrm-railway.upstream.version="${WACRM_VERSION}"

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/wacrm-app-entrypoint"]
