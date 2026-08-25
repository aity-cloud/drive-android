# Agent rules - Aity Drive Android Factory

This repo is the Android Factory of the Aity Drive Clients. The canon
lives in `drive/meta` (side by side in the workspace:
`../meta/AGENTS.md`, `CONTEXT.md`, `specs/aity-drive-v1.md`,
`docs/maintenance.md`) - read it first; its rules all apply here.

Factory-specific rules:

- **Overlay only.** Never commit any file of the upstream tree, never edit
  `build/upstream` expecting it to stick (materialize resets it). A change
  that Branding can express goes in `overlay/`; only a change that cannot
  ship otherwise becomes a Patch, with its `PATCHES.md` entry. Zero
  Patches is the target; there is currently exactly one.
- **The overlay overrides, it does not replace.** Branding lives in the
  `original` flavor source set (`owncloudApp/src/original/...`) precisely
  so upstream files stay untouched and Bumps only conflict on the one
  Patch. Do not add overlay files that shadow whole upstream files.
- **Generated rasters are generated.** Everything under `overlay/**/res`
  that is a PNG comes from `scripts/gen-icons.sh` and the brand master in
  `drive/meta/brand/`; regenerate, never hand-edit.
- **The Pin moves only via a Bump** (`UPSTREAM.md`), never casually.
  `UPSTREAM_TAG` in `.gitlab-ci.yml` is its single source of truth.
- **CI publishes, humans promote.** No local builds ever leave the
  machine; tags shaped `v<upstream>-aity-<n>` are the only release path,
  and `promote` is the only path to a public listing.
- **Both Environment builds, always** - a change that works for one
  Environment only is not done.
- **Record every trap you actually hit in `MAINTAINING.md`.**
- AGENTS.md is canonical, CLAUDE.md is a symlink to it. Commit identity
  `raul@aity.ro`. Plain dashes only, never em dashes.
