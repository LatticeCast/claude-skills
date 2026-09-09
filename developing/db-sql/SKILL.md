---
name: developing/db-sql
description: SQL writing — INSERT, UPSERT, indexing, JSONB. Use when writing or reviewing SQL statements, migrations, or schema changes.
user-invocable: false
version: 0.11.0
---

# Safe SQL Rules

## PG Roles & Schemas: Least Privilege

### Principle: roles start with ZERO privileges — add incrementally

A newly created role has NO access to anything. You must explicitly grant every capability.

### Schema-based permission model

```
public   — user-facing data (tables, rows, workspaces, workspace_members)
auth     — authentication (users, user_info)
private  — internal system data (migrations, config)
```

### Roles

| Role | Purpose | Schemas |
|------|---------|---------|
| `dba` | Migrations (DDL) | ALL schemas — CREATE/ALTER/DROP |
| `app` | General API | public: CRUD, auth: SELECT only |
| `login_mgr` | Login/auth | auth: SELECT/INSERT/UPDATE only |

### Creating roles (step by step)

```sql
-- 1. Create role (NO privileges by default)
CREATE ROLE app;

-- 2. Grant USAGE on schema (required to see objects in it)
GRANT USAGE ON SCHEMA public TO app;

-- 3. Grant table-level privileges
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app;

-- 4. Grant sequence usage (needed for SERIAL/BIGSERIAL columns)
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app;

-- 5. Set DEFAULT privileges (for tables created in the future by dba)
ALTER DEFAULT PRIVILEGES FOR ROLE dba IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app;
ALTER DEFAULT PRIVILEGES FOR ROLE dba IN SCHEMA public
  GRANT USAGE ON SEQUENCES TO app;

-- 6. Create login user inheriting role
CREATE USER app_user WITH PASSWORD 'secret' IN ROLE app;
```

### Key rules

- **Only DBA can modify tables** — CREATE TABLE, ALTER TABLE, DROP TABLE are DDL operations. Only `dba` role has these privileges. Migration SQL runner MUST use DBA connection.
- **`app` and `login_mgr` are DML-only** — SELECT/INSERT/UPDATE/DELETE. They cannot create, alter, or drop any database object.
- **`GRANT USAGE ON SCHEMA`** — required first, otherwise role can't even see the schema
- **`GRANT ... ON ALL TABLES`** — covers existing tables only
- **`ALTER DEFAULT PRIVILEGES`** — covers future tables (must specify `FOR ROLE <owner>`)
- **`FOR ROLE dba`** is critical — default privileges apply to objects created BY that role
- **Never GRANT on `public` schema to `login_mgr`** — login should only touch auth tables
- **Test**: `psql -U app_user -c "DROP TABLE public.rows"` must fail
- **Test**: `psql -U app_user -c "ALTER TABLE public.rows ADD COLUMN x TEXT"` must fail

### Cross-schema SELECT

If `app` needs to read from `auth` schema (e.g. resolve user display names):

```sql
GRANT USAGE ON SCHEMA auth TO app;
GRANT SELECT ON ALL TABLES IN SCHEMA auth TO app;
ALTER DEFAULT PRIVILEGES FOR ROLE dba IN SCHEMA auth
  GRANT SELECT ON TABLES TO app;
```

### search_path per connection

Set `search_path` when creating the SQLAlchemy engine so models resolve unqualified table names correctly:

```python
# app engine: sees public + auth (read-only)
engine = create_async_engine(url, connect_args={"server_settings": {"search_path": "public,auth"}})

# login engine: sees auth only  
engine = create_async_engine(url, connect_args={"server_settings": {"search_path": "auth"}})

# dba engine: sees everything
engine = create_async_engine(url, connect_args={"server_settings": {"search_path": "public,auth,private"}})
```

### PG logging (docker-compose)

Enable native logging for debugging permission issues:

```yaml
command: >
  postgres
  -c logging_collector=on
  -c log_directory=/var/log/postgresql
  -c log_statement=all
  -c log_connections=on
  -c log_disconnections=on
```

## Align columns + function params

