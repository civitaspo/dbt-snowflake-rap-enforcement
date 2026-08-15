# Integration Tests

DuckDB project that exercises `check_downstream_row_access_policies()` via `on-run-start`.

```bash
uv run dbt deps --project-dir integration_tests --profiles-dir integration_tests
uv run python integration_tests/run_downstream_failure_tests.py
uv run python integration_tests/run_retry_tests.py
uv run dbt compile --project-dir integration_tests --profiles-dir integration_tests
```

`apply_row_access_policies()` is Snowflake-only. CI covers SQL generation via unit tests. For a real warehouse apply check on your laptop, use [../snowflake_e2e/README.md](../snowflake_e2e/README.md) (`mise run test:snowflake-e2e`, env-var credentials, not CI).
