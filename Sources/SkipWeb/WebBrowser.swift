// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation
import SwiftUI

#if !SKIP
#if os(iOS)
import SafariServices
#endif
#endif

#if SKIP
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.app.PendingIntent
import androidx.browser.customtabs.CustomTabsIntent
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
#endif

// MARK: - Cross-Platform Types

/// A custom action that can be performed on a web page.
/// On iOS, this maps to a `UIActivity` in the Safari share sheet.
/// On Android, this maps to a menu item in Chrome Custom Tabs.
public struct WebBrowserAction {
    public let label: String
    public let handler: (URL) -> Void

    public init(label: String, handler: @escaping (URL) -> Void) {
        self.label = label
        self.handler = handler
    }
}

/// Configuration parameters for the embedded browser.
public struct EmbeddedParams {
    /// The tint color for the browser's toolbar/navigation bar.
    /// On iOS, maps to `SFSafariViewController.preferredBarTintColor`.
    /// On Android, maps to Custom Tabs toolbar and navigation bar color.
    public var barTintColor: Color?

    /// The tint color for the browser's control buttons.
    /// On iOS, maps to `SFSafariViewController.preferredControlTintColor`.
    /// On Android, best-effort mapping via secondary toolbar color.
    public var controlTintColor: Color?

    /// Custom actions available on the web page.
    /// On iOS, these appear in the Safari activity/share sheet.
    /// On Android, these appear as menu items in Chrome Custom Tabs (max 5).
    public var customActions: [WebBrowserAction]

    public init(
        barTintColor: Color? = nil,
        controlTintColor: Color? = nil,
        customActions: [WebBrowserAction] = []
    ) {
        self.barTintColor = barTintColor
        self.controlTintColor = controlTintColor
        self.customActions = customActions
    }
}

/// The mode for opening a web page.
public enum WebBrowserMode {
    /// Open the URL in the system's default browser application.
    case launchBrowser
    /// Open the URL in an embedded browser within the app.
    /// On iOS, uses `SFSafariViewController`. On Android, uses Chrome Custom Tabs.
    case embeddedBrowser(params: EmbeddedParams?)
}

// MARK: - View Extension

extension View {
    /// Opens a web page when `isPresented` becomes `true`.
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls when the web page is opened.
    ///   - url: The URL string of the web page to open.
    ///   - mode: How to open the web page — in the system browser or an embedded browser.
    @ViewBuilder public func openWebBrowser(isPresented: Binding<Bool>, url: URL, mode: WebBrowserMode) -> some View {
        switch mode {
        case .launchBrowser:
            #if !SKIP
            self.onChange(of: isPresented.wrappedValue) { oldPresented, newPresented in
                if newPresented {
                    #if os(iOS)
                    UIApplication.shared.open(url)
                    #elseif os(macOS)
                    NSWorkspace.shared.open(url)
                    #endif
                    isPresented.wrappedValue = false
                }
            }
            #else
            let context = LocalContext.current
            return onChange(of: isPresented.wrappedValue) { oldPresented, newPresented in
                if newPresented == true {
                    let uri = url.toAndroidUri()
                    let intent = Intent(Intent.ACTION_VIEW, uri)
                    context.startActivity(intent)
                    isPresented.wrappedValue = false
                }
            }
            #endif

        case .embeddedBrowser(let params):
            #if !SKIP
            #if os(iOS)
            fullScreenCover(isPresented: isPresented) {
                SafariViewWrapper(url: url, isPresented: isPresented, params: params)
                    .ignoresSafeArea()
            }
            #elseif os(macOS)
            // macOS does not have SFSafariViewController; fall back to system browser
            self.onChange(of: isPresented.wrappedValue) { oldPresented, newPresented in
                if newPresented {
                    NSWorkspace.shared.open(url)
                    isPresented.wrappedValue = false
                }
            }
            #endif
            #else
            let context = LocalContext.current
            // Resolve Color to ARGB int in the Composable context (before onChange)
            // SKIP INSERT: var resolvedBarArgb: Int? = null
            // SKIP INSERT: var resolvedControlArgb: Int? = null
            if let params = params {
                if let barColor = params.barTintColor {
                    let composed = barColor.colorImpl()
                    // SKIP INSERT: resolvedBarArgb = android.graphics.Color.argb((composed.alpha * 255).toInt(), (composed.red * 255).toInt(), (composed.green * 255).toInt(), (composed.blue * 255).toInt())
                    _ = composed
                }
                if let controlColor = params.controlTintColor {
                    let composed = controlColor.colorImpl()
                    // SKIP INSERT: resolvedControlArgb = android.graphics.Color.argb((composed.alpha * 255).toInt(), (composed.red * 255).toInt(), (composed.green * 255).toInt(), (composed.blue * 255).toInt())
                    _ = composed
                }
            }
            return onChange(of: isPresented.wrappedValue) { oldPresented, newPresented in
                if newPresented == true {
                    let builder = CustomTabsIntent.Builder()

                    // Apply color customization
                    // SKIP INSERT: if (resolvedBarArgb != null || resolvedControlArgb != null) {
                    // SKIP INSERT:     val colorBuilder = CustomTabColorSchemeParams.Builder()
                    // SKIP INSERT:     resolvedBarArgb?.let { colorBuilder.setToolbarColor(it); colorBuilder.setNavigationBarColor(it) }
                    // SKIP INSERT:     resolvedControlArgb?.let { colorBuilder.setSecondaryToolbarColor(it) }
                    // SKIP INSERT:     builder.setDefaultColorSchemeParams(colorBuilder.build())
                    // SKIP INSERT: }

                    // Add custom menu items
                    if let params = params {
                        if params.customActions.count > 5 {
                            logger.warning("openWebBrowser: Chrome Custom Tabs supports at most 5 menu items; only the first 5 will be shown")
                        }
                        for action in params.customActions {
                            let actionId = java.util.UUID.randomUUID().toString()
                            WebBrowserActionRegistry.register(actionId: actionId, handler: action.handler)

                            let menuIntent = Intent(context, context.asActivity().javaClass)
                            menuIntent.setAction("skip.kit.WEB_PAGE_ACTION")
                            menuIntent.putExtra("actionId", actionId)

                            // SKIP INSERT: val pendingFlags = PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                            let pendingIntent = PendingIntent.getActivity(context, actionId.hashCode(), menuIntent, pendingFlags)
                            builder.addMenuItem(action.label, pendingIntent)
                        }
                    }

                    let customTabsIntent = builder.build()
                    let uri = url.toAndroidUri()
                    customTabsIntent.launchUrl(context.asActivity(), uri)
                    isPresented.wrappedValue = false
                }
            }
            #endif
        }
    }
}

