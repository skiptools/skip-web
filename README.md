# SkipWeb

SkipWeb provides an embedded WebView for [Skip](https://skip.tools) projects.
On iOS it uses a [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)
and on Android it uses an [android.webkit.WebView](https://developer.android.com/develop/ui/views/layout/webapps/webview).

A simple example of 

```swift
import Foundation
import SwiftUI
import SkipWeb

struct EmbeddedWebView : View {
    let url: URL

    var body: some View {
        WebView(url: url)
    }
}
```

## Customization

The [`WebView`](https://github.com/skiptools/skip-web/blob/main/Sources/SkipWeb/WebView.swift) is backed by a
[`WebEngine`](https://github.com/skiptools/skip-web/blob/main/Sources/SkipWeb/WebEngine.swift).
It can be configured with a [`WebEngineConfiguration`] instance. For example:

```swift
import Foundation
import SwiftUI
import SkipWeb

struct ConfigurableWebView : View {
    let navigator: WebViewNavigator = WebViewNavigator(initialURL: URL("https://skip.tools")!)
    @ObservedObject var configuration: WebEngineConfiguration
    @Binding var state: WebViewState

    var body: some View {
        WebView(configuration: configuration, navigator: navigator, state: $state)
    }
}

```

## Contribution

Many delegates that are provided by `WKWebView` are not yet implemented in this project,
and so deeper customization may require custom implementation work.
To implement these, you may need to fork the repository and add it to your workspace,
as described in the [Contributing guide](https://skip.tools/docs/contributing/).
Please consider creating a [Pull Request](https://github.com/skiptools/skip-web/pulls)
with features and fixes that you create, as this benefits the entire Skip community.

## Building

This project is a free Swift Package Manager module that uses the
[Skip](https://skip.tools) plugin to transpile Swift into Kotlin.

Building the module requires that Skip be installed using 
[Homebrew](https://brew.sh) with `brew install skiptools/skip/skip`.
This will also install the necessary build prerequisites:
Kotlin, Gradle, and the Android build tools.

## Testing

The module can be tested using the standard `swift test` command
or by running the test target for the macOS destination in Xcode,
which will run the Swift tests as well as the transpiled
Kotlin JUnit tests in the Robolectric Android simulation environment.

Parity testing can be performed with `skip test`,
which will output a table of the test results for both platforms.
