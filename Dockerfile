# syntax=docker/dockerfile:1
#
# One image for every environment (see CLAUDE.md, "Same image everywhere").
#
#   prod  -> gunicorn, runtime deps only. This is what AWS runs.
#   dev   -> runserver, runtime + dev deps, uv available for `uv run` / `uv add`.
#
# Build:  docker build --target prod -t backend-rest-django:prod .
# Local:  docker compose up -d --build   (uses the dev target)

# ---------------------------------------------------------------------------
# Versions. ARGs declared before the first FROM are only visible to FROM lines,
# so stages that need them must redeclare them.
# ---------------------------------------------------------------------------
ARG PYTHON_VERSION=3.13
ARG DEBIAN_RELEASE=trixie
# Keep in sync with the uv used to generate uv.lock.
ARG UV_VERSION=0.13.8

# Named stage so the uv binary can be copied with a pinned version.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# ---------------------------------------------------------------------------
# base: shared Python runtime settings for every stage
# ---------------------------------------------------------------------------
# TODO: pin by digest (python:3.13-slim-trixie@sha256:...) once Docker access
# is confirmed, so rebuilds are reproducible; bump it deliberately for patches.
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_RELEASE} AS base

ENV \
    # Don't write .pyc at runtime; uv precompiles at build time instead.
    PYTHONDONTWRITEBYTECODE=1 \
    # Flush stdout/stderr immediately so logs reach CloudWatch without delay.
    PYTHONUNBUFFERED=1 \
    # Print Python tracebacks on segfaults (C extensions such as psycopg).
    PYTHONFAULTHANDLER=1 \
    # The virtualenv lives outside /app so the dev bind mount (.:/app) can't hide it.
    VIRTUAL_ENV=/opt/venv \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH="/opt/venv/bin:$PATH"

# ---------------------------------------------------------------------------
# builder: resolve dependencies from uv.lock into /opt/venv
# ---------------------------------------------------------------------------
FROM base AS builder

COPY --from=uv /uv /bin/uv

ENV \
    # Compile .pyc once at build time: faster container start.
    UV_COMPILE_BYTECODE=1 \
    # Cache mounts are a different filesystem; copy instead of hardlinking.
    UV_LINK_MODE=copy \
    # Use the image's Python; never let uv download another interpreter.
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app

# Only pyproject.toml and uv.lock are bind-mounted, so this layer is reused
# until dependencies change; editing code doesn't trigger a reinstall.
# --locked fails the build if uv.lock is out of date with pyproject.toml.
# --no-install-project: the project is a Django app, not an installable package.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv sync --locked --no-install-project --no-dev

# Same as above plus the dev dependency group (pytest, ruff, mypy...).
FROM builder AS builder-dev
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv sync --locked --no-install-project

# ---------------------------------------------------------------------------
# runtime-base: minimal OS + unprivileged user. No compilers, no curl.
# psycopg[binary] bundles libpq, so no apt packages are needed at all.
# ---------------------------------------------------------------------------
FROM base AS runtime-base

# Fixed UID/GID. Defaults match the usual first Linux user, so files the dev
# container writes into the bind mount (e.g. migrations) belong to you.
ARG APP_UID=1000
ARG APP_GID=1000
RUN groupadd --system --gid "${APP_GID}" app \
    && useradd --system --uid "${APP_UID}" --gid app \
       --home-dir /app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
EXPOSE 8000

# ---------------------------------------------------------------------------
# prod: the image AWS runs
# ---------------------------------------------------------------------------
FROM runtime-base AS prod

ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="backend-rest-django" \
      org.opencontainers.image.revision="${GIT_SHA}"

# venv and code stay root-owned: the app user can read and run them but not
# modify them, so a compromised process can't rewrite the application.
COPY --from=builder /opt/venv /opt/venv
COPY . /app

USER app

# Exec form (no shell wrapper) so gunicorn receives SIGTERM directly and shuts
# down gracefully during deploys. In ECS, enable `initProcessEnabled` for tini.
# Worker count comes from WEB_CONCURRENCY (read natively by gunicorn).
# Logs go to stdout/stderr ("-") for CloudWatch.
CMD ["gunicorn", "config.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--worker-tmp-dir", "/dev/shm", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]

# ---------------------------------------------------------------------------
# dev: local development via docker compose
# ---------------------------------------------------------------------------
FROM runtime-base AS dev

# uv in the image so `docker compose exec api uv run ...` works (CLAUDE.md).
COPY --from=uv /uv /uvx /bin/

ENV \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0 \
    # The app user has no writable home; keep uv's cache in /tmp.
    UV_CACHE_DIR=/tmp/uv-cache

# Owned by app so `uv add` / `uv sync` inside the container can update it.
COPY --from=builder-dev --chown=app:app /opt/venv /opt/venv
# Source is normally bind-mounted by compose; copied too so the image runs alone.
COPY --chown=app:app . /app

USER app

CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
