// Copyright 2024–2026 Skip
import XCTest
@testable import SkipWeb

#if SKIP
/// Covers the `<input type="file">` support on Android: result parsing, the handler hook, and the rule
/// that every `onShowFileChooser` callback is resolved exactly once.
///
/// The Kotlin below lives in a Swift block comment, and Swift block comments nest, so wildcard
/// MIME types are built from `star` instead of being written as literals.
// SKIP INSERT: @org.junit.runner.RunWith(androidx.test.ext.junit.runners.AndroidJUnit4::class)
final class AndroidFileChooserTests: XCTestCase {
    /* SKIP INSERT:
    @get:org.junit.Rule
    val composeRule = androidx.compose.ui.test.junit4.createComposeRule()

    private val star = "*"

    private val appContext: android.content.Context
        get() = androidx.test.core.app.ApplicationProvider.getApplicationContext()

    private val ownAuthority = "dev.test.ownapp.fileprovider"

    private fun registerOwnProvider() {
        val info = android.content.pm.ProviderInfo()
        info.authority = ownAuthority
        info.packageName = appContext.packageName
        info.name = "androidx.core.content.FileProvider"
        info.applicationInfo = appContext.applicationInfo
        org.robolectric.Shadows.shadowOf(appContext.packageManager).addOrUpdateProvider(info)
    }

    private fun clipResult(vararg items: android.content.ClipData.Item): android.content.Intent {
        val clip = android.content.ClipData("files", kotlin.arrayOf("application/octet-stream"), items[0])
        for (i in 1 until items.size) { clip.addItem(items[i]) }
        val intent = android.content.Intent()
        intent.clipData = clip
        return intent
    }

    private fun uriItem(value: String): android.content.ClipData.Item = android.content.ClipData.Item(android.net.Uri.parse(value))

    private fun parse(data: android.content.Intent?): kotlin.Array<android.net.Uri>? =
        WebEngine.parseFileChooserResult(android.app.Activity.RESULT_OK, data, appContext)

    @Test
    fun testCancelledResultParsesToNull() {
        val data = android.content.Intent().setData(android.net.Uri.parse("content://test/1"))
        org.junit.Assert.assertNull(WebEngine.parseFileChooserResult(android.app.Activity.RESULT_CANCELED, data, appContext))
        org.junit.Assert.assertNull(parse(null))
        org.junit.Assert.assertNull(parse(android.content.Intent()))
    }

    @Test
    fun testSingleResultUsesData() {
        val uri = android.net.Uri.parse("content://test/1")
        val result = parse(android.content.Intent().setData(uri))
        org.junit.Assert.assertEquals(listOf(uri), result!!.toList())
    }

    @Test
    fun testMultipleResultUsesClipData() {
        val first = android.net.Uri.parse("content://test/1")
        val second = android.net.Uri.parse("content://test/2")
        val result = parse(clipResult(android.content.ClipData.Item(first), android.content.ClipData.Item(second)))
        org.junit.Assert.assertEquals(listOf(first, second), result!!.toList())
    }

    @Test
    fun testFileAndOtherSchemesAreDropped() {
        org.junit.Assert.assertNull(parse(android.content.Intent().setData(android.net.Uri.parse("file:///data/data/x/shared_prefs/a.xml"))))
        org.junit.Assert.assertNull(parse(android.content.Intent().setData(android.net.Uri.parse("http://example.com/a.txt"))))
    }

    @Test
    fun testUrisFromTheAppsOwnProvidersAreDropped() {
        registerOwnProvider()
        val other = android.net.Uri.parse("content://test/2")
        val result = parse(clipResult(
            uriItem("content://" + ownAuthority + "/files/secret.db"),
            android.content.ClipData.Item(other),
            uriItem("content://0@" + ownAuthority + "/files/secret.db")
        ))
        org.junit.Assert.assertEquals(listOf(other), result!!.toList())
        org.junit.Assert.assertNull(parse(android.content.Intent().setData(android.net.Uri.parse("content://" + ownAuthority + "/files/secret.db"))))
    }

    @Test
    fun testClipItemsWithoutAUriAreDropped() {
        val kept = android.net.Uri.parse("content://test/2")
        val result = parse(clipResult(android.content.ClipData.Item("just text"), android.content.ClipData.Item(kept)))
        org.junit.Assert.assertEquals(listOf(kept), result!!.toList())
        org.junit.Assert.assertNull(parse(clipResult(android.content.ClipData.Item("just text"))))
    }

    @Test
    fun testPopupChildConfigurationMirrorsFileChooserHandler() {
        val config = WebEngineConfiguration()
        org.junit.Assert.assertNull(config.popupChildMirroredConfiguration().androidFileChooserHandler)
        config.androidFileChooserHandler = { _, _, _ -> true }
        org.junit.Assert.assertNotNull(config.popupChildMirroredConfiguration().androidFileChooserHandler)
    }

    @Test
    fun testCancelResolvesPendingCallbackExactlyOnce() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            val received = mutableListOf<kotlin.Array<android.net.Uri>?>()
            composeRule.runOnIdle {
                engine.pendingFileChooserCallback = android.webkit.ValueCallback<kotlin.Array<android.net.Uri>> { received.add(it) }
                engine.cancelPendingFileChooser()
                engine.cancelPendingFileChooser()
                org.junit.Assert.assertEquals(1, received.size)
                org.junit.Assert.assertNull(received[0])
                org.junit.Assert.assertNull(engine.pendingFileChooserCallback)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testResultResolvesCallbackAndStaleResultIsIgnored() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            val uri = android.net.Uri.parse("content://test/1")
            val received = mutableListOf<kotlin.Array<android.net.Uri>?>()
            composeRule.runOnIdle {
                engine.pendingFileChooserCallback = android.webkit.ValueCallback<kotlin.Array<android.net.Uri>> { received.add(it) }
                engine.completeAndroidFileChooser(android.app.Activity.RESULT_OK, android.content.Intent().setData(uri))
                engine.completeAndroidFileChooser(android.app.Activity.RESULT_OK, android.content.Intent().setData(uri))
                org.junit.Assert.assertEquals(1, received.size)
                org.junit.Assert.assertEquals(listOf(uri), received[0]!!.toList())
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testDeclinesWithoutLauncherAndLeavesCallbackUntouched() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            val received = mutableListOf<kotlin.Array<android.net.Uri>?>()
            val params = object : android.webkit.WebChromeClient.FileChooserParams() {
                override fun getMode(): Int = android.webkit.WebChromeClient.FileChooserParams.MODE_OPEN
                override fun getAcceptTypes(): kotlin.Array<String> = kotlin.arrayOf("image/$star")
                override fun isCaptureEnabled(): Boolean = false
                override fun getTitle(): CharSequence? = null
                override fun getFilenameHint(): String? = null
                override fun createIntent(): android.content.Intent = android.content.Intent()
            }
            composeRule.runOnIdle {
                val callback = android.webkit.ValueCallback<kotlin.Array<android.net.Uri>> { received.add(it) }
                org.junit.Assert.assertFalse(engine.presentAndroidFileChooser(callback, params))
                org.junit.Assert.assertTrue(received.isEmpty())
                org.junit.Assert.assertNull(engine.pendingFileChooserCallback)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    private class FakeLauncher : androidx.activity.result.ActivityResultLauncher<android.content.Intent>() {
        var launched = 0
        var failOnLaunch = false
        override fun launch(input: android.content.Intent, options: androidx.core.app.ActivityOptionsCompat?) {
            launched += 1
            if (failOnLaunch) { throw android.content.ActivityNotFoundException("no picker") }
        }
        override fun unregister() {}
        override val contract: androidx.activity.result.contract.ActivityResultContract<android.content.Intent, *>
            get() = androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    }

    private class Recorder {
        val values = mutableListOf<kotlin.Array<android.net.Uri>?>()
        val callback = android.webkit.ValueCallback<kotlin.Array<android.net.Uri>> { values.add(it) }
    }

    private fun fakeParams(): android.webkit.WebChromeClient.FileChooserParams = object : android.webkit.WebChromeClient.FileChooserParams() {
        override fun getMode(): Int = android.webkit.WebChromeClient.FileChooserParams.MODE_OPEN
        override fun getAcceptTypes(): kotlin.Array<String> = kotlin.arrayOf()
        override fun isCaptureEnabled(): Boolean = false
        override fun getTitle(): CharSequence? = null
        override fun getFilenameHint(): String? = null
        override fun createIntent(): android.content.Intent = android.content.Intent()
    }

    @Test
    fun testSecondRequestFromTheSameLauncherIsDeclinedWhileTheFirstPickerIsOpen() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            composeRule.runOnIdle {
                val launcher = FakeLauncher()
                engine.androidFileChooserLauncher = launcher
                val first = Recorder()
                val second = Recorder()
                org.junit.Assert.assertTrue(engine.presentAndroidFileChooser(first.callback, fakeParams()))
                org.junit.Assert.assertTrue(engine.presentAndroidFileChooser(second.callback, fakeParams()))
                org.junit.Assert.assertEquals(1, launcher.launched)
                org.junit.Assert.assertTrue(first.values.isEmpty())
                org.junit.Assert.assertEquals(1, second.values.size)
                org.junit.Assert.assertNull(second.values[0])
                val uri = android.net.Uri.parse("content://test/1")
                engine.completeAndroidFileChooser(android.app.Activity.RESULT_OK, android.content.Intent().setData(uri), launcher)
                org.junit.Assert.assertEquals(listOf(uri), first.values.single()!!.toList())
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testRequestOwnedByAGoneLauncherIsSupersededByANewOne() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            composeRule.runOnIdle {
                val goneLauncher = FakeLauncher()
                val newLauncher = FakeLauncher()
                val first = Recorder()
                val second = Recorder()
                engine.androidFileChooserLauncher = goneLauncher
                engine.presentAndroidFileChooser(first.callback, fakeParams())
                engine.androidFileChooserLauncher = newLauncher
                org.junit.Assert.assertTrue(engine.presentAndroidFileChooser(second.callback, fakeParams()))
                org.junit.Assert.assertEquals(1, first.values.size)
                org.junit.Assert.assertNull(first.values[0])
                org.junit.Assert.assertEquals(1, newLauncher.launched)
                org.junit.Assert.assertTrue(second.values.isEmpty())
                org.junit.Assert.assertTrue(engine.pendingFileChooserOwner === newLauncher)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testResultFromAnotherLauncherIsIgnored() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            composeRule.runOnIdle {
                val owner = FakeLauncher()
                val other = FakeLauncher()
                val recorder = Recorder()
                engine.androidFileChooserLauncher = owner
                engine.presentAndroidFileChooser(recorder.callback, fakeParams())
                val uri = android.net.Uri.parse("content://test/1")
                engine.completeAndroidFileChooser(android.app.Activity.RESULT_OK, android.content.Intent().setData(uri), other)
                org.junit.Assert.assertTrue(recorder.values.isEmpty())
                org.junit.Assert.assertNotNull(engine.pendingFileChooserCallback)
                engine.completeAndroidFileChooser(android.app.Activity.RESULT_OK, android.content.Intent().setData(uri), owner)
                org.junit.Assert.assertEquals(listOf(uri), recorder.values.single()!!.toList())
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testLeavingTheScreenCancelsTheRequestItsOwnLauncherStarted() {
        val navigator = composeRule.runOnIdle { WebViewNavigator() }
        val visible = androidx.compose.runtime.mutableStateOf(true)
        composeRule.setContent {
            if (visible.value) {
                WebView(navigator = navigator, state = skip.ui.Binding.constant(WebViewState())).Compose()
            }
        }
        val engine = composeRule.runOnIdle { navigator.webEngine!! }
        val recorder = Recorder()
        try {
            composeRule.runOnIdle {
                org.junit.Assert.assertNotNull(engine.androidFileChooserLauncher)
                engine.pendingFileChooserCallback = recorder.callback
                engine.pendingFileChooserOwner = engine.androidFileChooserLauncher
            }
            composeRule.runOnIdle { visible.value = false }
            composeRule.runOnIdle {
                org.junit.Assert.assertEquals(1, recorder.values.size)
                org.junit.Assert.assertNull(recorder.values[0])
                org.junit.Assert.assertNull(engine.androidFileChooserLauncher)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testLeavingTheScreenKeepsARequestAnotherLauncherStarted() {
        val navigator = composeRule.runOnIdle { WebViewNavigator() }
        val visible = androidx.compose.runtime.mutableStateOf(true)
        composeRule.setContent {
            if (visible.value) {
                WebView(navigator = navigator, state = skip.ui.Binding.constant(WebViewState())).Compose()
            }
        }
        val engine = composeRule.runOnIdle { navigator.webEngine!! }
        val recorder = Recorder()
        val otherCompositionsLauncher = FakeLauncher()
        try {
            composeRule.runOnIdle {
                engine.pendingFileChooserCallback = recorder.callback
                engine.pendingFileChooserOwner = otherCompositionsLauncher
            }
            composeRule.runOnIdle { visible.value = false }
            composeRule.runOnIdle {
                org.junit.Assert.assertTrue(recorder.values.isEmpty())
                org.junit.Assert.assertNotNull(engine.pendingFileChooserCallback)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testWebViewComposesWithoutAnActivityResultRegistryOwner() {
        val navigator = composeRule.runOnIdle { WebViewNavigator() }
        val applicationContext = appContext.applicationContext
        composeRule.setContent {
            androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalContext provides applicationContext) {
                WebView(navigator = navigator, state = skip.ui.Binding.constant(WebViewState())).Compose()
            }
        }
        val engine = composeRule.runOnIdle { navigator.webEngine!! }
        try {
            composeRule.runOnIdle {
                org.junit.Assert.assertNull(engine.androidFileChooserLauncher)
                val recorder = Recorder()
                org.junit.Assert.assertFalse(engine.presentAndroidFileChooser(recorder.callback, fakeParams()))
                org.junit.Assert.assertTrue(recorder.values.isEmpty())
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    private fun throwingParams(): android.webkit.WebChromeClient.FileChooserParams = object : android.webkit.WebChromeClient.FileChooserParams() {
        override fun getMode(): Int = android.webkit.WebChromeClient.FileChooserParams.MODE_OPEN
        override fun getAcceptTypes(): kotlin.Array<String> = kotlin.arrayOf()
        override fun isCaptureEnabled(): Boolean = false
        override fun getTitle(): CharSequence? = null
        override fun getFilenameHint(): String? = null
        override fun createIntent(): android.content.Intent = throw IllegalStateException("no intent")
    }

    private fun mountWebView(config: WebEngineConfiguration): WebViewNavigator {
        val navigator = composeRule.runOnIdle { WebViewNavigator() }
        composeRule.setContent {
            WebView(configuration = config, navigator = navigator, state = skip.ui.Binding.constant(WebViewState())).Compose()
        }
        return navigator
    }

    @Test
    fun testClipWithoutAnyUriFallsBackToData() {
        val fromData = android.net.Uri.parse("content://test/1")
        val intent = clipResult(android.content.ClipData.Item("just text"))
        intent.data = fromData
        org.junit.Assert.assertEquals(listOf(fromData), parse(intent)!!.toList())
    }

    @Test
    fun testClipUrisTakePrecedenceOverData() {
        val fromClip = android.net.Uri.parse("content://test/2")
        val intent = clipResult(android.content.ClipData.Item(fromClip))
        intent.data = android.net.Uri.parse("content://test/1")
        org.junit.Assert.assertEquals(listOf(fromClip), parse(intent)!!.toList())
    }

    @Test
    fun testFailedLaunchResolvesTheCallbackWithNull() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            composeRule.runOnIdle {
                val launcher = FakeLauncher()
                launcher.failOnLaunch = true
                engine.androidFileChooserLauncher = launcher
                val recorder = Recorder()
                org.junit.Assert.assertTrue(engine.presentAndroidFileChooser(recorder.callback, fakeParams()))
                org.junit.Assert.assertEquals(1, launcher.launched)
                org.junit.Assert.assertEquals(1, recorder.values.size)
                org.junit.Assert.assertNull(recorder.values[0])
                org.junit.Assert.assertNull(engine.pendingFileChooserCallback)
                org.junit.Assert.assertNull(engine.pendingFileChooserOwner)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testFailingToBuildTheIntentResolvesTheCallbackWithNull() {
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            composeRule.runOnIdle {
                val launcher = FakeLauncher()
                engine.androidFileChooserLauncher = launcher
                val recorder = Recorder()
                org.junit.Assert.assertTrue(engine.presentAndroidFileChooser(recorder.callback, throwingParams()))
                org.junit.Assert.assertEquals(0, launcher.launched)
                org.junit.Assert.assertEquals(1, recorder.values.size)
                org.junit.Assert.assertNull(recorder.values[0])
                org.junit.Assert.assertNull(engine.pendingFileChooserCallback)
                org.junit.Assert.assertNull(engine.pendingFileChooserOwner)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testDestroyingTheEngineResolvesAPendingRequest() {
        val engine = composeRule.runOnIdle { WebEngine() }
        val recorder = Recorder()
        composeRule.runOnIdle {
            engine.androidFileChooserLauncher = FakeLauncher()
            engine.presentAndroidFileChooser(recorder.callback, fakeParams())
            org.junit.Assert.assertTrue(recorder.values.isEmpty())
            engine.destroyNativeView()
            org.junit.Assert.assertEquals(1, recorder.values.size)
            org.junit.Assert.assertNull(recorder.values[0])
            org.junit.Assert.assertNull(engine.pendingFileChooserCallback)
        }
    }

    @Test
    fun testHandlerReturningTrueTakesTheRequestAndSkipsTheDefaultPicker() {
        var handlerCalls = 0
        val config = WebEngineConfiguration()
        config.androidFileChooserHandler = { _, _, _ -> handlerCalls += 1; true }
        val navigator = mountWebView(config)
        val engine = composeRule.runOnIdle { navigator.webEngine!! }
        try {
            composeRule.runOnIdle {
                val launcher = FakeLauncher()
                engine.androidFileChooserLauncher = launcher
                val recorder = Recorder()
                val client = engine.webView.webChromeClient as SkipWebChromeClient
                org.junit.Assert.assertTrue(client.onShowFileChooser(engine.webView, recorder.callback, fakeParams()))
                org.junit.Assert.assertEquals(1, handlerCalls)
                org.junit.Assert.assertEquals(0, launcher.launched)
                org.junit.Assert.assertTrue(recorder.values.isEmpty())
                org.junit.Assert.assertNull(engine.pendingFileChooserCallback)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testHandlerReturningFalseFallsBackToTheDefaultPicker() {
        var handlerCalls = 0
        val config = WebEngineConfiguration()
        config.androidFileChooserHandler = { _, _, _ -> handlerCalls += 1; false }
        val navigator = mountWebView(config)
        val engine = composeRule.runOnIdle { navigator.webEngine!! }
        try {
            composeRule.runOnIdle {
                val launcher = FakeLauncher()
                engine.androidFileChooserLauncher = launcher
                val recorder = Recorder()
                val client = engine.webView.webChromeClient as SkipWebChromeClient
                org.junit.Assert.assertTrue(client.onShowFileChooser(engine.webView, recorder.callback, fakeParams()))
                org.junit.Assert.assertEquals(1, handlerCalls)
                org.junit.Assert.assertEquals(1, launcher.launched)
                org.junit.Assert.assertNotNull(engine.pendingFileChooserCallback)
                org.junit.Assert.assertTrue(recorder.values.isEmpty())
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testDecliningHandlerDoesNotCancelAnOpenDefaultPicker() {
        val config = WebEngineConfiguration()
        config.androidFileChooserHandler = { _, _, _ -> false }
        val navigator = mountWebView(config)
        val engine = composeRule.runOnIdle { navigator.webEngine!! }
        try {
            composeRule.runOnIdle {
                val launcher = FakeLauncher()
                engine.androidFileChooserLauncher = launcher
                val first = Recorder()
                val second = Recorder()
                val client = engine.webView.webChromeClient as SkipWebChromeClient
                client.onShowFileChooser(engine.webView, first.callback, fakeParams())
                client.onShowFileChooser(engine.webView, second.callback, fakeParams())
                org.junit.Assert.assertEquals(1, launcher.launched)
                org.junit.Assert.assertTrue(first.values.isEmpty())
                org.junit.Assert.assertEquals(1, second.values.size)
                org.junit.Assert.assertNull(second.values[0])
                org.junit.Assert.assertNotNull(engine.pendingFileChooserCallback)
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }

    @Test
    fun testHandlerTakingOverLeavesAnOpenDefaultPickerAlone() {
        var handlerResult = false
        val config = WebEngineConfiguration()
        config.androidFileChooserHandler = { _, _, _ -> handlerResult }
        val navigator = mountWebView(config)
        val engine = composeRule.runOnIdle { navigator.webEngine!! }
        try {
            composeRule.runOnIdle {
                val launcher = FakeLauncher()
                engine.androidFileChooserLauncher = launcher
                val first = Recorder()
                val second = Recorder()
                val client = engine.webView.webChromeClient as SkipWebChromeClient
                client.onShowFileChooser(engine.webView, first.callback, fakeParams())
                handlerResult = true
                org.junit.Assert.assertTrue(client.onShowFileChooser(engine.webView, second.callback, fakeParams()))
                org.junit.Assert.assertEquals(1, launcher.launched)
                org.junit.Assert.assertTrue(first.values.isEmpty())
                org.junit.Assert.assertTrue(second.values.isEmpty())
                org.junit.Assert.assertNotNull(engine.pendingFileChooserCallback)
                val uri = android.net.Uri.parse("content://test/1")
                engine.completeAndroidFileChooser(android.app.Activity.RESULT_OK, android.content.Intent().setData(uri), launcher)
                org.junit.Assert.assertEquals(listOf(uri), first.values.single()!!.toList())
            }
        } finally {
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }
    */
}
#endif
