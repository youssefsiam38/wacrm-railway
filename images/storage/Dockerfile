# syntax=docker/dockerfile:1
#
# Supabase Storage for Railway. The only change from the stock image is that the two API keys it
# needs are minted from JWT_SECRET at start-up rather than passed in: they are signed JWTs, which a
# Railway template variable cannot produce.
ARG STORAGE_IMAGE=docker.io/supabase/storage-api:v1.74.0@sha256:f1546fac6d1c7e345428ac904bfaa7be7cecd50a1f549fe1cf38c628a7b15c85
FROM ${STORAGE_IMAGE}

ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown

COPY lib/mint-supabase-keys.mjs /usr/local/lib/wacrm/mint-supabase-keys.mjs
COPY --chmod=0755 images/storage/entrypoint.sh /usr/local/bin/wacrm-storage-entrypoint
COPY licenses/ /usr/share/licenses/wacrm-railway/

ENV STORAGE_BACKEND=file \
    FILE_STORAGE_BACKEND_PATH=/var/lib/storage \
    FILE_SIZE_LIMIT=52428800 \
    REQUEST_ALLOW_X_FORWARDED_PATH=true \
    ENABLE_IMAGE_TRANSFORMATION=false \
    TENANT_ID=stub \
    GLOBAL_S3_BUCKET=stub \
    REGION=local \
    SERVER_HOST=:: \
    PORT=5000

LABEL org.opencontainers.image.title="wacrm-railway-storage" \
      org.opencontainers.image.description="Supabase Storage for the wacrm Railway template, with API keys minted from the shared JWT secret." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/wacrm-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENTRYPOINT ["/usr/local/bin/wacrm-storage-entrypoint"]
CMD ["node", "dist/start/server.js"]
