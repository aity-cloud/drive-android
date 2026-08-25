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
