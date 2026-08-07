#!/usr/bin/env python3
"""Local-only Snowflake E2E for apply_row_access_policies().

Connection and object location come exclusively from environment variables.
This suite is intentionally not wired into `mise run test` / CI.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent
PROJECT_DIR = ROOT
REPO_ROOT = ROOT.parent

ENV_PREFIX = "DBT_SNOWFLAKE_RAP_E2E_"

REQUIRED_ENV = [
    "ACCOUNT",
    "USER",
    "ROLE",
    "WAREHOUSE",
    "DATABASE",
    "SCHEMA",
]


class E2EError(RuntimeError):
    pass


def env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(ENV_PREFIX + name, default)
    if value is None:
        return None
    value = value.strip()
    return value if value else None


def require_env() -> dict[str, str]:
    missing = [ENV_PREFIX + key for key in REQUIRED_ENV if not env(key)]
    password = env("PASSWORD")
    private_key_path = env("PRIVATE_KEY_PATH")
    private_key = env("PRIVATE_KEY")
    if not password and not private_key_path and not private_key:
        missing.append(
            f"{ENV_PREFIX}PASSWORD or {ENV_PREFIX}PRIVATE_KEY_PATH or {ENV_PREFIX}PRIVATE_KEY"
        )
    if missing:
        raise E2EError(
            "Missing required environment variables for Snowflake E2E:\n  - "
            + "\n  - ".join(missing)
            + "\n\nSee snowflake_e2e/README.md. This suite is local-only and is not run in CI."
        )

    values = {key: env(key) for key in REQUIRED_ENV}
    assert all(values.values())
    values["PASSWORD"] = password or ""
    values["PRIVATE_KEY_PATH"] = private_key_path or ""
    values["PRIVATE_KEY"] = private_key or ""
    values["PRIVATE_KEY_PASSPHRASE"] = env("PRIVATE_KEY_PASSPHRASE") or ""
    return values  # type: ignore[return-value]


def sanitize_ident(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_]", "_", value)
    if not re.match(r"^[A-Za-z_]", cleaned):
        cleaned = "E_" + cleaned
    return cleaned.upper()


def run_id() -> str:
    return secrets.token_hex(4).upper()


def write_profiles(
    profiles_dir: Path,
    cfg: dict[str, str],
    *,
    database: str,
    schema: str,
) -> None:
    output: dict[str, object] = {
        "type": "snowflake",
        "account": cfg["ACCOUNT"],
        "user": cfg["USER"],
        "role": cfg["ROLE"],
        "warehouse": cfg["WAREHOUSE"],
        "database": database,
        "schema": schema,
        "threads": 4,
        "client_session_keep_alive": False,
    }
    if cfg["PRIVATE_KEY_PATH"]:
        output["private_key_path"] = cfg["PRIVATE_KEY_PATH"]
        if cfg["PRIVATE_KEY_PASSPHRASE"]:
            output["private_key_passphrase"] = cfg["PRIVATE_KEY_PASSPHRASE"]
    elif cfg["PRIVATE_KEY"]:
        output["private_key"] = cfg["PRIVATE_KEY"]
        if cfg["PRIVATE_KEY_PASSPHRASE"]:
            output["private_key_passphrase"] = cfg["PRIVATE_KEY_PASSPHRASE"]
    else:
        output["password"] = cfg["PASSWORD"]

    payload = {
        "snowflake_e2e": {
            "target": "snowflake",
            "outputs": {"snowflake": output},
        }
    }
    profiles_dir.mkdir(parents=True, exist_ok=True)
    (profiles_dir / "profiles.yml").write_text(
        yaml.safe_dump(payload, sort_keys=False),
        encoding="utf-8",
    )


def invoke_dbt(args: list[str], profiles_dir: Path) -> None:
    from dbt.cli.main import dbtRunner

    full = [
        *args,
        "--project-dir",
        str(PROJECT_DIR),
        "--profiles-dir",
        str(profiles_dir),
    ]
    print("+ dbt " + " ".join(args))
    result = dbtRunner().invoke(full)
    if not result.success:
        detail = ""
        if result.exception is not None:
            detail = f"\n{type(result.exception).__name__}: {result.exception}"
        raise E2EError(f"dbt command failed: dbt {' '.join(args)}{detail}")


def main() -> int:
    os.chdir(REPO_ROOT)
    cfg = require_env()
    rid = run_id()
    base_schema = sanitize_ident(cfg["SCHEMA"])
    schema = sanitize_ident(f"{base_schema}_{rid}")
    database = sanitize_ident(cfg["DATABASE"])
    policy_name = sanitize_ident(f"RAP_E2E_POL_{rid}")
    policy_fqn = f"{database}.{schema}.{policy_name}"
    model_name = "e2e_protected_table"

    print(f"Snowflake E2E run_id={rid}")
    print(f"Using schema {database}.{schema}")
    print(f"Using policy {policy_fqn}")

    with tempfile.TemporaryDirectory(prefix="rap-e2e-profiles-") as tmp:
        profiles_dir = Path(tmp)
        write_profiles(profiles_dir, cfg, database=database, schema=schema)
        vars_payload = {"e2e_policy_fqn": policy_fqn}
        vars_json = json.dumps(vars_payload)

        try:
            invoke_dbt(["deps"], profiles_dir)
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_create_schema",
                    "--args",
                    json.dumps({"database": database, "schema": schema}),
                ],
                profiles_dir,
            )
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_create_policy",
                    "--args",
                    json.dumps({"policy_fqn": policy_fqn}),
                ],
                profiles_dir,
            )
            invoke_dbt(
                ["run", "--select", model_name, "--vars", vars_json],
                profiles_dir,
            )
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_assert_policy_attached",
                    "--args",
                    json.dumps(
                        {
                            "database": database,
                            "schema": schema,
                            "identifier": model_name,
                            "policy_fqn": policy_fqn,
                        }
                    ),
                ],
                profiles_dir,
            )
            print("Snowflake E2E passed.")
            return 0
        finally:
            try:
                invoke_dbt(
                    [
                        "run-operation",
                        "e2e_drop_schema",
                        "--args",
                        json.dumps({"database": database, "schema": schema}),
                    ],
                    profiles_dir,
                )
            except E2EError as cleanup_error:
                print(
                    f"WARNING: cleanup failed: {cleanup_error}",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except E2EError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from exc
