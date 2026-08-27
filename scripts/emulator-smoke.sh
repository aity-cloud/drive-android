#!/usr/bin/env bash
# Aity Drive for Android - the account journey smoke on an emulator.
#
#   scripts/emulator-smoke.sh <production|staging>
#
# Materialises the Environment, builds the debug app plus its instrumented
# test APK, boots a headless emulator and runs
# tech.aity.drive.smoke.AccountJourneySmokeTest against the server that build
# points at: sign in with the real drive-android OIDC client, see a file that
# was seeded over WebDAV before launch, create a folder from the app, remove
# it again, leave nothing behind.
#
# Credentials come from AITY_CONTRACT_USER / AITY_CONTRACT_PASSWORD (protected
# CI variables on the aity-cloud/drive group) and are passed to the
# instrumentation, never written to a file and never baked into an APK.
# Without them the test skips itself rather than failing.
#
# Knobs:
#   AITY_SMOKE_REPEAT   how many times to run the test (default 1). >1 reports
#                       a pass rate and only fails when every run failed - it
#                       is a MEASUREMENT, not a gate.
#   AITY_SMOKE_AVD      AVD name (default aity-drive-smoke)
#   AITY_SMOKE_API      API level of the system image (default 36)
#   AITY_SMOKE_ABI      system image ABI (default: matches the host)
#   AITY_SMOKE_SKIP_BUILD=true  reuse the APKs from a previous run
#
# The runner needs a working KVM (Linux) or HVF (macOS); on the `macos` runner
# that is an Apple Silicon arm64-v8a image.
set -euo pipefail

ENVIRONMENT="${1:?usage: $0 <production|staging>}"
case "$ENVIRONMENT" in production|staging) ;; *) echo "unknown environment '$ENVIRONMENT'" >&2; exit 64 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?ANDROID_HOME or ANDROID_SDK_ROOT must be set}}"
AVD="${AITY_SMOKE_AVD:-aity-drive-smoke}"
API="${AITY_SMOKE_API:-36}"
case "$(uname -m)" in
    arm64|aarch64) HOST_ABI=arm64-v8a ;;
    *) HOST_ABI=x86_64 ;;
esac
ABI="${AITY_SMOKE_ABI:-$HOST_ABI}"
IMAGE="system-images;android-${API};google_apis;${ABI}"
REPEAT="${AITY_SMOKE_REPEAT:-1}"
TEST_CLASS="tech.aity.drive.smoke.AccountJourneySmokeTest"

note() { echo "==> $*"; }

# --- the tree -----------------------------------------------------------------
if [ "${AITY_SMOKE_SKIP_BUILD:-}" != "true" ]; then
    bash scripts/materialize.sh "$ENVIRONMENT"
fi

# --- the emulator -------------------------------------------------------------
note "emulator: $IMAGE as AVD '$AVD'"
if ! "$SDK/cmdline-tools/latest/bin/avdmanager" list avd -c 2>/dev/null | grep -qx "$AVD"; then
    # pipefail off for this one line only: sdkmanager closes its stdin, `yes`
    # dies of SIGPIPE (141), and with pipefail that status kills the script
    # before the emulator is ever created. Cost one silent no-op run.
    set +o pipefail
    yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --install "$IMAGE" >/dev/null
    set -o pipefail
    echo no | "$SDK/cmdline-tools/latest/bin/avdmanager" create avd \
        --name "$AVD" --package "$IMAGE" --device pixel_6 --force >/dev/null
fi

"$SDK/platform-tools/adb" start-server >/dev/null 2>&1 || true
# -no-snapshot so every run starts from the same state: an account left behind
# by a previous run would make the second run test nothing.
"$SDK/emulator/emulator" -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -no-snapshot -gpu swiftshader_indirect -netdelay none -netspeed full \
    -accel auto >"${TMPDIR:-/tmp}/aity-emulator.log" 2>&1 &
EMULATOR_PID=$!

cleanup() {
    note "shutting the emulator down"
    "$SDK/platform-tools/adb" emu kill >/dev/null 2>&1 || true
    kill "$EMULATOR_PID" >/dev/null 2>&1 || true
    wait "$EMULATOR_PID" 2>/dev/null || true
}
trap cleanup EXIT

