# Findings

## App (9.16.1, build 1731)
- Xcode 16.1 / iOS 18.1 SDK, MinimumOSVersion 15.0, arm64, decrypted via TrollDecrypt.
- Uses TrustKit (cert pinning) for native API calls.
- `UrlMapping.json`: tabs VERFOLGEN and FINDEN (Standorte) are WebView widgets,
  loaded through `WebContainerController` (`/int-static/pdapp/spa/SPA.html`, `window._platformProperties`).
- Remote config: https://www.dhl.de/int-static/pdapp/config/remoteconfig.json (no iOS-15 cut-off in it).

## Symptom on SE (iOS 15.8.8)
- Verfolgen (home) and Standorte: "Bereich wird geladen ... dauert etwas länger" forever.
- Packstation, Frankieren, Einstellungen (native): work.
- Syslog: all native HTTP requests succeed (200/304); no network errors.
- Hypothesis: the web content DHL now serves for these tabs uses JS/CSS that iOS 15 WebKit
  cannot run, so the page never signals "ready" to the native fallback timer.
- A newer app build would load the same web content in the same system WebKit,
  so patching MinimumOSVersion of 11.0 would most likely not fix these tabs.
