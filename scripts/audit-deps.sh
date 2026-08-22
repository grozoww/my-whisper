#!/usr/bin/env bash
#
# Checks the dependency graph for the two things that actually bite a small project:
# a version that is not pinned, and a version with a published vulnerability.
#
#   ./scripts/audit-deps.sh              both checks
#   ./scripts/audit-deps.sh --pins       pinning and drift only, no network
#   ./scripts/audit-deps.sh --vulns      vulnerability query only
#
# Exits non-zero on a finding, so CI fails rather than printing a warning nobody reads.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="OurWhisper.xcodeproj"
RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
failures=0

fail() { echo "${RED}FAIL${OFF}  $*"; failures=$((failures + 1)); }
pass() { echo "${GREEN}ok${OFF}    $*"; }
warn() { echo "${YELLOW}warn${OFF}  $*"; }

# ---------------------------------------------------------------------------
# Pinning
#
# Every direct dependency must use `kind = exactVersion`. A range means the build is not
# reproducible: CI and a contributor's machine can resolve different code from the same commit,
# and a compromised release inside the range lands automatically. Transitive dependencies are
# whatever our direct ones ask for, which is why Package.resolved is committed — it pins those.
# ---------------------------------------------------------------------------
check_pins() {
  echo "${DIM}— Direct dependencies —${OFF}"

  local loose
  loose="$(grep -A3 'requirement = {' "$PROJECT/project.pbxproj" \
    | grep -E 'kind = (upToNextMajorVersion|upToNextMinorVersion|versionRange|branch|revision)' || true)"

  if [ -n "$loose" ]; then
    fail "a dependency is not pinned to an exact version:"
    echo "$loose" | sed 's/^/        /'
  else
    local count
    count="$(grep -c 'kind = exactVersion' "$PROJECT/project.pbxproj" || echo 0)"
    pass "all $count direct dependencies pinned to an exact version"
  fi

  if [ ! -f "$RESOLVED" ]; then
    fail "Package.resolved is missing — transitive dependencies are unpinned"
    return
  fi

  # A branch or revision pin in the resolved file means someone is tracking a moving target.
  if grep -q '"branch"' "$RESOLVED"; then
    fail "Package.resolved contains a branch pin"
  else
    pass "no branch pins in Package.resolved"
  fi

  echo
  echo "${DIM}— Resolved graph —${OFF}"
  python3 - "$RESOLVED" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
width = max(len(p["identity"]) for p in pins)
for pin in sorted(pins, key=lambda p: p["identity"]):
    state = pin["state"]
    print(f"      {pin['identity']:<{width}}  {state.get('version', state.get('branch', state['revision'][:12]))}")
PY
}

# ---------------------------------------------------------------------------
# Drift
#
# Package.resolved must already match what resolution produces. If it does not, someone changed
# a version in the project without committing the resolved file, and every clone gets a
# different graph than the one that was reviewed.
# ---------------------------------------------------------------------------
check_drift() {
  echo
  echo "${DIM}— Lockfile drift —${OFF}"

  local before after
  before="$(shasum -a 256 "$RESOLVED" | cut -d' ' -f1)"
  xcodebuild -project "$PROJECT" -scheme OurWhisper -resolvePackageDependencies >/dev/null 2>&1 || true
  after="$(shasum -a 256 "$RESOLVED" | cut -d' ' -f1)"

  if [ "$before" != "$after" ]; then
    fail "Package.resolved changed during resolution — commit the updated file"
    git --no-pager diff --stat -- "$RESOLVED" || true
  else
    pass "Package.resolved is in sync with the project"
  fi
}

# ---------------------------------------------------------------------------
# Vulnerabilities
#
# Queried from OSV.dev, which carries the GitHub Advisory Database under its `SwiftURL`
# ecosystem. No account, no token, no data about this machine leaves beyond the package names
# and versions that are already public in Package.resolved.
# ---------------------------------------------------------------------------
check_vulns() {
  echo
  echo "${DIM}— Known vulnerabilities (osv.dev) —${OFF}"

  if [ ! -f "$RESOLVED" ]; then
    fail "Package.resolved is missing; nothing to query"
    return
  fi

  local report
  report="$(python3 - "$RESOLVED" <<'PY'
import json, sys, urllib.request, urllib.error

pins = json.load(open(sys.argv[1]))["pins"]
findings = 0
skipped = []

for pin in sorted(pins, key=lambda p: p["identity"]):
    version = pin["state"].get("version")
    if not version:
        skipped.append(pin["identity"])
        continue

    # OSV identifies a Swift package by its repository URL with the scheme and .git suffix
    # removed — "github.com/owner/repo".
    name = pin["location"].removeprefix("https://").removeprefix("http://").removesuffix(".git")
    query = json.dumps({"version": version, "package": {"name": name, "ecosystem": "SwiftURL"}}).encode()

    try:
        request = urllib.request.Request(
            "https://api.osv.dev/v1/query", data=query, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            vulns = json.load(response).get("vulns", [])
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        print(f"QUERY-FAILED {pin['identity']} {error}")
        continue

    if vulns:
        findings += len(vulns)
        for vuln in vulns:
            summary = vuln.get("summary") or vuln.get("details", "")[:100]
            print(f"VULN {pin['identity']} {version} {vuln['id']} {summary}")
    else:
        print(f"CLEAN {pin['identity']} {version} {name}")

for identity in skipped:
    print(f"SKIPPED {identity} pinned to a revision, so no version to query")

print(f"TOTAL {findings}")
PY
)"

  echo "$report" | while IFS= read -r line; do
    case "$line" in
      CLEAN*)        pass "$(echo "$line" | cut -d' ' -f2-)" ;;
      VULN*)         fail "$(echo "$line" | cut -d' ' -f2-)" ;;
      SKIPPED*)      warn "$(echo "$line" | cut -d' ' -f2-)" ;;
      QUERY-FAILED*) warn "could not query $(echo "$line" | cut -d' ' -f2-)" ;;
    esac
  done

  local total
  total="$(echo "$report" | awk '/^TOTAL/{print $2}')"
  if [ "${total:-0}" -gt 0 ]; then
    failures=$((failures + total))
  fi
}

case "${1:---all}" in
  --pins)  check_pins; check_drift ;;
  --vulns) check_vulns ;;
  *)       check_pins; check_drift; check_vulns ;;
esac

echo
if [ "$failures" -gt 0 ]; then
  echo "${RED}$failures problem(s) found.${OFF}"
  exit 1
fi
echo "${GREEN}Dependencies are pinned and clean.${OFF}"
