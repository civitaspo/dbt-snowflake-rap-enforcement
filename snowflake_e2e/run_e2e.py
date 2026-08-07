#!/usr/bin/env python3
"""Local-only Snowflake E2E for apply_row_access_policies().

Connection and object location come exclusively from environment variables.
This suite is intentionally not wired into `mise run test` / CI.

Scenarios:
1. Existing bare table (no RAP) -> run-operation apply ADDs the policy
2. dbt run materializes with native WITH RAP, post_hook strips it, on-run-end ADDs
3. Stale RAP attached -> authoritative apply REPLACEs with the desired policy
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
    authenticator = (env("AUTHENTICATOR") or "").lower()
    oauth_token = env("TOKEN")

    browser_auth = authenticator in {
        "externalbrowser",
        "oauth",
        "oauth_authorization_code",
    }
    has_secret_auth = bool(password or private_key_path or private_key or oauth_token)
    if not browser_auth and not has_secret_auth:
        missing.append(
            f"{ENV_PREFIX}PASSWORD or {ENV_PREFIX}PRIVATE_KEY_PATH or "
            f"{ENV_PREFIX}PRIVATE_KEY or {ENV_PREFIX}TOKEN or "
            f"{ENV_PREFIX}AUTHENTICATOR=externalbrowser"
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
    values["AUTHENTICATOR"] = authenticator
    values["TOKEN"] = oauth_token or ""
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
    authenticator = cfg.get("AUTHENTICATOR") or ""
    if authenticator:
        if authenticator == "oauth_authorization_code":
            output["authenticator"] = "oauth"
        else:
            output["authenticator"] = authenticator
    if cfg["TOKEN"]:
        output["token"] = cfg["TOKEN"]
        output.setdefault("authenticator", "oauth")
    if cfg["PRIVATE_KEY_PATH"]:
        output["private_key_path"] = cfg["PRIVATE_KEY_PATH"]
        if cfg["PRIVATE_KEY_PASSPHRASE"]:
            output["private_key_passphrase"] = cfg["PRIVATE_KEY_PASSPHRASE"]
    elif cfg["PRIVATE_KEY"]:
        output["private_key"] = cfg["PRIVATE_KEY"]
        if cfg["PRIVATE_KEY_PASSPHRASE"]:
            output["private_key_passphrase"] = cfg["PRIVATE_KEY_PASSPHRASE"]
    elif cfg["PASSWORD"]:
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


def invoke_dbt(args: list[str], profiles_dir: Path) -> str:
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
    # dbtRunner does not always expose combined stdout; success flag is enough.
    if not result.success:
        detail = ""
        if result.exception is not None:
            detail = f"\n{type(result.exception).__name__}: {result.exception}"
        raise E2EError(f"dbt command failed: dbt {' '.join(args)}{detail}")
    return ""


def relation_args(database: str, schema: str, identifier: str) -> str:
    return json.dumps(
        {"database": database, "schema": schema, "identifier": identifier}
    )


def main() -> int:
    os.chdir(REPO_ROOT)
    cfg = require_env()
    rid = run_id()
    base_schema = sanitize_ident(cfg["SCHEMA"])
    schema = sanitize_ident(f"{base_schema}_{rid}")
    database = sanitize_ident(cfg["DATABASE"])
    policy_name = sanitize_ident(f"RAP_E2E_POL_{rid}")
    stale_policy_name = sanitize_ident(f"RAP_E2E_STALE_{rid}")
    policy_fqn = f"{database}.{schema}.{policy_name}"
    stale_policy_fqn = f"{database}.{schema}.{stale_policy_name}"
    model_name = "e2e_protected_table"

    print(f"Snowflake E2E run_id={rid}")
    print(f"Using schema {database}.{schema}")
    print(f"Using policy {policy_fqn}")
    print(f"Using stale policy {stale_policy_fqn}")

    with tempfile.TemporaryDirectory(prefix="rap-e2e-profiles-") as tmp:
        profiles_dir = Path(tmp)
        write_profiles(profiles_dir, cfg, database=database, schema=schema)
        vars_payload = {"e2e_policy_fqn": policy_fqn}
        vars_json = json.dumps(vars_payload)
        rel = relation_args(database, schema, model_name)

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
                [
                    "run-operation",
                    "e2e_create_policy",
                    "--args",
                    json.dumps({"policy_fqn": stale_policy_fqn}),
                ],
                profiles_dir,
            )

            print("== Scenario 1: bare existing table -> run-operation apply ADD ==")
            invoke_dbt(
                ["run-operation", "e2e_create_bare_table", "--args", rel],
                profiles_dir,
            )
            invoke_dbt(
                ["run-operation", "e2e_assert_policy_absent", "--args", rel],
                profiles_dir,
            )
            invoke_dbt(
                [
                    "run-operation",
                    "apply_row_access_policies",
                    "--vars",
                    vars_json,
                ],
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

            print("== Scenario 2: on-run-end ADD after post_hook strips native WITH RAP ==")
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

            print("== Scenario 3: stale RAP -> authoritative apply REPLACE ==")
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_create_bare_table",
                    "--args",
                    rel,
                ],
                profiles_dir,
            )
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_attach_policy",
                    "--args",
                    json.dumps(
                        {
                            "database": database,
                            "schema": schema,
                            "identifier": model_name,
                            "policy_fqn": stale_policy_fqn,
                        }
                    ),
                ],
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
                            "policy_fqn": stale_policy_fqn,
                        }
                    ),
                ],
                profiles_dir,
            )
            invoke_dbt(
                [
                    "run-operation",
                    "apply_row_access_policies",
                    "--vars",
                    vars_json,
                ],
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