Pad name/type so reviewers scan the type column. Applies to
`CREATE TABLE`, function parameters, and `DECLARE` blocks. Spaces only.

```sql
CREATE TABLE IF NOT EXISTS public.workspaces (
    workspace_id   UUID      NOT NULL DEFAULT gen_random_uuid(),
    workspace_name VARCHAR   NOT NULL DEFAULT '',
    created_at     TIMESTAMP NOT NULL DEFAULT now(),
    updated_at     TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id)
);

CREATE OR REPLACE FUNCTION public.create_workspace(
    p_workspace_name VARCHAR,
    p_by             UUID
) RETURNS JSONB

```

### Notes

- Use **spaces only**, never tabs. PG, psql output, and most diffs render
  spaces consistently; tabs drift between editors.
- The `.sqlfluff` config for this project excludes `layout.spacing`
  (LT01) and `layout.indent` (LT02) exactly so hand-aligned blocks
  survive `sqlfluff fix`. Do **not** run `sqlfluff fix` on files that
  have intentional alignment — it'll strip the spaces back to one.
- When adding a new column to an existing aligned table, re-flow the
  whole table's alignment if the new name is wider. The whole block
  should look like one table after the edit.

### Wrapping long GRANT / REVOKE

When a single-line GRANT/REVOKE on a function exceeds 80 chars, break
after `ON` and indent `FUNCTION` 4 spaces on the next line. Keep the
function signature + `FROM`/`TO` clause on the same indented line so the
function being granted is visually grouped.

```sql
REVOKE ALL    ON
    FUNCTION public.add_column(UUID, VARCHAR, TEXT, TEXT, JSONB, UUID) FROM public;

GRANT EXECUTE ON
    FUNCTION public.add_column(UUID, VARCHAR, TEXT, TEXT, JSONB, UUID) TO app, mgr;
```

Aligning `REVOKE ALL    ON` against `GRANT EXECUTE ON` keeps the keyword
columns visually aligned across the whole block.


## Idempotent SQL: Always use IF EXISTS / IF NOT EXISTS

All SQL must be safe to run multiple times. See [safe_example.sql](safe_example.sql) for complete patterns.

Key patterns:
- `CREATE TABLE IF NOT EXISTS` / `DROP TABLE IF EXISTS`
- `CREATE SCHEMA IF NOT EXISTS` / `DROP SCHEMA IF EXISTS`
- `CREATE INDEX IF NOT EXISTS` / `DROP INDEX IF EXISTS`
- Roles/Users/Columns have no `IF NOT EXISTS` — wrap in `DO $$ BEGIN IF NOT EXISTS (SELECT ...) THEN ... END IF; END $$;`
- Triggers: `DROP TRIGGER IF EXISTS` then `CREATE TRIGGER`
- Functions: `CREATE OR REPLACE FUNCTION`
- GRANTs are naturally idempotent (re-granting is a no-op)

## ALWAYS DUMP BEFORE MIGRATING

**Before any migrate command on a real DB (`--apply-only` or the default
full flow), clone the live DB first.** `--dump` does a `CREATE DATABASE
db_<YYYYMMDD_HHMMSS> WITH TEMPLATE db` — a sibling database on the same
PG instance, byte-identical. AWS Backup covers prod; dev/staging relies
on this clone.

```bash
# Step 1 — ALWAYS, before any migrate command:
docker compose --profile migration run --rm \
  --entrypoint python migration migrate.py --dump
# → creates DB `db_<YYYYMMDD_HHMMSS>` on the same PG instance

# Step 2 — then run the migration:
docker compose --profile migration run --rm \
  --entrypoint python migration migrate.py --apply-only

# Restore if needed (rename swap, instant):
docker compose exec -T db psql -U dba_user -d postgres <<'SQL'
DROP DATABASE "db";
ALTER DATABASE "db_<YYYYMMDD_HHMMSS>" RENAME TO "db";
SQL
```

