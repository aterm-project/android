Bundled Flutter Web fallback font files from the current Flutter Web SDK map.
The upstream path and family version are preserved so fontFallbackBaseUrl can use this directory directly.
All current fallback WOFF2 entries are bundled for offline, same-origin rendering.
Corresponding font license texts are in licenses/. The Flutter SDK's Roboto fallback subset is kept at its generated v32 URL.
Flutter SDK upgrades must run test/web_build_config_test.dart to detect newly required files.
