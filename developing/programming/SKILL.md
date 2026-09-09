---
name: developing/programming
description: Post-code workflow — test, format, lint, commit. Also handles versioning (CHANGELOG.md + package version bumps). Use after implementing code changes or when the user specifies a version.
version: 0.11.0
---

# Programming Skill

Common development workflows that any project can use.

## After Code Changes

See [developing.md](developing.md) — run tests, format, lint, then commit (never commit `.tmp/`).

## Versioning & Changelog

See [writelog.md](writelog.md) — when user specifies a version, update CHANGELOG.md and bump version in package files.

## Temporary Files

- **All temp/scratch work MUST go in `./.tmp/`** (project-local), never `/tmp/`.
- `.tmp/` should be in `.gitignore` — safe for intermediate outputs, downloads, generated files, build artifacts, etc.
- Create `.tmp/` if it doesn't exist before writing to it.
- **Never commit `.tmp/**`.**
