#!/usr/bin/env bash
# Capture evidence before android-emulator-runner shuts the emulator down.
set -euo pipefail

project=${DIAGNOSTIC_PROJECT:-.build/plugins/outputs/skip-web/SkipWebTests/destination/skipstone}
output=${DIAGNOSTIC_DIR:?Set DIAGNOSTIC_DIR to a directory outside the checkout}
scope=${DIAGNOSTIC_SCOPE:-suite}
repetitions=${DIAGNOSTIC_REPETITIONS:-3}
if [[ ! "$repetitions" =~ ^([1-9]|10)$ ]] || [[ "$scope" != suite && "$scope" != popup ]]; then
    echo 'Expected DIAGNOSTIC_REPETITIONS=1..10 and DIAGNOSTIC_SCOPE=suite|popup' >&2
    exit 64
fi
test -f "$project/settings.gradle.kts"
mkdir -p "$output"
adb shell dumpsys webviewupdate > "$output/webview-provider.txt" 2>&1
adb shell getprop ro.build.fingerprint > "$output/android-build.txt"
adb logcat -b all -v threadtime > "$output/logcat.txt" 2>&1 &
logcat_pid=$!

finish() {
    result=$?
    trap - EXIT
    set +e
    adb logcat -b crash -d -v threadtime > "$output/crash-buffer.txt" 2>&1
    adb shell dumpsys meminfo > "$output/memory.txt" 2>&1
    if [ "$result" -ne 0 ]; then
        python3 - "$output/bugreport.zip" > "$output/bugreport-command.txt" 2>&1 <<'PY'
import subprocess
import sys
try:
    subprocess.run(['adb', 'bugreport', sys.argv[1]], timeout=120, check=False)
except subprocess.TimeoutExpired:
    print('Bug report timed out after 120 seconds; other diagnostic files are retained.')
PY
    fi
    kill "$logcat_pid" 2>/dev/null
    wait "$logcat_pid" 2>/dev/null
    exit "$result"
}
trap finish EXIT

gradle_args=(:SkipWeb:connectedDebugAndroidTest --project-dir "$project"
    -PbuildDir=.build/SkipWeb --rerun-tasks --console=plain --stacktrace)
if [[ "$scope" == popup ]]; then
    gradle_args+=('-Pandroid.testInstrumentationRunnerArguments.class=skip.web.AndroidPopupStateIsolationTests')
fi

failed=0
for ((attempt = 1; attempt <= repetitions; attempt++)); do
    attempt_dir="$output/attempt-$attempt"
    mkdir -p "$attempt_dir"
    echo "Running $scope tests, attempt $attempt/$repetitions"
    adb shell log -t SkipWebCI "BEGIN attempt=$attempt scope=$scope"
    set +e
    gradle "${gradle_args[@]}" 2>&1 | tee "$attempt_dir/gradle.log"
    result=${PIPESTATUS[0]}
    set -e
    echo "$result" > "$attempt_dir/exit-code.txt"
    adb shell log -t SkipWebCI "END attempt=$attempt exit=$result" || true
    # Copy reports before the next run overwrites them. Include failed/partial runs.
    build="$project/SkipWeb/.build/SkipWeb"
    for report in outputs/androidTest-results reports/androidTests; do
        if [[ -d "$build/$report" ]]; then
            cp -R "$build/$report" "$attempt_dir/"
        fi
    done
    if [[ "$result" -ne 0 ]]; then
        failed=1
        # Keep running after a test-process crash to measure intermittency.
        # The final nonzero result still makes CI fail even if later attempts pass.
    fi
done
exit "$failed"
