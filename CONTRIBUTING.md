# Contributing

Thanks for contributing to `dbt-snowflake-rap-enforcement`.

## Development setup

Install pinned tools with [mise](https://mise.jdx.dev/):

```bash
mise install --locked
```

Useful tasks:

| Task | Command |
|------|---------|
| Lint | `mise run lint` |
| Tests (dbt Core) | `mise run test` |
| Tests (dbt Fusion) | `mise run test:fusion` |
| Snowflake E2E (dbt Core, local only) | `mise run test:snowflake-e2e` |
| Snowflake E2E (dbt Fusion, local only) | `mise run test:snowflake-e2e:fusion` |

## Pull requests

- Write commits, PR titles/bodies, documentation, and comments in **English only**.
- Use Conventional Commits for PR titles (`feat`, `fix`, `docs`, `refactor`, `test`, `ci`, `build`, `chore`, `perf`, `revert`; use `!` for breaking changes).
- Never push directly to `main`. Open a PR and squash-merge after required checks pass.
- Keep changes small, reviewable, and focused on one meaningful unit of work.
- Sign commits (SSH signing is configured for maintainers and coding agents committing as `civitaspo`).
- Do **not** edit `CHANGELOG.md` on feature PRs. git-cliff regenerates it on the `release/next` Release PR from Conventional Commit subjects (see [docs/releasing.md](docs/releasing.md)).

Before opening a PR:

```bash
mise run lint
mise run test
mise run test:fusion
```

## Package boundaries

- **This package:** Snowflake RAP application (DDL / attach to existing tables) and RAP-side metadata for downstream policy (`meta.row_access_policy_enforcement`).
- **[`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models):** adapter-independent reference authorization / lint (`meta.authorize`).

Prefer sharing a reference-control *contract* with authorized-models rather than embedding Snowflake RAP DDL there. Details: [docs/boundaries.md](docs/boundaries.md).

## Tests

```bash
uv sync --frozen
mise run test
mise run test:fusion
```

Unit tests use DuckDB + `dbt-unittest`. Integration tests compile a small DuckDB project and assert warn/error paths for downstream RAP lint. CI runs the same suites on dbt Core and dbt Fusion.

Optional local Snowflake E2E exercises `apply_row_access_policies()` against a real account:

- dbt Core: `mise run test:snowflake-e2e`
- dbt Fusion: `mise run test:snowflake-e2e:fusion`

Credentials and account location come from `DBT_SNOWFLAKE_RAP_E2E_*` environment variables only — see [snowflake_e2e/README.md](snowflake_e2e/README.md). Do not commit account hostnames or secrets. These tasks are not part of CI.

## Release flow (summary)

1. Merges to `main` trigger the Release PR workflow, which runs git-cliff and opens or updates the changelog / version bump PR on `release/next`.
2. Merging the release PR creates a tag and requests a server-side publish in `civitaspo/securefix-server`.
3. A GitHub Release is published for the tag.

See [docs/releasing.md](docs/releasing.md) and [docs/securefix.md](docs/securefix.md) for details.

## Security

Do not store strong credentials in this repository. Report vulnerabilities via GitHub private vulnerability reporting ([SECURITY.md](SECURITY.md)).
