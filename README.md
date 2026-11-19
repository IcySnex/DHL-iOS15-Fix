# DHLHomeFix

Tweak (plain dylib, no Theos) for the Post & DHL app on an iPhone SE 1st gen (iOS 15, arm64),
injected with TrollFools. Goal: the home screen loads forever on iOS 15 – find out why and fix it.

## Layout

- `dump/` – decrypted IPA and extracted app (not committed)
- `captures/` – mitmproxy flows and syslogs (not committed)
- `notes/` – findings
- `src/` – tweak source

## Build

Plain `xcrun clang`, arm64 only, `-miphoneos-version-min=15.0`. TrollFools signs the dylib on injection.
