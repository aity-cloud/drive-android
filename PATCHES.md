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

## 0002-androidtest-exclude-uncompilable-upstream-tests.patch

- **File**: `owncloudApp/build.gradle`, one hunk appended after the
  `android { }` block: a `KotlinCompile` configuration that excludes three
  files from the `androidTest` compilation only.
- **What**: excludes
  `settings/security/PassCodeActivityTest.kt`,
  `settings/security/PatternActivityTest.kt` and
  `logging/LogsListActivityTest.kt` from the instrumented-test source set.
- **Why a Patch**: those three of upstream's OWN instrumented tests do not
  COMPILE at Pin v4.8.4 - they reference R ids that were renamed in the
  layouts (`error`/`explanation` are `passcode_error`/`passcode_explanation`
  now, `header_pattern`/`explanation_pattern` are
  `pattern_header`/`pattern_explanation`, and `toolbar_activity_logs_list`
  no longer exists). Kotlin compiles a source set as a unit, so three dead
  files block EVERY instrumented test in the module, including our account
  journey smoke (`smoke:emulator`). Nothing in `overlay/` can express this:
  an Overlay copies files in, it cannot remove them from a compilation, and
  the exclusion has to live in the build script. Rewriting upstream's tests
  instead would be a far larger patch to code we do not run.
- **Upstream**: their CI runs `:ownCloudData:connectedAndroidTest` only
  (`.github/workflows/android-instrumented-data-tests.yml`), never the app
  module's, which is why this rot is unnoticed. Worth reporting upstream.
- **Bump risk**: LOW as a patch (it appends, so it does not conflict with
  upstream edits), but it must be RE-EXAMINED on every Bump: if upstream
  fixes the ids, delete this patch; if they break a fourth file, the
  emulator smoke fails to build and the list needs extending.

## 0003-workspace-privacy-entry-points.patch

- **File**: `SettingsFragment.kt`, browser intent import and two preferences.
- **What**: discoverable account and selected-data deletion links next to the
  privacy policy. Labels and the three environment-specific URLs are Branding.
- **Why not shippable without it**: upstream offers a single privacy-policy
  resource but no configurable additional account/data actions. Replacing the
  entire settings XML in the overlay would hide upstream additions on a Bump.
  This small additive patch preserves the factory's overlay-only rule.
- **Scope**: the labels explain suite-wide account deletion and distinguish
  device removal. Browser links carry no identity or credentials.
- **Bump risk**: recheck `SettingsFragment.onCreatePreferences` and preference
  ordering. Both environments must materialize and open their own URLs.
