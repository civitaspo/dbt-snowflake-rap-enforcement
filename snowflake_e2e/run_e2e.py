#!/usr/bin/env python3
"""Local-only Snowflake E2E for apply_row_access_policies().

Connection and object location come exclusively from environment variables.
This suite is intentionally not wired into `mise run test` / CI.

Pass --dbt-executable (or DBT_SNOWFLAKE_RAP_E2E_DBT_EXECUTABLE) to run with
dbt Fusion or another CLI instead of dbt Core's dbtRunner.

Scenarios:
1. Existing bare table (no RAP) -> run-operation apply ADDs the policy
2. dbt run materializes with native WITH RAP, post_hook strips it, on-run-end ADDs
3. Stale RAP attached -> authoritative apply REPLACEs with the desired policy
4. RAP attached + model config has no row_access_policy -> authoritative apply DROPs
5. Extra out-of-graph attachments force the policy inventory path
6. A large threshold forces the relation inventory path
7. Execution failure then dbt retry attaches the desired RAP
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
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


def invoke_dbt_core(
    args: list[str],
    profiles_dir: Path,
    *,
    expect_success: bool = True,
) -> str:
    from io import StringIO
    from contextlib import redirect_stderr, redirect_stdout

    from dbt.cli.main import dbtRunner

    full = [
        *args,
        "--project-dir",
        str(PROJECT_DIR),
        "--profiles-dir",
        str(profiles_dir),
    ]
    print("+ dbt " + " ".join(args))
    buf = StringIO()
    with redirect_stdout(buf), redirect_stderr(buf):
        result = dbtRunner().invoke(full)
    output = buf.getvalue()
    if output.strip():
        print(output, end="" if output.endswith("\n") else "\n")
    if expect_success and not result.success:
        detail = ""
        if result.exception is not None:
            detail = f"\n{type(result.exception).__name__}: {result.exception}"
        raise E2EError(f"dbt command failed: dbt {' '.join(args)}{detail}")
    if not expect_success and result.success:
        raise E2EError(f"dbt command unexpectedly succeeded: dbt {' '.join(args)}")
    return output


def invoke_dbt_executable(
    dbt_executable: str,
    args: list[str],
    profiles_dir: Path,
    *,
    expect_success: bool = True,
) -> str:
    command = [
        dbt_executable,
        *args,
        "--project-dir",
        str(PROJECT_DIR),
        "--profiles-dir",
        str(profiles_dir),
    ]
    print("+ " + " ".join(command))
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    output = (completed.stdout or "") + (completed.stderr or "")
    if output.strip():
        print(output, end="" if output.endswith("\n") else "\n")
    if expect_success and completed.returncode != 0:
        raise E2EError(
            f"dbt command failed (exit {completed.returncode}): "
            + " ".join(command)
            + (f"\n{output}" if output.strip() else "")
        )
    if not expect_success and completed.returncode == 0:
        raise E2EError(
            "dbt command unexpectedly succeeded: " + " ".join(command)
        )
    return output


def make_invoker(dbt_executable: str | None):
    def invoke(
        args: list[str],
        profiles_dir: Path,
        *,
        expect_success: bool = True,
    ) -> str:
        if dbt_executable:
            return invoke_dbt_executable(
                dbt_executable,
                args,
                profiles_dir,
                expect_success=expect_success,
            )
        return invoke_dbt_core(args, profiles_dir, expect_success=expect_success)

    return invoke


def apply_vars(policy_fqn: str, relation_threshold: int | None = None) -> str:
    package_vars: dict[str, object] = {"apply_authoritatively": True}
    if relation_threshold is not None:
        package_vars["policy_references_relation_threshold"] = relation_threshold
    return json.dumps(
        {
            "e2e_policy_fqn": policy_fqn,
            "dbt_snowflake_rap_enforcement": package_vars,
        }
    )


def assert_complete_metrics(output: str, **expected: object) -> None:
    lines = [
        line
        for line in output.splitlines()
        if "apply_row_access_policies complete:" in line
    ]
    if not lines:
        raise E2EError("missing apply_row_access_policies complete metrics line")
    line = lines[-1]
    for key, value in expected.items():
        needle = f"{key}={value}"
        if needle not in line:
            raise E2EError(f"expected {needle} in metrics line: {line}")


def relation_args(database: str, schema: str, identifier: str) -> str:
    return json.dumps(
        {"database": database, "schema": schema, "identifier": identifier}
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Local-only Snowflake E2E for apply_row_access_policies(). "
            "Uses dbt Core dbtRunner by default; pass --dbt-executable for Fusion."
        )
    )
    parser.add_argument(
        "--dbt-executable",
        default=env("DBT_EXECUTABLE"),
        help=(
            "Path to a dbt CLI executable (e.g. dbt Fusion). "
            f"Defaults to ${ENV_PREFIX}DBT_EXECUTABLE when set; "
            "otherwise uses dbt Core's programmatic dbtRunner API."
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
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
    invoke_dbt = make_invoker(args.dbt_executable)

    print(f"Snowflake E2E run_id={rid}")
    print(f"Using schema {database}.{schema}")
    print(f"Using policy {policy_fqn}")
    print(f"Using stale policy {stale_policy_fqn}")
    if args.dbt_executable:
        print(f"Using dbt executable {args.dbt_executable}")
    else:
        print("Using dbt Core dbtRunner")

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

            print("== Scenario 4: cleared config -> authoritative apply DROP ==")
            cleared_model = "e2e_cleared_table"
            cleared_rel = relation_args(database, schema, cleared_model)
            invoke_dbt(
                ["run-operation", "e2e_create_bare_table", "--args", cleared_rel],
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
                            "identifier": cleared_model,
                            "policy_fqn": policy_fqn,
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
                            "identifier": cleared_model,
                            "policy_fqn": policy_fqn,
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
                    "e2e_assert_policy_absent",
                    "--args",
                    cleared_rel,
                ],
                profiles_dir,
            )

            print("== Scenario 5: policy inventory path with extra attachments ==")
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_create_fanout_tables",
                    "--args",
                    json.dumps(
                        {
                            "database": database,
                            "schema": schema,
                            "policy_fqn": policy_fqn,
                            "table_count": 8,
                        }
                    ),
                ],
                profiles_dir,
            )
            policy_output = invoke_dbt(
                [
                    "run-operation",
                    "apply_row_access_policies",
                    "--vars",
                    apply_vars(policy_fqn, relation_threshold=1),
                ],
                profiles_dir,
            )
            assert_complete_metrics(
                policy_output,
                inventory_strategy="policy",
                policy_lookup_calls=1,
            )
            complete_line = policy_output.split("apply_row_access_policies complete:")[-1]
            if "extra_attachments=0" in complete_line:
                raise E2EError(
                    "policy path should report extra_attachments from fan-out tables"
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
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_assert_policy_absent",
                    "--args",
                    cleared_rel,
                ],
                profiles_dir,
            )

            print("== Scenario 6: relation inventory path ==")
            relation_output = invoke_dbt(
                [
                    "run-operation",
                    "apply_row_access_policies",
                    "--vars",
                    apply_vars(policy_fqn, relation_threshold=10000),
                ],
                profiles_dir,
            )
            assert_complete_metrics(
                relation_output,
                inventory_strategy="relation",
                policy_lookup_calls=0,
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
            invoke_dbt(
                [
                    "run-operation",
                    "e2e_assert_policy_absent",
                    "--args",
                    cleared_rel,
                ],
                profiles_dir,
            )

            print("== Scenario 7: dbt retry after execution failure ==")
            retry_model = "e2e_retry_model"
            with tempfile.TemporaryDirectory(prefix="rap-e2e-target-") as target_tmp:
                target_path = str(Path(target_tmp).resolve())
                os.environ["DBT_SNOWFLAKE_RAP_E2E_RETRY_FAIL"] = "1"
                try:
                    invoke_dbt(
                        [
                            "run",
                            "--select",
                            retry_model,
                            "--target-path",
                            target_path,
                            "--vars",
                            vars_json,
                        ],
                        profiles_dir,
                        expect_success=False,
                    )
                finally:
                    os.environ["DBT_SNOWFLAKE_RAP_E2E_RETRY_FAIL"] = "0"
                retry_output = invoke_dbt(
                    [
                        "retry",
                        "--target-path",
                        target_path,
                        "--vars",
                        vars_json,
                    ],
                    profiles_dir,
                )
                assert_complete_metrics(
                    retry_output,
                    inventory_strategy="relation",
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
                            "identifier": retry_model,
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
