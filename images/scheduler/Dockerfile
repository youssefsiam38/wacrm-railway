# syntax=docker/dockerfile:1
#
# The cron pinger for the wacrm Railway template: Alpine, curl and a loop. See entrypoint.sh.
ARG ALPINE_IMAGE=docker.io/library/alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40
FROM ${ALPINE_IMAGE}

ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

RUN apk add --no-cache curl \
    && curl --version >/dev/null \
    && adduser -S -H -u 10001 scheduler

COPY --chmod=0755 images/scheduler/entrypoint.sh /usr/local/bin/wacrm-scheduler-entrypoint
COPY licenses/ /usr/share/licenses/wacrm-railway/

USER scheduler

LABEL org.opencontainers.image.title="wacrm-railway-scheduler" \
      org.opencontainers.image.description="Calls wacrm's automation and flow cron endpoints on a schedule, for the wacrm Railway template." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/wacrm-railway" \
      org.opencontainers.image.url="https://github.com/youssefsiam38/wacrm-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

ENTRYPOINT ["/usr/local/bin/wacrm-scheduler-entrypoint"]
