# Upstream and the Pin

Upstream is [owncloud/android](https://github.com/owncloud/android), the
GPLv2 ownCloud Android client. This Factory never contains a copy of it:
`scripts/materialize.sh` clones the exact Pin into `build/upstream`
(gitignored) and layers the Overlay on top.

## The Pin

The Pin is the `UPSTREAM_TAG` variable in `.gitlab-ci.yml` - the single
source of truth, annotated for Renovate (`datasource=github-tags
depName=owncloud/android`), which files a signal MR when upstream releases.

Current Pin: **v4.8.3** (latest 4.8.x at Factory creation, 2026-08-25).
It already targets **API 36** (`sdkTargetVersion = 36` in the root
`build.gradle`), which satisfies Google Play's target-API requirement for
new apps from 2026-08-31.

## How to Bump

A Renovate MR on `UPSTREAM_TAG` is a signal, not a mergeable change; the
Bump is a human act (full loop: `drive/meta/docs/maintenance.md`):

1. Read upstream's release notes, looking for Branding-key changes in
   `owncloudApp/src/main/res/values/setup.xml` - new keys, renamed keys,
   changed defaults. Those are the only breaking changes this Overlay can
   see, because `overlay/` only OVERRIDES values (flavor source set) and
   never replaces upstream files. Also diff upstream's `defaultConfig`
   (versionCode/versionName lines) - the one Patch carries their upstream
   values as fallbacks and must be regenerated when they move.
2. Move `UPSTREAM_TAG` in `.gitlab-ci.yml`; run
   `scripts/materialize.sh production` - it fails if a Patch no longer
   applies. Rebase or drop Patches per `PATCHES.md`.
3. Materialize both Environments, open the tree in Android Studio once,
   confirm the branded login against `drive.aity.works`.
4. Push to main (pipeline proves the build), then tag
   `v<new upstream>-aity-1`. `<n>` resets to 1 on every Pin move and
   increments for Overlay-only re-releases.
5. Verify the staging build from the internal track, then run `promote`.

## Trademark

"ownCloud" never appears in our group, repo, package, bundle or product
names. Prose about the upstream software (like this file) is fine, and the
GPL notices and copyright lines inside the app are never removed.
