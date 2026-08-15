#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


PROJECT_DIR = "integration_tests"
PROFILES_DIR = "integration_tests"
# Absolute paths keep dbt Core and Fusion on the same artifact dirs.
# Fusion resolves relative --target-path against --project-dir.
HARNESS_DIR = Path("integration_tests/target/retry_harness").resolve()
RETRY_VARS = '{"enable_retry_models": true}'
FAIL_ENV = "DBT_SNOWFLAKE_RAP_RETRY_FAIL"
METRICS_RE = re.compile(
    r"Downstream row access policy check metrics: "
    r"graph_nodes=(\d+); rap_sources=(\d+); dependency_edges=(\d+); "
    r"ancestor_visits=(\d+); child_edges_examined=(\d+); checked=(\d+)"
)


@dataclass(frozen=True)
class Metrics:
    graph_nodes: int
    rap_sources: int
    dependency_edges: int
    ancestor_visits: int
    child_edges_examined: int
    checked: int


@dataclass(frozen=True)
class Invocation:
    name: str
    description: str
    output: str
    success: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run one dbt build and three retries to assert the downstream "
            "check still walks the full graph on every non-empty attempt."
        )
    )
    parser.add_argument(
        "--dbt-executable",
        default="dbt",
        help="Path to a dbt CLI executable (default: dbt on PATH).",
    )
    return parser.parse_args()


def fail(message: str, invocation: Invocation | None = None) -> None:
    print(message, file=sys.stderr)
    if invocation is not None:
        print("Invocation: " + invocation.description, file=sys.stderr)
        print(invocation.output, file=sys.stderr)
    raise SystemExit(1)


def invoke_dbt(
    dbt_executable: str,
    dbt_args: list[str],
    name: str,
    fail_retry: bool,
) -> Invocation:
    env = os.environ.copy()
    env[FAIL_ENV] = "1" if fail_retry else "0"
    command = [dbt_executable, *dbt_args]
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    return Invocation(
        name=name,
        description=" ".join(command) + f" {FAIL_ENV}={env[FAIL_ENV]}",
        output=(completed.stdout or "") + (completed.stderr or ""),
        success=completed.returncode == 0,
    )


def parse_metrics(invocation: Invocation) -> Metrics:
    matches = METRICS_RE.findall(invocation.output)
    if len(matches) != 1:
        fail(
            f"{invocation.name} expected exactly one downstream-check metrics "
            f"line, found {len(matches)}",
            invocation,
        )
    values = tuple(int(part) for part in matches[0])
    return Metrics(*values)


def main() -> int:
    args = parse_args()
    if HARNESS_DIR.exists():
        shutil.rmtree(HARNESS_DIR)
    HARNESS_DIR.mkdir(parents=True, exist_ok=True)

    attempts = [
        ("attempt0", "build", True),
        ("attempt1", "retry", True),
        ("attempt2", "retry", True),
        ("attempt3", "retry", False),
    ]
    previous_target: Path | None = None
    metrics_by_attempt: dict[str, Metrics] = {}

    for name, command, fail_retry in attempts:
        target_path = HARNESS_DIR / name
        dbt_args = [
            command,
            "--project-dir",
            PROJECT_DIR,
            "--profiles-dir",
            PROFILES_DIR,
            "--vars",
            RETRY_VARS,
            "--target-path",
            str(target_path.resolve()),
        ]
        if command == "build":
            dbt_args.extend(["--select", "flaky_retry_model"])
        else:
            if previous_target is None:
                fail("retry attempted before the initial build")
            dbt_args.extend(["--state", str(previous_target.resolve())])

        invocation = invoke_dbt(args.dbt_executable, dbt_args, name, fail_retry)
        if fail_retry and invocation.success:
            fail(f"{name} expected a failed {command}", invocation)
        if (not fail_retry) and (not invocation.success):
            fail(f"{name} expected a successful {command}", invocation)
        if fail_retry and "nonexistent_retry_failure_table" not in invocation.output:
            fail(f"{name} missing intentional retry failure", invocation)

        metrics_by_attempt[name] = parse_metrics(invocation)
        previous_target = target_path
        print(f"OK: {name} {command} fail={fail_retry} metrics={metrics_by_attempt[name]}")

    baseline = metrics_by_attempt["attempt0"]
    if baseline.graph_nodes < 5:
        fail(f"expected a full-graph node count, got graph_nodes={baseline.graph_nodes}")
    if baseline.rap_sources < 2:
        fail(f"expected RAP sources on the full graph, got rap_sources={baseline.rap_sources}")
    if baseline.dependency_edges < 3:
        fail(
            "expected dependency edges on the full graph, got "
            f"dependency_edges={baseline.dependency_edges}"
        )
    if baseline.ancestor_visits < 3:
        fail(
            "expected ancestor visits on the full graph, got "
            f"ancestor_visits={baseline.ancestor_visits}"
        )
    if baseline.child_edges_examined < 3:
        fail(
            "expected child-edge examinations on the full graph, got "
            f"child_edges_examined={baseline.child_edges_examined}"
        )
    if baseline.checked < 2:
        fail(f"expected downstream relationships checked, got checked={baseline.checked}")

    for name, metrics in metrics_by_attempt.items():
        if metrics != baseline:
            fail(
                f"{name} metrics {metrics} did not match the full-graph "
                f"baseline {baseline}"
            )

    print(
        "Downstream row access policy retry tests passed "
        f"(graph_nodes={baseline.graph_nodes}, rap_sources={baseline.rap_sources})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
