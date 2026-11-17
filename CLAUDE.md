# backend-rest-django

REST API backend built with Django and Django REST Framework. It is a production service, so security, data integrity and backward compatibility come before speed of delivery.

## Stack

- **Python** 3.13, **Django** 5.2 LTS, **Django REST Framework** 3.16
- **PostgreSQL** 16 (also in tests; never use SQLite)
- **Redis** for cache and as the Celery broker; **Celery** for background jobs
- **uv** for dependencies (`pyproject.toml` + `uv.lock`)
- **pytest** + `pytest-django` + `factory_boy` for tests
- **ruff** for lint and format, **mypy** + `django-stubs` + `djangorestframework-stubs` for types
- **drf-spectacular** for the OpenAPI schema
- **django-environ** for configuration from environment variables
- **gunicorn** as the production WSGI server
- **Local:** everything runs in docker compose (api, worker, db, redis)
- **Production:** AWS, using the same Docker image as local (see "Environments and deployment")

## Commands

All commands run inside the `api` container. Always run Python through `uv run`. Never use `pip install`; add dependencies with `uv add <pkg>` (or `uv add --dev <pkg>`) and rebuild the image.

```bash
docker compose up -d --build           # start api, worker, db, redis
docker compose logs -f api             # follow app logs
docker compose down                    # stop (add -v to also delete the local database)

docker compose exec api uv run python manage.py migrate
docker compose exec api uv run python manage.py createsuperuser
docker compose exec api uv run python manage.py shell

docker compose exec api uv run pytest                          # full test suite
docker compose exec api uv run pytest apps/<app>/tests/test_x.py::test_name
docker compose exec api uv run pytest --cov=apps --cov-report=term-missing

docker compose exec api uv run ruff check . --fix              # lint
docker compose exec api uv run ruff format .                   # format
docker compose exec api uv run mypy .                          # type check

docker compose exec api uv run python manage.py makemigrations <app>
docker compose exec api uv run python manage.py makemigrations --check --dry-run
docker compose exec api uv run python manage.py spectacular --file schema.yml
```

Before saying a task is done, run: `ruff check`, `ruff format --check`, `mypy`, `pytest`, and `makemigrations --check`. All must pass.

## Project layout

```
config/
  settings/
    base.py        # shared settings
    local.py       # development
    test.py        # pytest (DJANGO_SETTINGS_MODULE=config.settings.test)
    production.py  # production hardening
  urls.py          # root URLconf, mounts /api/v1/
  celery.py
  asgi.py / wsgi.py
apps/
  <app>/
    models.py
    services.py    # write operations / business logic
    selectors.py   # read queries
    serializers.py
    views.py
    urls.py
    admin.py
    tasks.py       # Celery tasks
    tests/
      factories.py
      test_models.py
      test_services.py
      test_api.py
common/            # shared base models, permissions, pagination, exceptions, utils
Dockerfile         # one multi-stage image for local and production
docker-compose.yml # local only; never used in AWS
.env.example       # every environment variable, with safe dummy values
```

New apps go in `apps/` and are registered as `apps.<name>` in `INSTALLED_APPS`.

## Architecture

- **Views are thin.** They handle HTTP only: authentication, permissions, validation through serializers, and calling a service or selector. No business logic in views or serializers.
- **Services** (`services.py`) hold all writes and business rules. They are plain functions with keyword-only arguments and type hints, e.g. `def order_create(*, user: User, items: list[Item]) -> Order:`.
- **Selectors** (`selectors.py`) hold non-trivial read queries and own `select_related` / `prefetch_related`.
- **Serializers** validate input and shape output. Use separate input and output serializers when they differ.
- Wrap multi-step writes in `transaction.atomic()`. Trigger Celery tasks with `transaction.on_commit(...)`, never inside the transaction directly.
- Models inherit from `common.models.BaseModel` (UUID primary key, `created_at`, `updated_at`).
- Use a custom user model (`apps.users.User`) and reference it through `settings.AUTH_USER_MODEL` or `get_user_model()`.

## API conventions

- All endpoints live under `/api/v1/`. Breaking changes require a new version; never change the shape of an existing response in place.
- Resource URLs are plural nouns in kebab-case: `/api/v1/purchase-orders/`.
- JSON fields are `snake_case`.
- Every list endpoint is paginated (default page size 20, max 100) and has a deterministic `ordering`.
- Default permission is `IsAuthenticated`. Every endpoint states its permissions explicitly; `AllowAny` needs a comment saying why.
- Errors use one consistent format from `common.exceptions`:
  `{"type": "...", "detail": "...", "errors": {...}}`
- Use the correct status codes: 201 on create, 204 on delete, 400 validation, 401 unauthenticated, 403 forbidden, 404 not found, 409 conflict.
- Every endpoint has a drf-spectacular schema (`@extend_schema` where inference is not enough). Regenerate `schema.yml` when the API changes.

## Environments and deployment

