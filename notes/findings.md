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

## Root cause (confirmed 2026-11-19)
- Verfolgen: `ver9-SPA-VERFOLGEN.html` -> `verfolgen.js` -> `import()` of `/int-verfolgen/static/spa/main.<hash>.js`;
  chunk `ShipmentArticle.*.js` (and `LiveTrackingMap.*.js`) use ES2022 class static blocks.
- Standorte: `postfinder.js` -> `import('/int-postfinder/webservice/spa/js/standortfinder.js')` -> `main.<hash>.js` (22 static blocks).
- JSC before Safari 16.4 rejects `static { }` -> "SyntaxError: Unexpected token '{'" -> module graph fails -> endless spinner.
- PoomSmart Polyfills (installed) lowers static blocks only for classic `<script>` (re-fetch + eval on error).
  ES modules from `import()` cannot be re-evaluated that way, so it does not cover this case.

## Fix (works on device)
- SPA HTML fetched natively, dhl.de `<script src>` rewritten to `dhlfix://`, shown via `loadSimulatedRequest`.
- `dhlfix://` WKURLSchemeHandler fetches https original and lowers static blocks (18–58 ms per bundle on the SE).
- `_registerURLSchemeAsSecure:` / `_registerURLSchemeAsBypassingContentSecurityPolicy:` are available on iOS 15.
- Open: one rejection "Right side of assignment cannot be destructured" in ShipmentArticle (page still works).
