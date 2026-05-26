# syntax=docker/dockerfile:1
# RapidPro v9 application image (multi-arch). Single-version (v9-only) build.
# Static assets are baked at build time; runtime serves them via WhiteNoise.

# ---------------------------------------------------------------------------
# Stage 1: builder (Python venv + Node assets, then bake collectstatic/compress)
# ---------------------------------------------------------------------------
FROM python:3.10-slim-bookworm AS builder

ARG RAPIDPRO_REPO=rapidpro/rapidpro
ARG RAPIDPRO_VERSION=v9.0.0
ARG NODE_MAJOR=20

ENV PIP_RETRIES=120 \
    PIP_TIMEOUT=400 \
    PIP_DEFAULT_TIMEOUT=400 \
    C_FORCE_ROOT=1 \
    VIRTUAL_ENV=/venv \
    POETRY_NO_INTERACTION=1

# Build + GeoDjango + asset toolchain deps. Node 20 from NodeSource.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg wget tar \
        build-essential postgresql-client \
        libmagic-dev libpcre3-dev libffi-dev libssl-dev \
        libgeos-dev libgdal-dev libproj-dev gdal-bin; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    npm install -g yarn; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /rapidpro

# Fetch RapidPro source for the pinned version.
RUN set -eux; \
    echo "Downloading RapidPro ${RAPIDPRO_VERSION} from https://github.com/${RAPIDPRO_REPO}"; \
    wget -O rapidpro.tar.gz "https://github.com/${RAPIDPRO_REPO}/archive/${RAPIDPRO_VERSION}.tar.gz"; \
    tar -xf rapidpro.tar.gz --strip-components=1; \
    rm rapidpro.tar.gz

# Python venv + dependencies (poetry installs into the active venv). gunicorn is
# an upstream dep; whitenoise is added here (not shipped by v9) to serve static.
ENV PATH="/venv/bin:/rapidpro/node_modules/.bin:$PATH"
RUN set -eux; \
    python3 -m venv /venv; \
    pip install -U pip poetry; \
    poetry install --no-interaction; \
    pip install gunicorn whitenoise

# JS deps for the static bundles. django-compressor calls bare `lessc`; v9 needs
# the latest LESS (handles CSS custom properties inside color functions), so
# install it globally and drop the old pinned shim so the global one resolves.
RUN yarn install --frozen-lockfile || yarn install
RUN npm install -g less && rm -f /rapidpro/node_modules/.bin/lessc

# Our settings overlay must be present before baking static.
COPY settings.py /rapidpro/temba/settings.py

# Bake static: collectstatic + offline compression. Dummy env so settings load
# without real services; no DB access occurs in these commands.
ARG RAPIDPRO_VERSION
ENV RAPIDPRO_VERSION=${RAPIDPRO_VERSION} \
    SECRET_KEY=build-time-dummy-key \
    DATABASE_URL=postgresql://u:p@localhost/db \
    REDIS_URL=redis://localhost:6379/0 \
    DJANGO_COMPRESSOR=on \
    AWS_STATIC=  \
    AWS_MEDIA=
# v9 templates are .html (not .haml) and use a dedicated compress settings module.
RUN set -eux; \
    python manage.py collectstatic --noinput --no-post-process; \
    python manage.py compress --extension=".html" --settings=temba.settings_compress --force -v0

# ---------------------------------------------------------------------------
# Stage 2: runtime (slim, non-root, no Node, baked static)
# ---------------------------------------------------------------------------
FROM python:3.10-slim-bookworm

ARG RAPIDPRO_REPO=rapidpro/rapidpro
ARG RAPIDPRO_VERSION=v9.0.0

# Runtime shared libs only (GeoDjango + libmagic + psql client for the migrate Job).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-client libmagic1 libpcre3 \
        libgeos-c1v5 libgdal32 libproj25 \
        ca-certificates tini; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 1000 rapidpro; \
    useradd -r -u 1000 -g rapidpro -d /rapidpro rapidpro

COPY --from=builder --chown=rapidpro:rapidpro /venv /venv
COPY --from=builder --chown=rapidpro:rapidpro /rapidpro /rapidpro

# Runtime helpers / config overlays.
COPY --chown=rapidpro:rapidpro stack/startup.sh /startup.sh
COPY --chown=rapidpro:rapidpro stack/gunicorn.conf.py /rapidpro/gunicorn.conf.py
COPY --chown=rapidpro:rapidpro stack/500.html /rapidpro/templates/500.html
COPY --chown=rapidpro:rapidpro stack/init_db.sql /rapidpro/init_db.sql
COPY --chown=rapidpro:rapidpro stack/clear-compressor-cache.py /rapidpro/clear-compressor-cache.py
RUN chmod +x /startup.sh

ENV PATH="/venv/bin:$PATH" \
    VIRTUAL_ENV=/venv \
    PYTHONUNBUFFERED=1 \
    RAPIDPRO_VERSION=${RAPIDPRO_VERSION} \
    STARTUP_CMD="gunicorn temba.wsgi:application -c /rapidpro/gunicorn.conf.py"

WORKDIR /rapidpro
USER rapidpro
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/').status < 500 else 1)" || exit 1

LABEL org.opencontainers.image.title="RapidPro" \
      org.opencontainers.image.description="RapidPro visual messaging application platform (v9)." \
      org.opencontainers.image.url="https://www.rapidpro.io/" \
      org.opencontainers.image.source="https://github.com/morrismukiri/rapidpro-docker" \
      org.opencontainers.image.version="${RAPIDPRO_VERSION}" \
      org.opencontainers.image.vendor="Nyaruka, UNICEF, and individual contributors." \
      io.rapidpro.app-source="https://github.com/${RAPIDPRO_REPO}"

ENTRYPOINT ["tini", "--"]
CMD ["/startup.sh"]
