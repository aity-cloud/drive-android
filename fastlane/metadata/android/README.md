# Play listing metadata

Skeleton consumed by `fastlane android metadata` (and by `supply` on the
publish jobs once screenshots exist). Before the first real Play push this
still needs, per locale under `images/`:

- `icon.png` - 512x512 listing icon (derive with `scripts/gen-icons.sh`
  sizes from the brand master, not by hand)
- `featureGraphic.png` - 1024x500
- `phoneScreenshots/` - at least 2 real phone screenshots (staging build,
  demo content, no customer data)

Locales: `en-US` and `ro`. Keep both in sync when texts change.
