# Patch inventory

Honest, hunk-by-hunk. Zero Patches is the target; a Patch needs "not
shippable without it" plus this entry. Everything expressible as Branding
lives in `overlay/` instead (see README for what the Overlay covers WITHOUT
patches: app name, account type, every provider authority, oauth client,
redirect scheme/host, server lock, colors, icons - all resource overrides
through the `original` flavor source set).

## 0001-application-identity-and-version-wiring.patch

- **File**: `owncloudApp/build.gradle`, one hunk in `defaultConfig`.
- **What**: adds `applicationId` read from the Gradle property
  `aityApplicationId` (supplied per Environment by the overlay's
  `owncloudApp/gradle.properties`), and makes `versionCode`/`versionName`
  overridable via `-PaityVersionCode`/`-PaityVersionName` (CI passes
  `CI_PIPELINE_IID` and the tag-derived version). Every value falls back to
  upstream's, so the patched tree without the overlay builds exactly like
  upstream.
- **Why a Patch**: upstream sets no `applicationId` at all - the install
  identity falls back to the `namespace` `com.owncloud.android`, which we
  must not ship (trademark, and staging/production must coexist). AGP only
  accepts `applicationId`/`versionCode`/`versionName` from Gradle build
  scripts; no resource, manifest placeholder, or gradle.properties key can
  express them without a build.gradle change, and a Gradle init script
  would not survive a plain Android Studio build of the materialized tree.
  Upstream's `OC_APP_NAME`/`OC_BUILD_NUMBER` env vars only rename the
  output file.
- **Bump risk**: the hunk replaces upstream's literal
  `versionCode`/`versionName` lines, so it goes STALE on every upstream
  version change - `materialize.sh` then fails loudly and the patch is
  regenerated with the new fallbacks (procedure in `UPSTREAM.md`).
