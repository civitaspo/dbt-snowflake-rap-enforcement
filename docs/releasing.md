# Releasing

This repository uses a tagpr-equivalent release flow built on CSM actions.

## Overview

1. Commits land on `main` via squash-merged pull requests.
2. The **Release PR** workflow computes the next version and changelog, then asks `civitaspo/securefix-server` to open or update `release/next`.
3. A human squash-merges `chore(release): vX.Y.Z`.
4. The **Release Tag** workflow creates an annotated tag `vX.Y.Z` and requests a server-side release.
5. The securefix-server **Release dbt Snowflake RAP** workflow checks out the tag and publishes the GitHub Release.

## Repository release protections

- **Tag protection** (`Protect tags` ruleset): active — blocks force-pushes and deletion of tags outside the allowed release path.
- **Immutable releases**: enabled when the publisher creates a draft release, attaches notes, then publishes once.

## Version bump rules (while major is 0)

Scripts live under `scripts/release/`.

- Conventional Commit breaking change (`type!:` or `BREAKING CHANGE`) → minor
- `feat:` → minor
- everything else releasable → patch
- Only `chore(release):` commits since the last tag → nothing to release

The Release PR workflow floors the base version on both the latest `v*` tag and `.release-version` on `main`, so a push that lands after a release merge but before Release Tag finishes cannot re-propose the version that just shipped.

## Local helpers

```bash
scripts/release/next-version.sh
scripts/release/changelog.sh 0.1.0
```

## Server request format

The Release Tag workflow creates a label on `civitaspo/securefix-server` whose description is:

```text
civitaspo/dbt-snowflake-rap-enforcement/<run_id>/vX.Y.Z/<merge-commit-sha>
```

If that string would exceed GitHub's 100-character label description limit, the merge commit SHA is omitted and the server resolves it from the merged `release/next` pull request.

The merge commit SHA is preferred because `Release Tag` on a merged `release/next` PR tags the squash-merge commit on `main`, while the workflow run's `head_sha` is the PR head.

See [securefix.md](securefix.md) for client/server credential layout.
