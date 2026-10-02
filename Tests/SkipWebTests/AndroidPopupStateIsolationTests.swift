// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import SkipWeb

#if SKIP
/// Exercises popup transport and its installed listeners without network or popup timing.
// SKIP INSERT: @org.junit.runner.RunWith(androidx.test.ext.junit.runners.AndroidJUnit4::class)
final class AndroidPopupStateIsolationTests: XCTestCase {
    /* SKIP INSERT:
    @get:org.junit.Rule
    val composeRule = androidx.compose.ui.test.junit4.createComposeRule()

    @Test
    fun testBlankPopupNavigationDoesNotOverwriteParentStateOrNotifyParent() {
        composeRule.runOnIdle {
            val popup = PopupFixture()
            try {
                val client = popup.childView.webViewClient
                client.onPageStarted(popup.childView, "about:blank", null)
                client.onPageCommitVisible(popup.childView, "about:blank")
                client.onPageFinished(popup.childView, "about:blank")
                popup.assertParentUnchanged()
                org.junit.Assert.assertEquals(emptyList<String>(), popup.parentEvents)
                org.junit.Assert.assertEquals(listOf("started", "committed", "finished"), popup.childEvents)
            } finally {
                popup.close()
            }
        }
    }

    @Test
    fun testPopupDownloadIsForwardedWithoutChangingParentLoadingState() {
        composeRule.runOnIdle {
            val popup = PopupFixture()
            try {
                popup.childView.recordedDownloadListener!!.onDownloadStart(
                    "https://example.test/movie.mp4", "test-agent", "", "video/mp4", 123L
                )
                org.junit.Assert.assertEquals(1, popup.downloads.size)
                org.junit.Assert.assertEquals("https://example.test/movie.mp4", popup.downloads.single().url!!.absoluteString)
                popup.assertParentUnchanged()
                org.junit.Assert.assertEquals(emptyList<String>(), popup.parentEvents)
            } finally {
                popup.close()
            }
        }
    }

    @Test
    fun testMountedPopupUpdatesItsOwnStateAndCallbacks() {
        val popup = composeRule.runOnIdle { PopupFixture() }
        val childState = WebViewState()
        val mountedEvents = mutableListOf<String>()
        val visible = androidx.compose.runtime.mutableStateOf(true)
        val navigator = composeRule.runOnIdle {
            WebViewNavigator().also { it.webEngine = popup.childEngine }
        }
        try {
            composeRule.setContent {
                if (visible.value) {
                    WebView(
                        navigator = navigator,
                        state = skip.ui.Binding.constant(childState),
                        onNavigationCommitted = { mountedEvents.add("committed") },
                        onNavigationFinished = { mountedEvents.add("finished") }
                    ).Compose()
                }
            }
            composeRule.runOnIdle {
                org.junit.Assert.assertTrue(popup.childView.isAttachedToWindow)
                mountedEvents.clear()
                popup.childView.documentURL = "https://example.test/allowed-popup"
                popup.childView.documentTitle = "Allowed popup"
                val client = popup.childView.webViewClient
                client.onPageStarted(popup.childView, popup.childView.documentURL, null)
                client.onPageFinished(popup.childView, popup.childView.documentURL)
                org.junit.Assert.assertEquals(popup.childView.documentURL, childState.url!!.absoluteString)
                org.junit.Assert.assertEquals("Allowed popup", childState.pageTitle)
                org.junit.Assert.assertEquals(listOf("committed", "finished"), mountedEvents)
                popup.assertParentUnchanged()
                org.junit.Assert.assertEquals(emptyList<String>(), popup.parentEvents)
            }
        } finally {
            composeRule.runOnIdle { visible.value = false }
            composeRule.runOnIdle { popup.close() }
        }
    }

    @Test
    fun testPopupPreservesNavigationPolicyForwarding() {
        composeRule.runOnIdle {
            val popup = PopupFixture()
            try {
                val client = popup.childView.webViewClient
                org.junit.Assert.assertTrue(client.shouldOverrideUrlLoading(popup.childView, Request("https://example.test/blocked")))
                org.junit.Assert.assertFalse(client.shouldOverrideUrlLoading(popup.childView, Request("https://example.test/allowed")))
                org.junit.Assert.assertEquals(listOf("https://example.test/blocked", "https://example.test/allowed"), popup.policyURLs)
                popup.assertParentUnchanged()
            } finally {
                popup.close()
            }
        }
    }

    private class Request(private val address: String): android.webkit.WebResourceRequest {
        override fun getUrl() = android.net.Uri.parse(address)
        override fun isForMainFrame() = true
        override fun isRedirect() = false
        override fun hasGesture() = true
        override fun getMethod() = "GET"
        override fun getRequestHeaders() = emptyMap<String, String>()
    }

    private class PopupPlatformView(context: android.content.Context): android.webkit.WebView(context) {
        var documentURL = "about:blank"
        var documentTitle = "about:blank"
        var recordedDownloadListener: android.webkit.DownloadListener? = null
        override fun getUrl() = documentURL
        override fun getTitle() = documentTitle
        override fun setDownloadListener(listener: android.webkit.DownloadListener?) {
            recordedDownloadListener = listener
            super.setDownloadListener(listener)
        }
    }

    private class PopupFixture {
        val parentState = WebViewState()
        val parentEvents = mutableListOf<String>()
        val childEvents = mutableListOf<String>()
        val downloads = mutableListOf<WebDownloadRequest>()
        val policyURLs = mutableListOf<String>()
        val parentURL = skip.foundation.URL(string = "https://example.test/article")
        val parentEngine = WebEngine()
        val childView = PopupPlatformView(parentEngine.webView.context)
        val childDelegate = object: SkipWebNavigationDelegate {
            override fun webEngineDidStartProvisionalNavigation(engine: WebEngine) { childEvents.add("started") }
            override fun webEngineDidCommitNavigation(engine: WebEngine) { childEvents.add("committed") }
            override fun webEngineDidFinishNavigation(engine: WebEngine) { childEvents.add("finished") }
        }
        val childEngine = WebEngine(configuration = WebEngineConfiguration(navigationDelegate = childDelegate), webView = childView)
        val owner: WebView

        init {
            parentState.url = parentURL
            parentState.pageTitle = "Parent article"
            parentState.canGoBack = true
            parentState.canGoForward = true
            parentState.isLoading = true
            parentState.isProvisionallyNavigating = true
            parentState.estimatedProgress = 0.5
            parentEngine.configuration.androidCreateWindowHandler = { _, _, _ -> childEngine }
            owner = WebView(
                configuration = parentEngine.configuration,
                state = skip.ui.Binding.constant(parentState),
                onNavigationCommitted = { parentEvents.add("committed") },
                onNavigationFinished = { parentEvents.add("finished") },
                onNavigationFailed = { parentEvents.add("failed") },
                onDownloadRequested = { downloads.add(it) },
                shouldOverrideUrlLoading = { url, _ ->
                    policyURLs.add(url.absoluteString)
                    url.absoluteString.endsWith("/blocked")
                }
            )
            val chrome = SkipWebChromeClient(webView = owner, webEngine = parentEngine)
            val transport = parentEngine.webView.WebViewTransport()
            val message = android.os.Message.obtain(android.os.Handler(android.os.Looper.getMainLooper()))
            message.obj = transport
            org.junit.Assert.assertTrue(chrome.onCreateWindow(parentEngine.webView, false, true, message))
            org.junit.Assert.assertSame(childView, transport.webView)
        }

        fun assertParentUnchanged() {
            org.junit.Assert.assertEquals(parentURL, parentState.url)
            org.junit.Assert.assertEquals("Parent article", parentState.pageTitle)
            org.junit.Assert.assertTrue(parentState.canGoBack)
            org.junit.Assert.assertTrue(parentState.canGoForward)
            org.junit.Assert.assertTrue(parentState.isLoading)
            org.junit.Assert.assertTrue(parentState.isProvisionallyNavigating)
            org.junit.Assert.assertEquals(0.5, parentState.estimatedProgress!!, 0.0)
        }

        fun close() {
            childView.destroy()
            parentEngine.webView.destroy()
        }
    }
    */
}
#endif
