// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import SkipWeb

#if SKIP
/// Exercises real window attachment without requiring a network page or long-press timing.
// SKIP INSERT: @org.junit.runner.RunWith(androidx.test.ext.junit.runners.AndroidJUnit4::class)
final class AndroidLinkMenuLifecycleTests: XCTestCase {
    /* SKIP INSERT:
    @get:org.junit.Rule
    val composeRule = androidx.compose.ui.test.junit4.createComposeRule()

    @Test
    fun testDetachAndReattachRejectsPendingLinkMenu() {
        val visible = androidx.compose.runtime.mutableStateOf(true)
        val engine = composeRule.runOnIdle { WebEngine() }
        try {
            composeRule.setContent {
                if (visible.value) {
                    androidx.compose.ui.viewinterop.AndroidView(factory = {
                        (engine.webView.parent as? android.view.ViewGroup)?.removeView(engine.webView)
                        engine.webView
                    })
                }
            }
            val generation = composeRule.runOnIdle {
                org.junit.Assert.assertTrue(engine.isCurrentLinkMenu(engine.linkMenuGeneration, engine.webView.url))
                engine.linkMenuGeneration
            }
            val pageURL = composeRule.runOnIdle { engine.webView.url }
            composeRule.runOnIdle { visible.value = false }
            composeRule.runOnIdle {
                org.junit.Assert.assertFalse(engine.webView.isAttachedToWindow)
                org.junit.Assert.assertTrue(engine.linkMenuGeneration > generation)
                org.junit.Assert.assertFalse(engine.isCurrentLinkMenu(generation, pageURL))
            }
            composeRule.runOnIdle { visible.value = true }
            composeRule.runOnIdle {
                org.junit.Assert.assertTrue(engine.webView.isAttachedToWindow)
                org.junit.Assert.assertEquals(pageURL, engine.webView.url)
                org.junit.Assert.assertFalse(engine.isCurrentLinkMenu(generation, pageURL))
                org.junit.Assert.assertTrue(engine.isCurrentLinkMenu(engine.linkMenuGeneration, pageURL))
            }
        } finally {
            composeRule.runOnIdle { visible.value = false }
            composeRule.runOnIdle { engine.webView.destroy() }
        }
    }
    */
}
#endif
