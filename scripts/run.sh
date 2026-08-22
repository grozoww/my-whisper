#!/usr/bin/env bash
#
# Build and (re)launch OurWhisper. Editor-agnostic — works from VS Code, Cursor, a bare terminal,
# or anywhere else. Xcode is only needed for SwiftUI previews and GUI breakpoint debugging.
#
#   ./scripts/run.sh              build Debug and relaunch
#   ./scripts/run.sh --build      build only
#   ./scripts/run.sh --test       run the unit tests
#   ./scripts/run.sh --check      what CI runs: warning-free build, tests, dependency audit
#   ./scripts/run.sh --logs       tail the app's logs (also works while it runs)
#   ./scripts/run.sh --selftest speech.wav [ru]
#                                 transcribe a file and print the result, no UI needed

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="OurWhisper"
CONFIG="Debug"
SUBSYSTEM="com.grozoww.ourwhisper"

# Deliberately uses Xcode's default DerivedData rather than a local build/ directory.
# buildServer.json — what gives VS Code its code intelligence — points at that same location, and
# a custom -derivedDataPath would leave the editor indexing a directory nothing ever writes to.
app_path() {
  xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
}

build() {
  echo "==> Building $SCHEME ($CONFIG)"
  set -o pipefail
  xcodebuild \
    -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    build \
    | grep -E '(error|warning):|BUILD (SUCCEEDED|FAILED)' || true

  APP="$(app_path)/$SCHEME.app"
  BINARY="$APP/Contents/MacOS/$SCHEME"
  [ -d "$APP" ] || { echo "Build produced no app bundle."; exit 1; }

  # Xcode's DerivedData path contains a machine-specific hash, so nothing can reference the
  # built app by a fixed path. This symlink gives one — which is what lets VS Code's debugger
  # configuration name a program path that keeps working.
  mkdir -p build
  ln -sfn "$APP" "build/$SCHEME.app"
}

stop() {
  pkill -f "$SCHEME.app/Contents/MacOS/$SCHEME" 2>/dev/null || true
}

# The test target uses the app as its test host, so launching it must not start a 600 MB model
# download — see `AppState.isRunningTests`.
run_tests() {
  echo "==> Testing $SCHEME"
  set -o pipefail
  xcodebuild \
    -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    test 2>&1 \
    | grep -vE 'linkd\.autoShortcut|Process Instance Registry' \
    | grep -E '(error|warning):|✘|✔ Test run|TEST (SUCCEEDED|FAILED)' || true
}

case "${1:-}" in
  --build)
    build
    ;;

  --test)
    run_tests
    ;;

  --check)
    # The same gates as .github/workflows/ci.yml, so a failure shows up here rather than after a
    # push. CONTRIBUTING.md makes the warning-free build a rule; this is where it is enforced.
    echo "==> Building (warnings are errors here)"
    set -o pipefail
    xcodebuild \
      -project "$SCHEME.xcodeproj" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -destination 'platform=macOS' \
      clean build 2>&1 | tee /tmp/ourwhisper-build.log \
      | grep -E '(error|warning):|BUILD (SUCCEEDED|FAILED)' || true

    if grep -qE '^/.*warning:' /tmp/ourwhisper-build.log; then
      echo "Build produced warnings. See CONTRIBUTING.md — keep the build warning-free."
      exit 1
    fi

    run_tests
    ./scripts/audit-deps.sh
    ;;

  --logs)
    # `log show` hides info-level messages unless asked, and most of this app's useful output —
    # transcripts, timings, model loading — is logged at info.
    echo "==> Streaming $SUBSYSTEM logs (ctrl-C to stop)"
    exec /usr/bin/log stream --level info --predicate "subsystem == \"$SUBSYSTEM\"" --style compact
    ;;

  --selftest)
    FILE="${2:?usage: ./scripts/run.sh --selftest <audio-file> [language-code]}"
    LANG_CODE="${3:-auto}"
    build
    stop
    START="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "==> Transcribing $FILE ($LANG_CODE)"
    OURWHISPER_SELFTEST="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")" \
    OURWHISPER_SELFTEST_LANGUAGE="$LANG_CODE" \
      "$BINARY" >/dev/null 2>&1 &
    for _ in $(seq 1 60); do
      if /usr/bin/log show --start "$START" --info --predicate "subsystem == \"$SUBSYSTEM\"" --style compact 2>/dev/null \
         | grep -qE "Self-test finished|SELFTEST FAILED"; then break; fi
      sleep 2
    done
    /usr/bin/log show --start "$START" --info --predicate "subsystem == \"$SUBSYSTEM\"" --style compact 2>/dev/null \
      | grep -E "RESULT|TIMING|FAILED" | sed "s/.*\[$SUBSYSTEM:selftest\] //"
    stop
    ;;

  *)
    build
    stop
    echo "==> Launching"
    open "$APP"
    echo
    echo "It is a menu bar app — look for the microphone icon, not the Dock."
    echo "Logs: ./scripts/run.sh --logs"
    ;;
esac
