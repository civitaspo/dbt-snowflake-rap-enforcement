# Repository Guidelines

## Project Scope

This repository contains `dbt-snowflake-rap-enforcement`, a Snowflake-oriented dbt package that applies row access policies to models (including existing tables) and expresses RAP-side rules for downstream references.

Keep adapter-independent reference authorization in [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models). Do not fold Snowflake RAP DDL into that package.

## Contributor Expectations

- Write commits, pull request titles/bodies, documentation, comments, and user-facing messages in **English only**.
- Use Conventional Commits for pull request titles (`feat`, `fix`, `docs`, `refactor`, `test`, `ci`, `build`, `chore`, `perf`, `revert`; use `!` for breaking changes).
- Never push directly to `main`. Open a pull request and squash-merge after required checks pass.
- Keep changes small, reviewable, and focused on one meaningful unit of work.
- Sign commits (SSH signing is configured for maintainers and coding agents committing as `civitaspo`).
- Do not store strong credentials in this repository. GPG keys, machine-user PATs, and `contents: write` app keys live only in `civitaspo/securefix-server`.

## Tooling

Install pinned tools with mise:

```bash
mise install --locked
```

Before opening a pull request, run:

```bash
mise run lint
mise run test
mise run test:fusion
```

Treat dbt Fusion compatibility as a required behavior surface, not an optional smoke test. When changing compatibility-sensitive macro behavior, verify with Fusion using `mise run test:fusion` (or the CI `fusion-compatibility` job commands). Do not hide CI steps behind mise tasks — keep failing commands visible in GitHub Actions.

## GitHub Actions

- Pin public GitHub Actions to immutable SHAs.
- Use `persist-credentials: false` with `actions/checkout` unless a workflow explicitly needs push credentials.
- Keep workflow permissions least-privilege.
- Securefix applies machine fixes via `civitaspo/securefix-server`.
- Approvals for trusted authors are requested through `csm-actions/approve-pr-action`.

See [CONTRIBUTING.md](CONTRIBUTING.md), [docs/securefix.md](docs/securefix.md), and [docs/releasing.md](docs/releasing.md).
