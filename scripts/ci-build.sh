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
    # ANDROID_UPLOAD_KEYSTORE is a file-type CI variable holding the BASE64
    # of the upload keystore: GitLab variables are text, so a binary JKS
    # pasted in verbatim would be mangled. Decode it to a real keystore.
    base64 -d "$ANDROID_UPLOAD_KEYSTORE" > /tmp/aity-upload.keystore \
        || { echo "FATAL: ANDROID_UPLOAD_KEYSTORE is not valid base64" >&2; exit 1; }
    export OC_RELEASE_KEYSTORE=/tmp/aity-upload.keystore
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
# Upstream's CI builds and tests on JDK 17 (temurin); the SDK image ships a
# newer JDK on which the Pin's mockk cannot mock JDK classes (NPE storm in
# owncloudData unit tests). Pin the Gradle JVM to 17 so the materialized
# tree builds exactly like upstream's own CI.
JAVA17_HOME=/usr/lib/jvm/java-17-openjdk-amd64
if [ ! -d "$JAVA17_HOME" ]; then
    echo "==> installing openjdk-17 (image JDK is $(java -version 2>&1 | head -1))"
    apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-17-jdk-headless >/dev/null
fi

# GRADLE_USER_HOME gradle.properties overrides the project's; upstream's
# 1536M heap is too small for an AGP 8 release build of this app.
mkdir -p "${GRADLE_USER_HOME:-$HOME/.gradle}"
cat > "${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties" <<PROPS
org.gradle.java.home=$JAVA17_HOME
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
    # The manifest's intent-filter scheme/host stay resource REFERENCES in
    # the binary manifest (resolved by the platform at install time), so
    # they are asserted through the compiled resource table instead.
    local badging resources
    badging="$("$AAPT2" dump badging "$apk")"
    resources="$("$AAPT2" dump resources "$apk")"

    echo "$badging" | grep -F "package: name='$app_id'" \
        || { echo "FATAL: applicationId is not $app_id" >&2; exit 1; }
    echo "$badging" | grep -F "versionCode='$VERSION_CODE'" >/dev/null \
        || { echo "FATAL: versionCode is not $VERSION_CODE" >&2; exit 1; }
    echo "$badging" | grep -F "versionName='$VERSION_NAME'" >/dev/null \
        || { echo "FATAL: versionName is not $VERSION_NAME" >&2; exit 1; }
    echo "$badging" | grep -F "application-label:'$label'" \
        || { echo "FATAL: app label is not '$label'" >&2; exit 1; }
    echo "$badging" | grep -F "targetSdkVersion:'36'" \
        || { echo "FATAL: targetSdkVersion is not 36 (Play requires API 36 for new apps from 2026-08-31)" >&2; exit 1; }
    echo "$resources" | grep -A2 "string/oauth2_redirect_uri_scheme" | grep -F "\"$scheme\"" >/dev/null \
        || { echo "FATAL: oauth2_redirect_uri_scheme is not $scheme" >&2; exit 1; }
    echo "$resources" | grep -A2 "string/oauth2_redirect_uri_host" | grep -F "\"$host\"" >/dev/null \
        || { echo "FATAL: oauth2_redirect_uri_host is not $host" >&2; exit 1; }
    echo "$resources" | grep -A2 "string/oauth2_client_id" | grep -F "\"drive-android\"" >/dev/null \
        || { echo "FATAL: oauth2_client_id is not drive-android" >&2; exit 1; }
    echo "$resources" | grep -A2 "string/server_url" | head -3 | grep -q "aity" \
        || { echo "FATAL: server_url does not point at an aity host" >&2; exit 1; }
    local app_host="app.aity.tech"
    [ "$app_id" = tech.aity.drive.staging ] && app_host="app.aity.works"
    for entry in "url_privacy_policy:policy" "aity_delete_account_url:account-deletion" "aity_delete_data_url:data-deletion"; do
        local key="${entry%%:*}" route="${entry#*:}"
        echo "$resources" | grep -A2 "string/$key" | grep -F "https://$app_host/privacy/$route" >/dev/null \
            || { echo "FATAL: $key points to the wrong privacy environment" >&2; exit 1; }
    done
    echo "==> OK: $app_id / '$label' / ${scheme}://$host / versionName $VERSION_NAME ($VERSION_CODE) / targetSdk 36"
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