note "waiting for the emulator to boot"
"$SDK/platform-tools/adb" wait-for-device
for _ in $(seq 1 180); do
    [ "$("$SDK/platform-tools/adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
done
[ "$("$SDK/platform-tools/adb" shell getprop sys.boot_completed | tr -d '\r')" = "1" ] \
    || { echo "the emulator never finished booting; log:" >&2; tail -40 "${TMPDIR:-/tmp}/aity-emulator.log" >&2; exit 1; }

# Animations turn "wait for this view" into a coin flip.
for scale in window_animation_scale transition_animation_scale animator_duration_scale; do
    "$SDK/platform-tools/adb" shell settings put global "$scale" 0 || true
done
"$SDK/platform-tools/adb" shell input keyevent 82 >/dev/null 2>&1 || true

# --- the APKs -----------------------------------------------------------------
APK_DIR="build/upstream/owncloudApp/build/outputs/apk"
if [ "${AITY_SMOKE_SKIP_BUILD:-}" != "true" ]; then
    note "building the debug app and its instrumented test APK"
    ( cd build/upstream && ./gradlew --stacktrace \
        :owncloudApp:assembleOriginalDebug \
        :owncloudApp:assembleOriginalDebugAndroidTest )
fi

app_apks=("$APK_DIR"/original/debug/*.apk)
test_apks=("$APK_DIR"/androidTest/original/debug/*.apk)
APP_APK="${app_apks[0]}"
TEST_APK="${test_apks[0]}"
note "app  $APP_APK"
note "test $TEST_APK"

aapt2s=("$SDK"/build-tools/*/aapt2)
AAPT2="${aapt2s[${#aapt2s[@]}-1]}"
TEST_PACKAGE="$("$AAPT2" dump badging "$TEST_APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
RUNNER="$("$AAPT2" dump badging "$TEST_APK" | sed -n "s/.*instrumentation: name='\([^']*\)'.*/\1/p" | head -n1)"
: "${RUNNER:=com.owncloud.android.utils.OCTestAndroidJUnitRunner}"
note "instrumentation ${TEST_PACKAGE}/${RUNNER}"

app_package="$("$AAPT2" dump badging "$APP_APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"

if [ -z "${AITY_CONTRACT_USER:-}" ] || [ -z "${AITY_CONTRACT_PASSWORD:-}" ]; then
    echo "!!! AITY_CONTRACT_USER / AITY_CONTRACT_PASSWORD are not set - the journey"
    echo "!!! will skip itself (protected CI variables on the aity-cloud/drive group)."
fi

# --- run ----------------------------------------------------------------------
mkdir -p reports/emulator
green=0
for run in $(seq 1 "$REPEAT"); do
    log="reports/emulator/instrument-${run}.log"
    note "run ${run}/${REPEAT}"
    # A FRESH install before EVERY run, including the first: the AVD keeps its
    # userdata across emulator restarts, so the account a previous run created
    # is still there and the app opens straight into the file list - a run that
    # starts logged in is not the test anybody wrote, and it fails with "the
    # login screen never appeared" (hit 2026-08-27).
    "$SDK/platform-tools/adb" uninstall "$app_package" >/dev/null 2>&1 || true
    "$SDK/platform-tools/adb" install -r -t "$APP_APK" >/dev/null
    "$SDK/platform-tools/adb" install -r -t "$TEST_APK" >/dev/null

    # Not `set -x` around this line on purpose: it carries the password.
    set +x
    "$SDK/platform-tools/adb" shell am instrument -w -r \
        -e class "$TEST_CLASS" \
        -e aityUser "${AITY_CONTRACT_USER:-}" \
        -e aityPassword "${AITY_CONTRACT_PASSWORD:-}" \
        "${TEST_PACKAGE}/${RUNNER}" > "$log" 2>&1 || true

    if grep -q "INSTRUMENTATION_CODE: -1" "$log" && ! grep -q "FAILURES!!!" "$log"; then
        note "run ${run}: PASS"
        green=$((green + 1))
    else
        note "run ${run}: FAIL"
        sed -n '1,200p' "$log"
        # The app's own log explains most failures better than the test does.
        "$SDK/platform-tools/adb" logcat -d -t 400 AityDriveSmoke:V "*:E" \
            > "reports/emulator/logcat-${run}.log" 2>&1 || true
        tail -60 "reports/emulator/logcat-${run}.log" || true
    fi
done

note "pass rate: ${green}/${REPEAT}"
if [ "$green" -eq 0 ]; then
    echo "emulator smoke failed every run" >&2
    exit 1
fi
