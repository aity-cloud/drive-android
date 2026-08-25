# Aity Drive for Android - Factory

Produces the Aity Drive Android Client from the upstream ownCloud Android
client: a small Overlay (Branding + one Patch + CI) on top of a pinned
upstream release. Never a fork, never a copy of the upstream tree.
Vocabulary and rules: `drive/meta` (`CONTEXT.md`, `AGENTS.md`,
`specs/aity-drive-v1.md`).

## Layout

```
.gitlab-ci.yml          pipeline + the Pin (UPSTREAM_TAG, renovate-watched)
UPSTREAM.md             what the Pin is, how to Bump
PATCHES.md              patch inventory (currently exactly one)
MAINTAINING.md          traps this Factory has actually hit
overlay/
  common/               branding shared by both Environment builds
  production/           drive.aity.tech identity (tech.aity.drive)
  staging/              drive.aity.works identity (tech.aity.drive.staging)
patches/                *.patch applied after the overlay
scripts/materialize.sh  clone Pin -> overlay common -> overlay <env> -> patches
scripts/gen-icons.sh    regenerate overlay rasters from drive/meta/brand
scripts/ci-build.sh     what the CI build job runs
fastlane/               supply deploy lanes + Play listing metadata skeleton
```

## Working on it

```sh
scripts/materialize.sh staging      # or production
# open build/upstream in Android Studio, build the originalRelease variant
```

The overlay lands in the `original` flavor's source set
(`owncloudApp/src/original/...`), so every value overrides upstream's
`src/main` resources by resource-merge priority - upstream files are never
edited. Only the `original` flavor is branded or built; `mdm` and `qa` stay
upstream.

Both Environment builds install side by side (distinct applicationId,
account type, provider authorities, redirect scheme); the staging launcher
icon carries a generated STG badge.

## Releasing

CI is the only builder and publisher (see `.gitlab-ci.yml`): push to main
proves the build; a `v<upstream>-aity-<n>` tag builds both Environment
builds as artifacts, `publish-staging` puts staging on the Play internal
track, and the manual `promote` job is the only path to the public listing.
Nothing is ever built, signed or uploaded from a workstation.

Not configured yet (M0): the Play service account (publish jobs no-op
loudly), the upload keystore (builds fall back to a debug key and say so),
and the `macos` runner for the emulator smoke. The `imprint`/terms links
stay off until the pages exist.
