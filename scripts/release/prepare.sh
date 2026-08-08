#!/bin/sh
# Compute the next release version and regenerate CHANGELOG.md with git-cliff.
# Prints: VERSION=<semver> or nothing when there is nothing to release.
#
# Usage: scripts/release/prepare.sh
# Env: requires git-cliff on PATH (mise install --locked).

set -eu

latest_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || printf '%s\n' v0.0.0)
if [ -f .release-version ]; then
  shipped_tag="v$(tr -d '[:space:]' < .release-version)"
  if printf '%s\n' "$shipped_tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    latest_tag=$(printf '%s\n%s\n' "$latest_tag" "$shipped_tag" | sort -V | tail -n1)
  fi
fi

echo "Using base tag: $latest_tag" >&2

# When .release-version is ahead of the real git tag (release merged, tag not
# created yet), point a local tag at the release commit so git-cliff bumps from
# the shipped version. Never push this tag.
if ! git rev-parse --verify --quiet "$latest_tag^{commit}" >/dev/null; then
  version_no_v=${latest_tag#v}
  ship_commit=$(
    git log --grep="^chore(release): v${version_no_v}$" --format='%H' -1 2>/dev/null || true
  )
  if [ -z "$ship_commit" ]; then
    ship_commit=$(
      git log --grep="^chore(release): prepare v${version_no_v}$" --format='%H' -1 2>/dev/null || true
    )
  fi
  if [ -n "$ship_commit" ]; then
    git tag -f "$latest_tag" "$ship_commit" >/dev/null
    echo "Created local tag $latest_tag at $ship_commit" >&2
  else
    echo "Base tag $latest_tag does not exist and no matching release commit was found." >&2
    exit 1
  fi
fi

bumped=$(git cliff --bumped-version)
bumped=${bumped#v}
base=${latest_tag#v}

if [ -z "$bumped" ] || [ "$bumped" = "$base" ]; then
  echo "No releasable commits found." >&2
  exit 0
fi

git cliff --tag "v${bumped}" --output CHANGELOG.md
printf '%s\n' "$bumped" > .release-version
echo "VERSION=$bumped"
