# Integration Tests

DuckDB project that exercises `check_downstream_row_access_policy()` via `on-run-start`.

```bash
uv run dbt deps --project-dir integration_tests --profiles-dir integration_tests
uv run python integration_tests/run_downstream_failure_tests.py
uv run dbt compile --project-dir integration_tests --profiles-dir integration_tests
```

`apply_row_access_policies()` is Snowflake-only and is covered by unit tests that assert SQL generation (no warehouse credentials in CI).
