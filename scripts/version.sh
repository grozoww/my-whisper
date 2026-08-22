#!/usr/bin/env bash
#
# Works out what to call this build. One place, so the DMG filename, the version baked into the
# app and the name on the release page can never disagree.
#
#   ./scripts/version.sh            VERSION=… BUILD=… SHA=… RELEASE_NAME=… , for eval or $GITHUB_ENV
#   ./scripts/version.sh --version  1.0.3
#   ./scripts/version.sh --build    12
#   ./scripts/version.sh --sha      a1b2c3d
#   ./scripts/version.sh --name     release-1.0.3-a1b2c3d
#
# The rule:
#
#   The `VERSION` file holds the line you are on — 1.0.0. Major and minor are a deliberate human
#   edit to that file; nobody derives "this release broke things" from a commit count. The patch
#   number is derived: it counts the pull requests merged since `VERSION` last changed. Merge four
#   PRs after setting the file to 1.0.0 and this build is 1.0.4. Set the file to 1.1.0 and the
#   count starts again from there.
#
#   A `v*` tag on the exact commit being built outranks all of that. Tagging v1.2.0 is a decision,
#   and a release whose tag and whose app disagree about the version tells every user to upgrade
#   to what they already have — `UpdateChecker` compares the tag against CFBundleShortVersionString.
#
# PRs are counted along main's first-parent chain, so only what actually landed counts, once
# each. Both merge styles are recognised: GitHub's merge commit ("Merge pull request #12") and a
# squash ("Some change (#12)").
#
# Needs full history. `actions/checkout` clones one commit by default, which would make every
# build look like the first one — the workflows that call this pass `fetch-depth: 0`.

set -euo pipefail
# Resolved before the cd, so `--help` still finds this file when it was run from inside scripts/.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

BASE_FILE="VERSION"
PBXPROJ="OurWhisper.xcodeproj/project.pbxproj"

in_git() { git rev-parse --git-dir >/dev/null 2>&1; }

# Distinct PR numbers on the first-parent chain over the given range.
count_prs() {
  git log --first-parent --format=%s "$@" 2>/dev/null \
    | sed -nE 's/^Merge pull request #([0-9]+).*/\1/p; s/.*\(#([0-9]+)\)$/\1/p' \
    | sort -u \
    | wc -l \
    | tr -d '[:space:]'
}

# The `VERSION` file is the source of truth; the project setting is what a plain Xcode build uses
# and is kept in step with it, so it is a safe fallback for a checkout without the file.
if [ -f "$BASE_FILE" ]; then
  BASE="$(tr -d '[:space:]' < "$BASE_FILE")"
else
  BASE="$(grep -m1 'MARKETING_VERSION' "$PBXPROJ" | sed 's/.*= *//; s/;//')"
fi

case "$BASE" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "version.sh: $BASE_FILE should hold a version like 1.0.0, not '$BASE'" >&2; exit 1 ;;
esac

IFS=. read -r MAJOR MINOR PATCH <<EOF
$BASE
EOF

# `git tag --points-at` needs the tags to have been fetched, which a workflow triggered by a tag
# push has not necessarily done. GITHUB_REF_* is authoritative there and costs nothing to check.
TAGGED=""
if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  TAGGED="${GITHUB_REF_NAME:-}"
elif in_git; then
  TAGGED="$(git tag --points-at HEAD 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
fi

SHA="unknown"
BUILD=1

if in_git; then
  SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
  # Says out loud that a local build was made from something that is not committed anywhere.
  if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    SHA="$SHA-dirty"
  fi

  # CFBundleVersion has to increase for every build macOS ever sees, and never resets when the
  # marketing version does. Every PR ever merged, plus one, does that and stays meaningful.
  BUILD=$(( $(count_prs HEAD) + 1 ))
fi

case "$TAGGED" in
  v[0-9]*.[0-9]*.[0-9]*)
    VERSION="${TAGGED#v}"
    ;;
  *)
    # The commit that last changed `VERSION` on main. `--first-parent` attributes it to the merge
    # commit that landed it, so the PR carrying the bump is not then counted as a PR since the
    # bump — which would make setting the file to 1.0.0 produce 1.0.1.
    ANCHOR=""
    if in_git; then
      ANCHOR="$(git log --first-parent -1 --format=%H -- "$BASE_FILE" 2>/dev/null || true)"
    fi

    if [ -n "$ANCHOR" ]; then
      VERSION="$MAJOR.$MINOR.$(( PATCH + $(count_prs "$ANCHOR..HEAD") ))"
    else
      # No anchor means no history to count from — a source download, a shallow clone, or the
      # commit that introduces the file. The base version verbatim is the honest answer; counting
      # every PR in the repository instead would date a fresh 1.0.0 line at 1.0.30.
      VERSION="$BASE"
    fi
    ;;
esac

RELEASE_NAME="release-$VERSION-$SHA"

case "${1:-}" in
  --version) echo "$VERSION" ;;
  --build)   echo "$BUILD" ;;
  --sha)     echo "$SHA" ;;
  --name)    echo "$RELEASE_NAME" ;;
  ""|--env)
    printf 'VERSION=%s\nBUILD=%s\nSHA=%s\nRELEASE_NAME=%s\n' \
      "$VERSION" "$BUILD" "$SHA" "$RELEASE_NAME"
    ;;
  -h|--help)
    sed -n '3,10p' "$SELF" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "version.sh: unknown option $1" >&2
    exit 2
    ;;
esac
