## Unreleased

  - Add portable content-blocker configuration with iOS rule-list support and Android request/cosmetic blocker hooks
  - Mirror content blockers into popup child engines and install them for caller-supplied `WKWebView` instances
  - Recompile changed iOS content-blocker rule files, prune stale cached rule lists, and expose setup errors on `WebEngine`/`WebEngineConfiguration`
  - Add `WebEngineConfiguration.clearContentBlockerCache()` so apps can explicitly remove persisted iOS compiled rule lists
  - Add shared `whitelistedDomains` content-blocker config that bypasses blocking on matching iOS and Android page domains
  - Make Android redirect detection best-effort for request blocking on runtimes that do not support `WEB_RESOURCE_REQUEST_IS_REDIRECT`

## 0.5.1

Released 2024-09-03

  - Merge pull request #2 from jeffc-dev/main
  - Added support for pull-to-refresh configuration option…
  - Add settings.setAllowContentAccess and settings.setAllowFileAccess

## 0.5.0

Released 2024-08-15


## 0.4.1

Released 2024-07-03


## 0.4.0

Released 2024-05-25

  - Call webView.setBackgroundColor to avoid screen flashing; bump dependency androidx.webkit:webkit:1.11.0

## 0.3.0

Released 2024-04-06

  - Handle external URL load

## 0.2.1

Released 2024-04-06

  - Handle external URL load

## 0.1.4

Released 2024-04-02

  - Refactor names; add UIDelegate
  - History view

## 0.1.3

Released 2024-04-01


## 0.1.2

Released 2024-04-01

  - Fix initializer for WebViewMessage
  - Re-enable some types on macOS due to CI failures
  - Re-enable some types on macOS due to CI failures
  - Disable some types on macOS due to CI failures
  - Support macOS 13 in order to be able to build with CI
  - Add WebBrowserStore and PageInfo data models
  - Refactor WebEngine, WebView, and WebBrowser

## 0.1.1

Released 2024-03-29

  - ci: update workflow actions location
  - ci: use skiptools/actions for shared workflows
  - Disable code to debug workflow failure
  - Disable code to debug workflow failure
  - Re-enable code to debug workflow failure
  - Disable code to debug workflow failure
  - Use ComposeView for AndroidView WebView embedding
  - Add WebEngine async load and test cases
  - Add WebEngine async load and test cases
  - Break SkipWeb into WebEngine, WebView, and BrowserView

## 0.1.0

Released 2024-03-01


## 0.0.3

Released 2023-11-22


## 0.0.2

Released 2023-11-22
