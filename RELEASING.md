# Releasing Aity Drive for Android

The operating manual for shipping this app: how updates flow, how testers
install, how production goes live. The account-side story (service
account, permissions, the 403 saga) lives in
`../meta/docs/runbooks/publisher-accounts.md`; day-to-day traps live in
`MAINTAINING.md`. Everything here was exercised for real on 2026-09-07.

## The map

Two Play apps, permanently:

| | package | Play tracks used | public? |
|---|---|---|---|
| Production build | `tech.aity.drive` | internal, closed (alpha), production | production track only, when promoted |
| Staging build | `tech.aity.drive.staging` | internal, closed (alpha) | **NEVER** |

**The staging app stays in closed testing forever.** It exists so the
staging Environment build is installable through Play with Google's
signature, nothing more. It never gets a production release, a public
listing, or a store presence. Do not "finish" its setup beyond what
closed testing requires; there is nothing to finish.

CI builds and uploads; humans promote. No artifact ever reaches Play
from a workstation.

## Shipping an update (the whole loop)

1. Change lands on `main` (a Pin Bump via `UPSTREAM.md`, a Branding
   change, a CI fix). The main pipeline must be green.
2. Tag it: `git tag v<upstream>-aity-<n> && git push origin <tag>`.
   The tag's upstream part must equal the Pin (`UPSTREAM_TAG`), or the
   build refuses. versionCode = CI_PIPELINE_IID, versionName = the tag.
3. The tag pipeline builds BOTH environment builds, signed with the real
   upload keystore, verifies the branded identity inside the APKs, and
   parks everything under `dist/` as artifacts.
4. Press **publish-staging** (manual job on the tag pipeline). fastlane
   uploads the staging AAB to the STAGING app's internal track. This is
   the automated path; it needs no Console.
5. Verify: install/update via Play on a phone (below), run the device
   checklist in `MAINTAINING.md` when the change warrants it.
6. Press **promote** (manual job, the one human act). It uploads the
   production AAB to the PRODUCTION app's production track as a DRAFT
   release. Nothing is public yet.
7. Roll out in Play Console: the production app > Production > the draft
   release > review > start rollout. Google reviews it; staged rollout
   percentages are available there. This click is deliberately outside
   CI.

Security releases: promote within 3 business days (binding target,
`../meta/docs/maintenance.md`).

## Installing as a tester

One-time, per person, per app:

1. Your Google account email must be on the tester list: Play Console >
   the app > Testing > Internal testing (or Closed testing) > Testers.
2. Open the opt-in link IN A BROWSER while signed in as that account,
   and press "Become a tester":
   - production app: https://play.google.com/apps/testing/tech.aity.drive
   - staging app: https://play.google.com/apps/testing/tech.aity.drive.staging
   (These are the closed-testing links; the internal-testing links are
   random per app and visible in the Console on the Testers tab.)
3. Follow the "download it on Google Play" link from that page and
   install.

From then on updates arrive like any Play update, automatically. The
Play build is re-signed by Google (Play App Signing) - it IS the shipped
artifact, which is exactly what testing wants. "(Unreviewed)" in the app
name on internal testing is normal.

If the link says "not available": wrong Google account in the Play Store
app (check the avatar menu), email not on THAT app's list, or the first
rollout is still baking (give it a few hours once).

## When something is wrong

- API refused / 403: `drive/certificates/android/check-play-access.sh`
  (needs MATCH_PASSWORD). Permission recipe and traps: the runbook.
- Lost CI variables: `drive/certificates/android/set-ci-variables.sh`
  restores the keystore set from the repo alone.
- A publish job no-ops loudly when `PLAY_SERVICE_ACCOUNT_JSON` is
  missing - that is a variables problem, not a Play problem.