The clone uses `CREATE DATABASE WITH TEMPLATE`, which requires the source
DB to have no other active connections. `--dump` calls
`pg_terminate_backend` on every other session before the clone, then
sessions reconnect automatically. Storage cost ≈ size of the live DB
(PG copies the data dir bytes).

This rule is non-negotiable for any command that mutates the live DB.
Past incident (2026-05-15): a `docker compose down -v` before pulling a
new migration permanently destroyed user data because no clone existed.

## Lint & Test: Migration Runner

Before committing migration SQL, validate with the dockerized runner:

```bash
# Full flow: lint → verify checksums → test → apply
docker compose --profile migration run --rm migration

# Lint + checksum + test (no apply to real DB)
docker compose --profile migration run --rm \
  --entrypoint python migration migrate.py --test-only

# Skip lint/test, apply directly (CI / prod deploy)
docker compose --profile migration run --rm \
  --entrypoint python migration migrate.py --apply-only

# Regenerate checksums.txt after editing any V*.sql — commit alongside
docker compose --profile migration run --rm \
  --entrypoint python migration migrate.py --hash

# Dump live DB to .tmp/ before any migrate — see "ALWAYS DUMP BEFORE MIGRATING" above
docker compose --profile migration run --rm \
  --entrypoint python migration migrate.py --dump
```

- **SQLFluff** lints all `V*.sql` with `max_line_length=80`. Violations block the flow.

- **SQLFluff** lints all `V*.sql` with `max_line_length=80`. SQLFluff's
  `align` rule only supports `create_table_statement`, so multi-space
  alignment in function parameters, GRANT/REVOKE blocks, and DECLARE
  sections will always fire **LT01** (spacing), **LT02** (indent on
  wraps), and **LT05** (line >80 due to alignment padding). These are
  **expected red lights** — we keep the alignment for readability and
  bypass lint via `--apply-only` when applying. Only investigate lint
  output for rule codes outside `LT01 / LT02 / LT05` — those signal
  real issues (capitalisation, structure, references).

- **Temp PG test** spins up a fresh container, applies all migrations, verifies schema + RLS.
- **Checksum integrity** — committed `migration/checksums.txt` is SHA-256 of every V*.sql. Mismatch aborts before any DB touch.
- **DB-side checksum** — `schema_migrations.checksum` tracks applied file hashes. Tampering with an already-applied migration aborts re-apply.

### Editing workflow

1. Add new `V<N>__name.sql` (never modify an existing one)
2. `docker compose --profile migration run --rm --entrypoint python migration migrate.py --test-only` → make lint green
3. `docker compose --profile migration run --rm --entrypoint python migration migrate.py --hash` → update `checksums.txt`
4. Commit SQL file + `checksums.txt` together
5. **Dump live DB first** (`migrate.py --dump` — see top of this section).
6. Deploy: `docker compose --profile migration run --rm migration` applies to real DB

## Migrations: NEVER modify existing files

**NEVER** edit an existing `migration/*.sql` file — it may have already been applied to production databases.

**ALWAYS** create a new migration file with the next sequence number.

**Why:** Migrations are applied once and recorded. Modifying an applied migration causes drift between environments. Always move forward.

## UPSERT: Always specify conflict target

**NEVER** bare `ON CONFLICT DO NOTHING` — it silently swallows constraint violations you didn't intend.

**ALWAYS** use `ON CONFLICT (column_name) DO NOTHING` or `DO UPDATE`.

```sql
-- BAD: which constraint? all of them? silent data loss
INSERT INTO users (email, name) VALUES ('a@b.com', 'A')
ON CONFLICT DO NOTHING;

-- GOOD: explicit — only skip on email duplicate
INSERT INTO users (email, name) VALUES ('a@b.com', 'A')
ON CONFLICT (email) DO NOTHING;

-- GOOD: upsert with explicit target
INSERT INTO users (email, name) VALUES ('a@b.com', 'A')
ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name;
```

**Why:** Bare `ON CONFLICT` catches ANY unique constraint — if a second unique column conflicts unexpectedly, the row silently disappears. Debugging this is painful.

## JSONB

See [jsonb.md](jsonb.md) for GIN indexing, query patterns, and containment operators.