| | Local | AWS production |
|---|---|---|
| App | docker compose `api` (runserver) | container running gunicorn |
| Worker | docker compose `worker` | separate container, same image |
| Database | `postgres:16` container | Amazon RDS for PostgreSQL |
| Cache / broker | `redis` container | Amazon ElastiCache (Redis) |
| Media files | local volume | Amazon S3 via `django-storages` |
| Static files | runserver | S3 (+ CloudFront) or WhiteNoise |
| Secrets | `.env` file | AWS Secrets Manager / SSM Parameter Store, injected as env vars |
| Logs | stdout | stdout → CloudWatch Logs |

Rules that keep the app deployable:

- **The 12-factor rule:** all configuration comes from environment variables. The code never reads AWS secrets directly and never checks "am I on AWS"; only `DJANGO_SETTINGS_MODULE` and env vars differ between environments.
- **Containers are stateless.** Never write files to the local disk in production code; use the configured storage (`default_storage`) so uploads go to S3.
- **Same image everywhere.** Don't add dependencies or setup steps that exist only locally or only in AWS.
- **Migrations run as a separate one-off task** before the new version starts, never on container startup. Because old and new code run side by side during a deploy, every migration must be backward compatible with the previous release (see migration rules below).
- **Health checks:** `GET /health/` returns 200 without authentication and without touching the database (for the load balancer). `GET /health/ready/` also checks the database and Redis.
- **Behind the load balancer:** production sets `SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")` and `USE_X_FORWARDED_HOST`; don't remove them.
- **Logging** in production is structured JSON to stdout so CloudWatch can search it. Include a request ID in every log line.
- **Celery tasks** must be idempotent and safe to retry, since workers can be stopped at any time during deploys or scaling.
- Never hardcode AWS account IDs, regions, bucket names, ARNs or hostnames; they are env vars.
- Infrastructure (Terraform/CDK/etc.) is not in this repository yet. Don't create AWS resources or run AWS CLI commands that change anything.

## Database and migrations

- **Never edit or delete a migration that has been merged.** Create a new one.
- One migration per logical change, with a descriptive name: `makemigrations <app> --name add_status_to_order`.
- Migrations must be safe on a live database:
  - Add new columns as nullable or with a default; backfill in a separate data migration.
  - Remove or rename columns in two steps (stop using it in code first, drop it in a later release).
  - Create indexes on large tables with `AddIndexConcurrently` (non-atomic migration).
- Data migrations use `RunPython` with a reverse function and use `apps.get_model()`, never direct model imports.
- Avoid N+1 queries. Use `select_related` / `prefetch_related` and assert query counts in tests (`django_assert_num_queries`) for list endpoints.
- Add database constraints (`UniqueConstraint`, `CheckConstraint`) for invariants; don't rely on application code alone.

## Testing

- Every new feature or bug fix comes with tests. A bug fix starts with a test that fails.
- Use `factory_boy` factories from `tests/factories.py`; no fixtures in JSON.
- Test services directly for business logic; test endpoints with DRF's `APIClient` for status codes, permissions and response shape.
- For each endpoint, cover: success, validation error, unauthenticated (401), and unauthorized (403).
- Mock external HTTP calls and Celery tasks; tests must not hit the network.
- Coverage target: 90% for `apps/`. Don't lower it.

## Code style

- ruff configuration in `pyproject.toml` is the source of truth; don't argue with the formatter.
- Type hints on all function signatures. New code must pass mypy with no new `# type: ignore` unless explained in a comment.
- Use absolute imports (`from apps.orders.services import order_create`).
- Use `logging.getLogger(__name__)`; never `print`. Don't log secrets, tokens or personal data.
- Write comments for *why*, not *what*. Docstrings on public services and selectors.

## Security

- Secrets come only from environment variables (from `.env` locally, from Secrets Manager / SSM in AWS). Never hardcode them and never commit `.env`; keep `.env.example` up to date when adding a variable.
- Never use AWS access keys in code or settings. In AWS the app gets permissions from its IAM role; `boto3` and `django-storages` pick them up automatically.
- Never disable CSRF, authentication or permission checks to make something work.
- Never use raw SQL with string formatting; use the ORM or parameterized queries.
- Validate and limit file uploads (type and size).
- Filter querysets by the requesting user or tenant; never trust IDs from the client without an ownership check.
- `production.py` must keep `DEBUG = False`, `SECURE_*` settings, HSTS, secure cookies and a strict `ALLOWED_HOSTS`.
- Run `uv run python manage.py check --deploy --settings=config.settings.production` after changing production settings.

## Git workflow

- Branch from `main`: `feat/<short-name>`, `fix/<short-name>`, `chore/<short-name>`.
- Conventional Commits: `feat(orders): add cancel endpoint`.
- Keep pull requests small and focused. Include migrations and tests in the same PR as the code that needs them.
- Never push directly to `main`, force-push shared branches, or commit without the checks above passing.

## Do not

- Edit merged migrations, `uv.lock` by hand, or files under `.venv/`.
- Add a dependency without saying why; prefer the standard library and existing dependencies.
- Change public API responses without a new API version.
- Put business logic in views, serializers, signals or `save()` overrides.
- Use Django signals for business logic; call services explicitly.
- Catch broad exceptions (`except Exception:`) without re-raising or logging them.
- Use `print`, `breakpoint()` or leave commented-out code in commits.
