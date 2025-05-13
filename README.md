# SkipWeb

SkipWeb provides an embedded WebView for [Skip Lite](https://skip.tools) transpiled Swift.
On iOS it uses a [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)
and on Android it uses an [android.webkit.WebView](https://developer.android.com/develop/ui/views/layout/webapps/webview).

A simple example of using an embedded WebView with a static URL can be seen:

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
It can be configured with a [`WebEngineConfiguration`](https://github.com/skiptools/skip-web/blob/main/Sources/SkipWeb/WebEngine.swift) instance. For example:

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

## Contributing

We welcome contributions to this package in the form of enhancements and bug fixes.

The general flow for contributing to this and any other Skip package is:

1. Fork this repository and enable actions from the "Actions" tab
2. Check out your fork locally
3. When developing alongside a Skip app, add the package to a [shared workspace](https://skip.tools/docs/contributing) to see your changes incorporated in the app
4. Push your changes to your fork and ensure the CI checks all pass in the Actions tab
5. Add your name to the Skip [Contributor Agreement](https://github.com/skiptools/clabot-config)
6. Open a Pull Request from your fork with a description of your changes

## License

This software is licensed under the
[GNU Lesser General Public License v3.0](https://spdx.org/licenses/LGPL-3.0-only.html),
with the following
[linking exception](https://spdx.org/licenses/LGPL-3.0-linking-exception.html)
to clarify that distribution to restricted environments (e.g., app stores)
is permitted:

> This software is licensed under the LGPL3, included below.
> As a special exception to the GNU Lesser General Public License version 3
> ("LGPL3"), the copyright holders of this Library give you permission to
> convey to a third party a Combined Work that links statically or dynamically
> to this Library without providing any Minimal Corresponding Source or
> Minimal Application Code as set out in 4d or providing the installation
> information set out in section 4e, provided that you comply with the other
> provisions of LGPL3 and provided that you meet, for the Application the
> terms and conditions of the license(s) which apply to the Application.
> Except as stated in this special exception, the provisions of LGPL3 will
> continue to comply in full to this Library. If you modify this Library, you
> may apply this exception to your version of this Library, but you are not
> obliged to do so. If you do not wish to do so, delete this exception
> statement from your version. This exception does not (and cannot) modify any
> license terms which apply to the Application, with which you must still
> comply.