#if SKIP
// https://stackoverflow.com/questions/51640154/android-view-contextthemewrapper-cannot-be-cast-to-android-app-activity/63360115#63360115
extension Context {
    func asActivity() -> android.app.Activity {
        if let activity = self as? android.app.Activity {
            return activity
        } else if let wrapper = self as? android.content.ContextWrapper {
            return wrapper.baseContext.asActivity()
        } else {
            fatalError("could not extract activity from: \(self)")
        }
    }
}
#endif

// MARK: - iOS: SFSafariViewController Wrapper

#if !SKIP
#if os(iOS)
private struct SafariViewWrapper: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool
    let params: EmbeddedParams?

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        let safariVC = SFSafariViewController(url: url, configuration: config)
        safariVC.delegate = context.coordinator

        if let barTint = params?.barTintColor {
            safariVC.preferredBarTintColor = UIColor(barTint)
        }
        if let controlTint = params?.controlTintColor {
            safariVC.preferredControlTintColor = UIColor(controlTint)
        }

        return safariVC
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> SafariCoordinator {
        SafariCoordinator(parent: self)
    }
}

private class SafariCoordinator: NSObject, SFSafariViewControllerDelegate {
    let parent: SafariViewWrapper

    init(parent: SafariViewWrapper) {
        self.parent = parent
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        parent.isPresented = false
    }

    func safariViewController(_ controller: SFSafariViewController, activityItemsFor URL: URL, title: String?) -> [UIActivity] {
        guard let actions = parent.params?.customActions else { return [] }
        return actions.map { action in
            WebBrowserUIActivity(webAction: action, pageURL: URL)
        }
    }
}

private class WebBrowserUIActivity: UIActivity {
    let webAction: WebBrowserAction
    let pageURL: URL

    init(webAction: WebBrowserAction, pageURL: URL) {
        self.webAction = webAction
        self.pageURL = pageURL
        super.init()
    }

    override var activityTitle: String? { webAction.label }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("skip.web.browseraction.\(webAction.label)")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        webAction.handler(pageURL)
        activityDidFinish(true)
    }
}
#endif
#endif

// MARK: - Android: Custom Tabs Action Registry

#if SKIP
/// Registry for custom action handlers used with Chrome Custom Tabs menu items.
/// When the user taps a menu item, Chrome fires a PendingIntent back to the activity.
/// The onNewIntent listener dispatches to the registered handler.
class WebBrowserActionRegistry {
    private static var handlers: [String: (URL) -> Void] = [:]
    private static var isListenerRegistered = false

    static func register(actionId: String, handler: @escaping (URL) -> Void) {
        handlers[actionId] = handler
        ensureListenerRegistered()
    }

    @discardableResult
    static func handleIntent(_ intent: Intent) -> Bool {
        guard intent.action == "skip.kit.WEB_PAGE_ACTION" else { return false }
        guard let actionId = intent.getStringExtra("actionId") else { return false }
        guard let handler = handlers.removeValue(forKey: actionId) else { return false }

        if let dataString = intent.dataString, let url = URL(string: dataString) {
            handler(url)
        }
        return true
    }

    private static func ensureListenerRegistered() {
        if isListenerRegistered { return }
        guard let activity = UIApplication.shared.androidActivity else { return }
        isListenerRegistered = true
        activity.addOnNewIntentListener(WebBrowserActionIntentListener())
    }
}

private struct WebBrowserActionIntentListener : androidx.core.util.Consumer<Intent> {
    override func accept(value: Intent) {
        WebBrowserActionRegistry.handleIntent(value)
    }
}
#endif

#endif // !SKIP_BRIDGE
