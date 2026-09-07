# Play store listing - the one folder

Everything the Google Play listing needs, per locale (en-US, ro):

- `title.txt`, `short_description.txt`, `full_description.txt` - the texts
- `changelogs/default.txt` - "what's new"
- `images/icon.png` - 512x512, downscaled from the iOS Factory's
  1024 px drive icon (cloud WITH sync arrows - never the plain company
  mark from meta/brand)
- `images/featureGraphic.png` - 1024x500, white drive mark on red-600
- `images/phoneScreenshots/` - 2-8 PNGs, strictly 9:16 or 16:9

Public on purpose: every byte here is public on the store anyway, and
`fastlane android metadata` uploads this folder verbatim once the app is
out of Draft (see meta docs/runbooks/publisher-accounts.md). Until then,
copy-paste from here into the Console.

Rules kept from day one: screenshots come from the staging build with
demo content, never customer data; en-US and ro stay in sync when texts
change.
