#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_SIM_NAME="${IOS_SIM_NAME:-iPhone 17}"
IOS_SIM_OS="${IOS_SIM_OS:-26.0}"
DESTINATION="platform=iOS Simulator,name=${IOS_SIM_NAME},OS=${IOS_SIM_OS}"

cd "$ROOT_DIR"

echo "[pre-pr-check] Running swift test"
swift test

DESTINATIONS="$(xcodebuild -scheme skip-web -showdestinations 2>/dev/null || true)"
if ! printf '%s\n' "$DESTINATIONS" | grep -q "platform:iOS Simulator.*name:${IOS_SIM_NAME}.*OS:${IOS_SIM_OS}[, ]"; then
  FALLBACK_OS="$(
    printf '%s\n' "$DESTINATIONS" | awk -v dev="$IOS_SIM_NAME" '
      /platform:iOS Simulator/ && index($0, "name:" dev) {
        if (match($0, /OS:[^,}]+/)) {
          print substr($0, RSTART + 3, RLENGTH - 3)
          exit
        }
      }'
  )"

  if [ -n "$FALLBACK_OS" ]; then
    DESTINATION="platform=iOS Simulator,name=${IOS_SIM_NAME},OS=${FALLBACK_OS}"
    echo "[pre-pr-check] Requested ${IOS_SIM_NAME} iOS ${IOS_SIM_OS} unavailable; using iOS ${FALLBACK_OS}"
  fi
fi

echo "[pre-pr-check] Running iOS build-for-testing on $DESTINATION"
xcodebuild build-for-testing \
  -scheme skip-web \
  -destination "$DESTINATION"

echo "[pre-pr-check] All checks passed"
