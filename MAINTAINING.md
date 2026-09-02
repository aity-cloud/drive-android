# Maintaining this Factory

The standing loop (watch, response targets, per-Bump checklist) lives in
`drive/meta/docs/maintenance.md`. This file records the choices and the
traps that actually bit while building and running THIS Factory.

## Toolchain choices

- **CI build image: `ghcr.io/cirruslabs/android-sdk:36`.** Actively
  maintained by Cirrus Labs, tag tracks the compile/target SDK we need
  (the image major follows the SDK level - move it together with the
  Pin's `sdkCompileVersion`), comes with JDK + sdkmanager + build-tools,
  and is pulled from ghcr.io on purpose: the shared runner's IPv6 path to
  Docker Hub (`registry-1.docker.io`) has flaked before, so Docker Hub
  images are avoided (the utility jobs use the
  `registry.aity.tech/catalog` alpine for the same reason).
- **Signing needs no patch**: upstream's `owncloudApp/build.gradle`
  already reads the release keystore from `OC_RELEASE_KEYSTORE(_PASSWORD)`
  / `OC_RELEASE_KEY_ALIAS` / `OC_RELEASE_KEY_PASSWORD` environment
  variables. CI maps the protected `ANDROID_UPLOAD_KEYSTORE*` variables
  onto them; without them `scripts/ci-build.sh` generates a throwaway
  debug keystore so the pipeline never fails for missing signing (the log
  shouts when artifacts are debug-signed).
- **Output naming**: upstream's `OC_APP_NAME`/`OC_BUILD_NUMBER` env vars
  only rename APK files; identity and versions are wired through the one
  Patch (`PATCHES.md`).

## Traps actually hit

- **The SDK image's JDK is newer than upstream's CI JVM.** Upstream builds
  and tests on temurin 17 (their GitHub workflows); the Pin's mockk
  (1.13.3) cannot mock JDK classes like `java.io.File` on the image's
  newer JDK - every `owncloudData` `ScopedStorageProviderTest` case NPEs
  at the `mockk<File>()` line. `scripts/ci-build.sh` installs
  `openjdk-17-jdk-headless` and pins `org.gradle.java.home` to it so the
  materialized tree builds exactly like upstream CI. Revisit on every
  Bump: when upstream moves its workflows off 17, move this pin with
  them.
- **The binary manifest keeps resource references, not strings.** The
  intent-filter `android:scheme`/`android:host` come from `@string`
  resources and STAY references in the compiled AndroidManifest, so
  grepping `aapt2 dump xmltree` for the literal scheme always fails on a
  correct APK. The CI verification asserts through
  `aapt2 dump resources` (the resolved resource table) instead;
  `application-label` and `package` in `aapt2 dump badging` are safe
  because badging resolves them.
- **GitLab YAML eats colons in plain scalars.** A `script:` line like
  `echo "(spec: ...)"` parses as a mapping and fails pipeline creation
  with "script config should be a string"; quote the whole line.
- **The brand master is a raster in disguise.** `drive/meta/brand/logo.svg`
  is an SVG wrapping two embedded PNGs, the larger 188x152 px, and has no
  vector shapes. Launcher assets up to 432 px (xxxhdpi adaptive layer) are
  therefore UPSCALED from 188 px and look slightly soft at the largest
  sizes. `scripts/gen_icons.py` composites and LANCZOS-resamples the
  embedded rasters directly (better than a generic SVG renderer would).
  When a true-vector master lands in `drive/meta/brand/`, just re-run
  `scripts/gen-icons.sh` - it detects vector content and switches to
  `rsvg-convert`.
- **PEP 668 blocks `pip install --user`** on the workstation's Python
  (externally managed environment). `scripts/gen-icons.sh` therefore
  bootstraps its own venv under `build/icons-venv` for Pillow instead of
  touching the system Python. No rsvg-convert/Inkscape/ImageMagick were
  installed on the workstation either - nothing outside the venv is
  needed.
- **Upstream's oauth redirect and deep-link schemes must stay distinct.**
  `LoginActivity` treats ANY cold-start VIEW intent carrying data as a
  deep link, and only lives through an OAuth redirect because the redirect
  normally arrives via `onNewIntent`. After process death during the
  browser hop, a redirect that reused the deep-link scheme would misroute.
  Upstream keeps `oc` vs `owncloud` apart; we keep `aitydrive` vs
  `aitydrive-link` (and the `-staging` pair) apart for the same reason.
- **Two "ownCloud" literals leak into user-facing en strings**
  (`welcome_feature_3_text` on a first-run wizard slide,
  `prefs_enable_logging_summary` in advanced settings). The wizard is off
  (`wizard_enabled=false`), which retires the first across ALL locales;
  the second is overridden in en only - other locales keep upstream's
  translated sentence until upstream drops the vendor name. Known,
  accepted gap.

## Tier 2b: how the Custom Tab is stood in for (2026-08-27)

`smoke:emulator` used to be an `exit 1` placeholder. It now runs
`tech.aity.drive.smoke.AccountJourneySmokeTest` (in
`overlay/common/owncloudApp/src/androidTest/`) against the Environment the
build points at: sign in, see a file that was seeded over WebDAV before the
app launched, create a folder from the app, remove it again, leave nothing
behind. `scripts/emulator-smoke.sh` is the whole harness and takes the same
path on the Mac runner and on any Linux box with a working `/dev/kvm`.

**What is exercised and what is not.** The app builds its own authorization
request, holds its own PKCE verifier and `state`, does its own token
exchange and creates its own AccountManager account. The only thing replaced
is Chrome: Espresso-Intents stubs the outgoing `ACTION_VIEW`, the test walks
the Keycloak login over HTTP with the URL the app produced, and hands the
resulting redirect back with a plain `startActivity` - `LoginActivity` is
`singleTask` with an intent-filter on `oauth2_redirect_uri_scheme`, so it
arrives at `onNewIntent` exactly as the browser would deliver it. So the
smoke does NOT cover Custom Tab rendering or Chrome's handling of the custom
scheme. Automating a real Custom Tab is the flakiest thing in Android UI
testing and it is not our software; this trade is deliberate.

Two Espresso-Intents facts this relies on, both worth knowing:

- `intending(...)` blocks plain `startActivity` too, not only
  `startActivityForResult`. The interception is in
  `MonitoringInstrumentation.execStartActivity`, which every overload goes
  through; only the RESULT is ignored for `startActivity`.
- The capture is done with a Hamcrest matcher that records what it matches,
  rather than `Intents.getIntents()`, so it does not depend on which
  Espresso version is in the Pin's version catalog.

Traps, all hit for real:

- **The realm's browser flow is IDENTITY-FIRST.** Page 1 is `login-username`
  (field `#username`, submit "Continue"), page 2 is `login` (field
  `#password`, submit "Sign in"). Posting both at once silently redisplays
  page 1 with NO error message, which looks exactly like a wrong password.
  The iOS smoke has the same two screens for the same reason.
- **The login page is a React app** (the Keycloakify `aity` theme). There is
  no server-rendered `<form id="kc-form-login">` to scrape; the POST target
  is `kcContext.url.loginAction`, embedded in the bootstrap script.
- **The app sends `prompt=select_account consent`**
  (`oauth2_openid_prompt`). Checked against the staging realm: it adds no
  consent step, the flow stays two pages.
- **Three of upstream's own instrumented tests do not compile** at this Pin,
  which blocks the whole `androidTest` source set. Patch 0002 excludes them;
  the details and the Bump duty are in PATCHES.md.
- **`git remote -v` inside a container** returns nothing when the checkout is
  owned by another uid, and upstream's `getGitOriginRemote()` then calls
  `.replace()` on null: "Cannot invoke method replace() on null object" at
  `owncloudApp/build.gradle` evaluation. `git config --global --add
  safe.directory '*'` fixes it. Harmless in CI, where the runner owns the
  checkout, but it stops a local reproduction dead.
- **`yes | sdkmanager` kills the script under `set -o pipefail`.** sdkmanager
  closes stdin, `yes` dies of SIGPIPE (141), and pipefail makes that the
  pipeline's status. `emulator-smoke.sh` turns pipefail off for that one
  line. The symptom is the script exiting 0 right after printing the
  emulator line, having done nothing.
- **POST_NOTIFICATIONS is requested when the file list first opens** (API 33+
  and the Pin targets 36). The test pre-grants it through `UiAutomation` and
  still dismisses a permission dialog if one appears, because a system
  dialog in the middle of the journey swallows every later tap.
- **The emulator must not restore a snapshot** (`-no-snapshot`), and the app
  is uninstalled and reinstalled between repeat runs: the account a previous
  run created survives otherwise, and a run that starts already logged in is
  not the test anybody wrote.

### A folder created in the app cannot be removed, renamed or moved

Measured on staging with the app's own UI, both ways round:

- The seeded `.txt`, which came FROM the server: its three-dot menu offers
  Remove, the removal goes through, and the server no longer has the file.
  That is the path the smoke uses, and it passes 5 runs out of 5.
- A folder created seconds earlier from the "+" FAB: **no Remove at all** -
  not in the three-dot menu, not after a long press. Long-press selection
  mode offers exactly four things for it: Select all, Select inverse, Copy,
  Set as available offline (the overflow really does contain only those four;
  checked by scrolling it, not by looking at one screenful).

It is not a server permission problem. PROPFIND on the contract user's
personal space returns `permissions=RDNVCKZP` for the space root AND for a
freshly created folder, so `D` (delete), `N` (rename) and `V` (move) are all
granted. `FilterFileMenuOptionsUseCase` gates Remove on
`files.all { it.hasDeletePermission }`, which reads `OCFile.permissions`, so
the app simply has no permissions string for a folder it created locally.
Copy and Set-as-available-offline survive because they are not gated on one.

User-visible consequence: create a folder, change your mind, and you cannot
delete it from the app until the account is re-synced. Upstream's, not ours
(a Patch to a use case is nowhere near the "not shippable without it" bar),
and worth reporting. Re-check on every Bump: if it is fixed, the smoke can
remove the folder it created and this note goes.

Knobs: `AITY_SMOKE_REPEAT` (pass-rate measurement, `measure:emulator-flakiness`
sets 5), `AITY_SMOKE_SKIP_BUILD=true`, `AITY_SMOKE_AVD`, `AITY_SMOKE_API`,
`AITY_SMOKE_ABI`. Without `AITY_CONTRACT_USER` / `AITY_CONTRACT_PASSWORD` the
test skips itself rather than failing, so a workstation without secrets still
gets a useful build.

## Play publishing setup (2026-09-02, org account exists)

The publish jobs and fastlane lanes were already complete; what was missing
was the account-side wiring. State and traps:

- **A binary keystore cannot live in a CI variable verbatim.** GitLab
  variables are text, so `ANDROID_UPLOAD_KEYSTORE` is a FILE-type variable
  holding the BASE64 of the .jks; `scripts/ci-build.sh` decodes it. Pasting
  the raw JKS in would mangle it silently and fail at signing time.
- **Protected variables need protected refs.** The repo had NO protected
  tags, so the `v*-aity-*` release pipelines would never have seen the
  protected variables and the publish jobs would no-op forever with secrets
  "set". `v*` is protected now (create: Maintainers). Check this first on
  every new Factory.
- The upload keystore (PKCS12, alias `upload`, RSA 4096, valid ~30y) is
  backed up ENCRYPTED in `drive/certificates/android/` (see that README;
  passphrase is `MATCH_PASSWORD`). Under Play App Signing it is only the
  upload key: Google holds the app signing key, a lost upload key is a
  reset request, not a lost app.
- The service account JSON (`PLAY_SERVICE_ACCOUNT_JSON`, file-type,
  protected) belongs on the `aity-cloud/drive` GROUP: one publisher
  service account for the whole Play org, granted account-level release
  permissions in Play Console so every future app inherits it. Per-app
  UPLOAD KEYSTORES stay per-Factory (project variables) - a leaked upload
  key then compromises one app, not the estate.
- **First upload**: the app entries (production AND staging package) must
  be created in the Play Console UI - the API cannot create apps. After
  that the publish jobs handle even the first build: the deploy lane
  defaults `release_status: draft`, which is exactly what the API requires
  before an app has been published once.
- **Org accounts skip the 12-tester/14-day rule** (that gate is
  personal-accounts-only). Internal track needs no listing; a PUBLIC
  production listing still needs screenshots (`fastlane/metadata` has only
  `.gitkeep`s), a 1024x500 feature graphic, content rating, data safety
  and the privacy policy URL (we have that one).

## Trademark audit of the shipped artifacts (2026-09-02)

Prompted by the desktop factory shipping a fully branded UI inside a .dmg
still named `owncloud-client-*` (caught 2026-08-30): the audit was run on the
ARTIFACTS of the latest green pipeline (`aity-drive-android-8.zip`), not only
on the sources. Findings, all clean, no fixes needed:

- `dist/` file names: `aity-drive_<ver>_<iid>.apk|.aab` and
  `aity-drive-staging_...` - named by `scripts/ci-build.sh` itself (`cp`),
  not by upstream's output naming, so a Bump cannot silently rename them.
- Install identity: `applicationId` `tech.aity.drive(.staging)`, label
  "Aity Drive (staging)" - `verify_apk` asserts both on every build.
- Settings > Passwords and accounts: `account_type` is
  `tech.aity.drive(.staging)`; the authenticator's label is
  `@string/app_name` and its icon the branded `@mipmap/icon`, so the row
  reads "Aity Drive" with the Aity mark.
- Notification channels: all generic upstream names ("Downloads",
  "Uploads", "File sync", "Music player", ...). Nothing to override.
- Documents provider root (the Files-app sidebar): `COLUMN_TITLE` is
  `app_name`, `COLUMN_ICON` the branded icon (`RootCursor.addRoot`).
- ZIP entry names inside the APK: none contain "owncloud".
- `resources.arsc` still holds ~106 "owncloud" occurrences, all
  unreachable or invisible: translations of the two known strings (wizard
  off retires one, the en logging summary is overridden - the accepted gap
  above), internal resource/style NAMES, and `android.owncloud.com` as the
  value of `kiteworks_redirect_uri_host` - an upstream Kiteworks auth
  default that is dead code with `server_url` locked and `enforce_oidc`
  on. The live `oauth2_redirect_uri_host` resolves to ours; CI asserts it.

## Real-device pass: the checklist (kit prepared 2026-09-02)

The app has never run on a real phone, and the iOS sibling shipped a crash
that passed a 5/5 simulator suite. What ONLY this pass proves: real Chrome
handing the `aitydrive-staging://` redirect back to the app (the smoke stubs
exactly that hop), the artifact as installed rather than the code as built,
real notifications, real backgrounding.

**The APK**: any green `main` pipeline's `build` job,
`dist/staging/aity-drive-staging_<ver>_<iid>.apk`. Current kit:
<https://gitlab.com/aity-cloud/drive/android/-/jobs/16149191685/artifacts/browse/dist/staging/>
(expires ~2026-09-26; a newer green build job works identically). Until
`ANDROID_UPLOAD_KEYSTORE` exists these are signed with a THROWAWAY per-job
debug keystore, so an upgrade over a previously sideloaded copy fails with a
signature mismatch - uninstall the old copy first.

**The account**: `drive-contract@aity.works` (password: group CI variable
`AITY_CONTRACT_PASSWORD`), or any staging account.

1. `adb install` the APK (or copy it over and accept the unknown-source
   prompt). The launcher shows "Aity Drive (staging)" with the Aity icon.
2. Launch: splash, then the login screen with NO server URL field (the
   server is preset to drive.aity.works).
3. Sign in: a real Chrome Custom Tab opens on auth.aity.works. Two pages:
   email then "Continue", password then "Sign in". Page 1 silently
   redisplaying means a wrong email, not a bug.
4. The personal space file list loads after the redirect. Allow the
   notification permission prompt when it appears.
5. Settings > Passwords and accounts: the account sits under "Aity Drive
   (staging)" with the branded icon; no "ownCloud" anywhere on the screen.
6. Create a folder with "+". EXPECTED (upstream #4673, see above): the new
   folder offers no Remove/Rename/Move until the list refreshes.
   Pull-to-refresh, then Remove appears and works. Do not file it.
7. Upload a photo from the phone. It appears in the list AND in the web UI
   at <https://drive.aity.works>.
8. Background sync: start an upload of something larger, background the app
   immediately; the "Uploads" notification shows progress and the file
   lands complete on the server (check the web UI).
9. Other direction: add a file from the web UI, pull-to-refresh in the
   app, open it (preview must render).
10. Leave nothing behind (staging hygiene): delete everything the pass
    created, remove the account, uninstall.
