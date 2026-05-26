# syntax=docker/dockerfile:1
# One parameterized image for the RapidPro Go services (mailroom, courier,
# rp-indexer, rp-archiver). Downloads the prebuilt release binary for the
# target architecture. Build with BINARY/REPO/VERSION build-args.
FROM debian:bookworm-slim AS build

# Populated automatically by BuildKit/buildah from --platform (amd64 | arm64).
ARG TARGETARCH
ARG BINARY
ARG REPO
ARG VERSION

RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    url="https://github.com/${REPO}/releases/download/v${VERSION}/${BINARY}_${VERSION}_linux_${arch}.tar.gz"; \
    echo "Downloading ${BINARY} v${VERSION} linux/${arch} from ${url}"; \
    mkdir -p /out; \
    wget -q -O /tmp/${BINARY}.tar.gz "${url}"; \
    tar -xzC /out -f /tmp/${BINARY}.tar.gz "${BINARY}"

FROM debian:bookworm-slim

ARG BINARY
ARG REPO
ARG VERSION
ARG PORT=8080
ENV SERVICE_BINARY=${BINARY}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates tini; \
    rm -rf /var/lib/apt/lists/*; \
    addgroup --system app; \
    adduser --system --ingroup app --home /home/app app; \
    mkdir -p /var/spool/${BINARY} _storage; \
    chown -R app:app /var/spool/${BINARY} _storage /home/app

COPY --from=build /out/${BINARY} /usr/local/bin/${BINARY}

EXPOSE ${PORT}
USER app

LABEL org.opencontainers.image.title="rapidpro-${BINARY}" \
      org.opencontainers.image.source="https://github.com/morrismukiri/rapidpro-docker" \
      org.opencontainers.image.version="${VERSION}" \
      io.rapidpro.component-source="https://github.com/${REPO}"

# tini reaps zombies; the service binary name is passed as CMD per build.
ENTRYPOINT ["tini", "--"]
CMD ["sh", "-c", "exec ${SERVICE_BINARY}"]
