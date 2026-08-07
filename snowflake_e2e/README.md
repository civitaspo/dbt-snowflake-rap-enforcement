# Snowflake E2E (local only)

Exercises `apply_row_access_policies()` against a real Snowflake account:

1. Create an isolated schema + row access policy
2. `dbt run` a model that declares `row_access_policy` (apply runs on `on-run-end`)
3. Assert the policy is attached via `POLICY_REFERENCES`
4. Drop the isolated schema

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

\* Provide exactly one auth material: password, private key path, or private key contents.

Example (password auth):

```bash
export DBT_SNOWFLAKE_RAP_E2E_ACCOUNT="myorg-myaccount"
export DBT_SNOWFLAKE_RAP_E2E_USER="..."
export DBT_SNOWFLAKE_RAP_E2E_PASSWORD="..."
export DBT_SNOWFLAKE_RAP_E2E_ROLE="..."
export DBT_SNOWFLAKE_RAP_E2E_WAREHOUSE="..."
export DBT_SNOWFLAKE_RAP_E2E_DATABASE="..."
export DBT_SNOWFLAKE_RAP_E2E_SCHEMA="RAP_E2E"
```

## Run

```bash
mise run test:snowflake-e2e
```

Or:

```bash
uv sync --frozen --extra snowflake-e2e
uv run --extra snowflake-e2e python snowflake_e2e/run_e2e.py
```

## Notes

- Assumes **unquoted** Snowflake identifiers (same as the package apply path).
- Downstream lint remains covered by the DuckDB integration tests; this suite focuses on apply/DDL.
