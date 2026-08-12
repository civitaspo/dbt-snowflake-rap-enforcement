# Snowflake E2E (local only)

Exercises `apply_row_access_policies()` against a real Snowflake account:

1. Create an isolated schema + desired / stale row access policies
2. **Bare table ADD (run-operation):** create a table with no RAP → assert absent → apply → assert attached
3. **on-run-end ADD:** `dbt run` materializes with Snowflake's native `WITH ROW ACCESS POLICY`, a `post_hook` strips it, then `on-run-end` apply must ADD again → assert attached
4. **Authoritative REPLACE:** attach a stale RAP → apply (`apply_authoritatively=true`) → assert desired policy replaced it
5. **Authoritative DROP on clear:** attach a RAP to a model with no `row_access_policy` config → apply → assert attachment removed
6. Drop the isolated schema

dbt-snowflake attaches RAP during `CREATE TABLE` when `config.row_access_policy` is set. Scenario 2 strips that attachment so the package's on-run-end path is what re-attaches the policy.

This suite is **not** part of `mise run test` or CI. Run it only on a machine with credentials.

## Prerequisites

- Snowflake role that can `CREATE SCHEMA`, `CREATE TABLE`, `CREATE ROW ACCESS POLICY`, and `ALTER TABLE ... ROW ACCESS POLICY` in the target database
- Network access to your Snowflake account

## Environment variables

All values are read from the environment. Nothing account-specific is committed to this repository.

| Variable | Required | Meaning |
|----------|----------|---------|
| `DBT_SNOWFLAKE_RAP_E2E_ACCOUNT` | yes | Snowflake account identifier (as used by connectors, not a docs hostname) |
| `DBT_SNOWFLAKE_RAP_E2E_USER` | yes | User |
| `DBT_SNOWFLAKE_RAP_E2E_ROLE` | yes | Role |
| `DBT_SNOWFLAKE_RAP_E2E_WAREHOUSE` | yes | Warehouse |
| `DBT_SNOWFLAKE_RAP_E2E_DATABASE` | yes | Database where an ephemeral schema will be created |
| `DBT_SNOWFLAKE_RAP_E2E_SCHEMA` | yes | Schema name prefix; each run appends `_<run_id>` and drops that schema afterward |
| `DBT_SNOWFLAKE_RAP_E2E_PASSWORD` | one of auth* | Password auth |
| `DBT_SNOWFLAKE_RAP_E2E_PRIVATE_KEY_PATH` | one of auth* | Path to PEM private key |
| `DBT_SNOWFLAKE_RAP_E2E_PRIVATE_KEY` | one of auth* | PEM private key contents |
| `DBT_SNOWFLAKE_RAP_E2E_PRIVATE_KEY_PASSPHRASE` | no | Passphrase for the private key |
| `DBT_SNOWFLAKE_RAP_E2E_AUTHENTICATOR` | one of auth* | e.g. `externalbrowser` or `oauth` (SSO / browser login) |
| `DBT_SNOWFLAKE_RAP_E2E_TOKEN` | optional | OAuth access token when using `oauth` |
| `DBT_SNOWFLAKE_RAP_E2E_DBT_EXECUTABLE` | no | Path to a dbt CLI (e.g. Fusion). Omit to use dbt Core `dbtRunner` |

\* Provide one auth path: password, private key path/contents, OAuth token, or `AUTHENTICATOR=externalbrowser`.

Example (browser / SSO auth):

```bash
export DBT_SNOWFLAKE_RAP_E2E_ACCOUNT="xy12345"
export DBT_SNOWFLAKE_RAP_E2E_USER="you@example.com"
export DBT_SNOWFLAKE_RAP_E2E_AUTHENTICATOR="externalbrowser"
export DBT_SNOWFLAKE_RAP_E2E_ROLE="..."
export DBT_SNOWFLAKE_RAP_E2E_WAREHOUSE="..."
export DBT_SNOWFLAKE_RAP_E2E_DATABASE="..."
export DBT_SNOWFLAKE_RAP_E2E_SCHEMA="RAP_E2E"
```

## Run

dbt Core (default):

```bash
mise run test:snowflake-e2e
```

Or:

```bash
uv sync --frozen --extra snowflake-e2e
uv run --extra snowflake-e2e python snowflake_e2e/run_e2e.py
```

dbt Fusion:

```bash
mise run test:snowflake-e2e:fusion
```

Or:

```bash
curl -fsSL https://public.cdn.getdbt.com/fs/install/install.sh \
  | sh -s -- --to /tmp/dbt-fusion-bin --update
uv sync --frozen
uv run python snowflake_e2e/run_e2e.py --dbt-executable /tmp/dbt-fusion-bin/dbt
# equivalently:
# export DBT_SNOWFLAKE_RAP_E2E_DBT_EXECUTABLE=/tmp/dbt-fusion-bin/dbt
# uv run python snowflake_e2e/run_e2e.py
```

## Notes

- Assumes **unquoted** Snowflake identifiers (same as the package apply path).
- Downstream lint remains covered by the DuckDB integration tests; this suite focuses on apply/DDL.
