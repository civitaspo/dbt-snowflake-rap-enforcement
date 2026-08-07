#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass


BASE_DBT_ARGS = [
    "compile",
    "--project-dir",
    "integration_tests",
    "--profiles-dir",
    "integration_tests",
]


@dataclass(frozen=True)
class Scenario:
    name: str
    vars: str
    expected_message: str
    expect_success: bool = False


@dataclass(frozen=True)
class Invocation:
    description: str
    output: str
    success: bool


SCENARIOS = [
    Scenario(
        name="unauthorized plain table",
        vars='{"enable_violation_models": true}',
        expected_message="Downstream row access policy check failed",
    ),
    Scenario(
        name="global meta allow-all open zone",
        vars='{"enable_global_meta_cases": true}',
        expected_message="Downstream row access policy check passed",
        expect_success=True,
    ),
    Scenario(
        name="global meta strict zone resumes validation",
        vars='{"enable_global_meta_cases": true, "enable_global_meta_violation": true}',
        expected_message="Downstream row access policy check failed",
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run downstream row access policy failure-path integration tests."
    )
    parser.add_argument(
        "--dbt-executable",
        help=(
            "Path to a dbt CLI executable. Omit this to use dbt Core's "
            "programmatic dbtRunner API."
        ),
    )
    return parser.parse_args()


def fail(message: str, invocation: Invocation) -> None:
    print(message, file=sys.stderr)
    print("Invocation: " + invocation.description, file=sys.stderr)
    print(invocation.output, file=sys.stderr)
    raise SystemExit(1)


def invoke_dbt_core(dbt_args: list[str]) -> Invocation:
    from dbt.cli.main import dbtRunner

    stdout = io.StringIO()
    stderr = io.StringIO()

    with redirect_stdout(stdout), redirect_stderr(stderr):
        result = dbtRunner().invoke(dbt_args)

    output = stdout.getvalue() + stderr.getvalue()
    if result.exception is not None:
        output += f"\n{type(result.exception).__name__}: {result.exception}\n"

    return Invocation(
        description="dbtRunner().invoke(" + repr(dbt_args) + ")",
        output=output,
        success=bool(result.success),
    )


def invoke_dbt_executable(dbt_executable: str, dbt_args: list[str]) -> Invocation:
    command = [dbt_executable, *dbt_args]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    return Invocation(
        description=" ".join(command),
        output=(completed.stdout or "") + (completed.stderr or ""),
        success=completed.returncode == 0,
    )


def main() -> int:
    args = parse_args()

    for scenario in SCENARIOS:
        dbt_args = [*BASE_DBT_ARGS, "--vars", scenario.vars]
        if args.dbt_executable:
            invocation = invoke_dbt_executable(args.dbt_executable, dbt_args)
        else:
            invocation = invoke_dbt_core(dbt_args)

        if scenario.expect_success and not invocation.success:
            fail(f"Scenario '{scenario.name}' expected success", invocation)
        if (not scenario.expect_success) and invocation.success:
            fail(f"Scenario '{scenario.name}' expected failure", invocation)
        if scenario.expected_message not in invocation.output:
            fail(
                f"Scenario '{scenario.name}' missing expected message: "
                + scenario.expected_message,
                invocation,
            )
        print(f"OK: {scenario.name}")

    print("Downstream row access policy failure tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
