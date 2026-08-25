#!/usr/bin/env bash
# CI build: materialize and build BOTH Environment builds (AAB + APK each),
# run the unit tests of the materialized tree once, and verify the branded
# identity inside the produced APKs. Runs inside the Android SDK image; see
# .gitlab-ci.yml and MAINTAINING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${UPSTREAM_TAG:?UPSTREAM_TAG must be set (pipeline variable)}"
VERSION_CODE="${CI_PIPELINE_IID:?CI_PIPELINE_IID must be set}"

if [ -n "${CI_COMMIT_TAG:-}" ]; then
    # Release contract: v<upstream>-aity-<n>, upstream part == the Pin.
    case "$CI_COMMIT_TAG" in
        "${UPSTREAM_TAG}-aity-"*) ;;
        *)
            echo "FATAL: tag $CI_COMMIT_TAG does not match the Pin $UPSTREAM_TAG" >&2
            echo "(release tags are ${UPSTREAM_TAG}-aity-<n>; move the Pin first)" >&2
            exit 1
            ;;
    esac
    VERSION_NAME="${CI_COMMIT_TAG#v}"
else
    VERSION_NAME="dev"
fi
echo "==> versionName=$VERSION_NAME versionCode=$VERSION_CODE (pin $UPSTREAM_TAG)"

# --- signing -----------------------------------------------------------------
# Upstream's build.gradle reads the release signing config from OC_RELEASE_*
# environment variables, so no gradle change is needed. Without the upload
# keystore we sign with a throwaway debug keystore instead of failing: the
# artifacts stay installable (emulator smoke, manual installs) but are NOT
# uploadable to Play.
if [ -n "${ANDROID_UPLOAD_KEYSTORE:-}" ]; then
    export OC_RELEASE_KEYSTORE="$ANDROID_UPLOAD_KEYSTORE"
    export OC_RELEASE_KEYSTORE_PASSWORD="${ANDROID_UPLOAD_KEYSTORE_PASSWORD:?set together with ANDROID_UPLOAD_KEYSTORE}"
    export OC_RELEASE_KEY_ALIAS="${ANDROID_UPLOAD_KEY_ALIAS:?set together with ANDROID_UPLOAD_KEYSTORE}"
    export OC_RELEASE_KEY_PASSWORD="${ANDROID_UPLOAD_KEY_PASSWORD:?set together with ANDROID_UPLOAD_KEYSTORE}"
    echo "==> signing with the upload keystore (ANDROID_UPLOAD_KEYSTORE)"
else
    echo "!!! ANDROID_UPLOAD_KEYSTORE is not set - signing with a THROWAWAY"
    echo "!!! DEBUG KEYSTORE generated for this job. These artifacts are"
    echo "!!! debug-signed: installable, but NOT uploadable to Google Play."
    DEBUG_KS=/tmp/aity-debug.keystore
    keytool -genkeypair -keystore "$DEBUG_KS" -storepass android \
        -keypass android -alias aitydebug -keyalg RSA -keysize 2048 \
        -validity 10000 -dname "CN=Aity Drive debug signing" >/dev/null 2>&1
    export OC_RELEASE_KEYSTORE="$DEBUG_KS"
    export OC_RELEASE_KEYSTORE_PASSWORD=android
    export OC_RELEASE_KEY_ALIAS=aitydebug
    export OC_RELEASE_KEY_PASSWORD=android
fi

# --- gradle environment ------------------------------------------------------
# GRADLE_USER_HOME gradle.properties overrides the project's; upstream's
# 1536M heap is too small for an AGP 8 release build of this app.
mkdir -p "${GRADLE_USER_HOME:-$HOME/.gradle}"
cat > "${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties" <<'PROPS'
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g
org.gradle.daemon=false
PROPS

AAPT2="$(ls "${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no ANDROID_HOME}}"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)"
echo "==> using aapt2 at $AAPT2"

mkdir -p dist reports/junit

# --- helpers -----------------------------------------------------------------
verify_apk() {
    local apk="$1" app_id="$2" label="$3" scheme="$4" host="$5"
    echo "==> verifying $apk"
    local badging manifest
    badging="$("$AAPT2" dump badging "$apk")"
    manifest="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$apk")"

    echo "$badging" | grep -F "package: name='$app_id'" \
        || { echo "FATAL: applicationId is not $app_id" >&2; exit 1; }
    echo "$badging" | grep -F "application-label:'$label'" \
        || { echo "FATAL: app label is not '$label'" >&2; exit 1; }
    echo "$badging" | grep -F "targetSdkVersion:'36'" \
        || { echo "FATAL: targetSdkVersion is not 36 (Play requires API 36 for new apps from 2026-08-31)" >&2; exit 1; }
    echo "$manifest" | grep -F "android:scheme" | grep -F "\"$scheme\"" >/dev/null \
        || { echo "FATAL: oauth redirect scheme $scheme missing from manifest" >&2; exit 1; }
    echo "$manifest" | grep -F "android:host" | grep -F "\"$host\"" >/dev/null \
        || { echo "FATAL: oauth redirect host $host missing from manifest" >&2; exit 1; }
    echo "==> OK: $app_id / '$label' / ${scheme}://$host / targetSdk 36"
}

build_env() {
    local env="$1" app_id="$2" label="$3" scheme="$4" host="$5" run_tests="$6"
    local out_name="aity-drive"
    [ "$env" = staging ] && out_name="aity-drive-staging"

    bash scripts/materialize.sh "$env"

    if [ "$run_tests" = yes ]; then
        echo "==> unit tests of the materialized tree ($env)"
        ( cd build/upstream && ./gradlew --stacktrace \
            :owncloudApp:testOriginalReleaseUnitTest \
            :owncloudData:testReleaseUnitTest \
            :owncloudDomain:testReleaseUnitTest )
        find build/upstream -path '*/test-results/*' -name 'TEST-*.xml' \
            -exec cp {} reports/junit/ \;
    fi

    echo "==> building $env ($app_id)"
    ( cd build/upstream && \
      OC_APP_NAME="$out_name" OC_BUILD_NUMBER="$VERSION_CODE" ./gradlew --stacktrace \
        -PaityVersionName="$VERSION_NAME" -PaityVersionCode="$VERSION_CODE" \
        :owncloudApp:assembleOriginalRelease :owncloudApp:bundleOriginalRelease )

    mkdir -p "dist/$env"
    local apk aab
    apk="$(ls build/upstream/owncloudApp/build/outputs/apk/original/release/*.apk)"
    aab="$(ls build/upstream/owncloudApp/build/outputs/bundle/originalRelease/*.aab)"
    cp "$apk" "dist/$env/${out_name}_${VERSION_NAME}_${VERSION_CODE}.apk"
    cp "$aab" "dist/$env/${out_name}_${VERSION_NAME}_${VERSION_CODE}.aab"

    verify_apk "dist/$env/${out_name}_${VERSION_NAME}_${VERSION_CODE}.apk" \
        "$app_id" "$label" "$scheme" "$host"
}

# --- both Environment builds, always -----------------------------------------
build_env production tech.aity.drive "Aity Drive" aitydrive android.aity.tech yes
build_env staging tech.aity.drive.staging "Aity Drive (staging)" aitydrive-staging android.aity.works no

echo "==> artifacts:"
ls -l dist/production dist/staging
