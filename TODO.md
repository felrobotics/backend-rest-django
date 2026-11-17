# TODO

Roadmap for the Django REST backend. Order matters: each phase unblocks the next.
Every item follows the rules in `CLAUDE.md` (tests with the code, small PRs, Conventional Commits).

Legend: `[ ]` open · `[x]` done

## Phase 0: Local environment (current)

Branch: `chore/uv-setup`

- [x] `pyproject.toml` + `uv.lock` with runtime and dev dependencies
- [x] `Dockerfile` (multi-stage), `docker-compose.yml`, `.dockerignore`, `.env.example`
- [ ] Docker permissions: `id -nG` must list `docker`. Log out and back in (or reboot), then restart Claude Code.
      Check: `docker run --rm hello-world`
- [ ] `docker compose build` succeeds for every target
- [ ] Pin the base image by digest (`python:3.13-slim-trixie`); there is a TODO in the `Dockerfile`
- [ ] Set the Redis image tag to the ElastiCache engine version we will use (`redis:7.2` is a placeholder)
- [ ] Review the `.gitignore` change (`local/`, `.vscode`), then commit the setup as `chore: add docker and uv setup`
- [ ] Merge to `main` via PR

## Phase 1: Django skeleton

Goal: `docker compose up` runs api, worker, db and redis with no errors.

- [ ] `config/` project: `manage.py`, `urls.py`, `wsgi.py`, `asgi.py`
- [ ] Settings split: `base.py`, `local.py`, `test.py`, `production.py`; all values via `django-environ`
- [ ] `config/celery.py` wired into `config/__init__.py`
- [ ] `common/` package: `BaseModel` (UUID pk, `created_at`, `updated_at`), pagination (20 default, 100 max), permissions
- [ ] `common/exceptions.py`: DRF exception handler returning `{"type", "detail", "errors"}`
- [ ] Health checks: `GET /health/` (no auth, no DB) and `GET /health/ready/` (DB + Redis), with tests
- [ ] Mount `/api/v1/` in the root URLconf
- [ ] drf-spectacular: `/api/v1/schema/` and docs UI, commit `schema.yml`
- [ ] Default DRF settings: `IsAuthenticated`, pagination, exception handler, schema class

## Phase 2: Quality gates

Goal: the "done" checklist from `CLAUDE.md` is enforced, not just written down.

- [ ] ruff config in `pyproject.toml` (lint rules, format, isort)
- [ ] mypy config with `django-stubs` and DRF stubs; passes with no `# type: ignore`
- [ ] pytest against PostgreSQL (never SQLite), with a shared `conftest.py` and an `APIClient` fixture
- [ ] Coverage threshold of 90% for `apps/`, enforced
- [ ] `makemigrations --check --dry-run` in the checks
- [ ] CI (GitHub Actions): ruff, format check, mypy, pytest with a Postgres service, migrations check, schema drift check
- [ ] Pre-commit hooks for ruff (optional)
- [ ] Branch protection on `main`: PR required, CI green

## Phase 3: Users and authentication

- [ ] `apps.users` with a custom `User` (created before the first migration of any other app)
- [ ] Choose the auth scheme (JWT via `djangorestframework-simplejwt`, or session/token). Record the reason before adding the dependency.
- [ ] Register, login, refresh/logout, current-user endpoints
- [ ] Password validation and throttling on auth endpoints
- [ ] Tests per endpoint: success, validation error, 401, 403
- [ ] Admin for users

## Phase 4: First domain app (template for the rest)

Use it to prove the services/selectors/serializers pattern before building more.

- [ ] Pick the first resource and define its models and constraints
- [ ] `services.py` for writes (keyword-only args, `transaction.atomic()`)
- [ ] `selectors.py` for reads with `select_related` / `prefetch_related`
- [ ] Separate input and output serializers
- [ ] Thin views, explicit permissions, ownership filtering on every queryset
- [ ] `@extend_schema` on every endpoint
- [ ] Tests: factories, service tests, API tests, `django_assert_num_queries` on the list endpoint
- [ ] Deterministic `ordering` on every list endpoint

## Phase 5: Background jobs

- [ ] Worker runs and picks up a sample task
- [ ] Task conventions: idempotent, retry with backoff, triggered via `transaction.on_commit`
- [ ] Celery tasks mocked in tests
- [ ] Decide on periodic jobs (Celery beat) if needed

## Phase 6: Production readiness

No AWS resources are created from this repo (see `CLAUDE.md`).

- [ ] `production.py` hardening: `DEBUG=False`, `SECURE_*`, HSTS, secure cookies, strict `ALLOWED_HOSTS`,
      `SECURE_PROXY_SSL_HEADER`, `USE_X_FORWARDED_HOST`
- [ ] `manage.py check --deploy --settings=config.settings.production` passes
- [ ] Structured JSON logging to stdout with a request ID on every line (middleware)
- [ ] Media on S3 via `django-storages` using the IAM role (no access keys); static files via WhiteNoise or S3/CloudFront
- [ ] Gunicorn configuration (workers, timeouts) via env vars
- [ ] Migration runner documented as a separate one-off task, never on container start
- [ ] Production Docker target runs as non-root and has a `HEALTHCHECK`
- [ ] Error tracking (e.g. Sentry) configured by env var
- [ ] Every new env var documented in `.env.example`

## Phase 7: Documentation and housekeeping

- [ ] `README.md`: setup, commands, project layout, how to run tests
- [ ] Short architecture note: why services/selectors, API versioning policy
- [ ] Dependency update routine (`uv lock --upgrade`, reviewed in a PR)
- [ ] Security review before first production release (`/security-review`)

## Open decisions

- Auth scheme (Phase 3)
- Redis / ElastiCache engine version (Phase 0)
- Static files: WhiteNoise or S3 + CloudFront (Phase 6)
- First domain resource (Phase 4)
