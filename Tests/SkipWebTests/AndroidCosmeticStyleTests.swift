// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if os(macOS) && !SKIP
import WebKit
import XCTest
@testable import SkipWeb

/// Executes the Android script in a real DOM without a JavaScript test dependency.
final class AndroidCosmeticStyleTests: XCTestCase {
    @MainActor
    func testNestedInsertionsAreScannedOnceAndDetachedStylesAreRestored() async throws {
        let result = try await run("""
        window.__skipWebCosmeticStyles.replace('test', '.ad { display: none !important; }');
        var scans = 0;
        var query = Element.prototype.querySelectorAll;
        Element.prototype.querySelectorAll = function (selector) { scans++; return query.call(this, selector); };
        var parent = document.createElement('section');
        document.body.appendChild(parent);
        for (var i = 0; i < 100; i++) {
            var child = document.createElement('div');
            child.className = 'ad';
            child.style.setProperty('display', 'block', 'important');
            parent.appendChild(child);
        }
        await settle();
        var bounded = scans === 1;
        var hidden = getComputedStyle(parent.firstChild).display === 'none';
        parent.remove();
        await settle();
        return bounded && hidden && parent.firstChild.style.display === 'block';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    @MainActor
    func testMatchingOneElementDoesNotChangeAnotherElementsSelector() async throws {
        let result = try await run("""
        document.body.innerHTML = '<div class="first" style="display: block !important;"></div><div class="second" style="display: block !important;"></div>';
        window.__skipWebCosmeticStyles.replace('test',
            '.first, [style="display: block !important;"] + .second { display: none !important; }');
        return Array.from(document.body.children).every(element => getComputedStyle(element).display === 'none');
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    @MainActor
    func testPageCanTakeOwnershipOfHiddenDisplayBeforeDisable() async throws {
        let result = try await run("""
        document.body.innerHTML = '<div class="ad" style="display: block !important;"></div>';
        var ad = document.querySelector('.ad');
        window.__skipWebCosmeticStyles.replace('test', '.ad { display: none !important; }');
        ad.style.setProperty('display', 'flex', 'important');
        ad.style.setProperty('display', 'none', 'important');
        window.__skipWebCosmeticStyles.replace('test', '');
        return ad.style.display;
        """)
        XCTAssertEqual(result as? String, "none")
    }

    @MainActor
    func testLargeRuleSetBatchesWorkAndStopsAfterDisable() async throws {
        let result = try await run("""
        // Match the investigated page's scale: 18 grouped rules, ~14,400 selectors,
        // 1,000 nodes, many inline styles, only two inline-important conflicts.
        document.body.innerHTML = '<main></main>';
        var main = document.querySelector('main');
        for (var i = 0; i < 1000; i++) {
            var node = document.createElement('div');
            node.style.color = 'red';
            main.appendChild(node);
        }
        main.children[0].className = 'ad';
        main.children[0].style.setProperty('display', 'block', 'important');
        main.children[1].style.setProperty('display', 'flex', 'important');
        var css = [];
        for (var group = 0; group < 18; group++) {
            var selectors = [];
            for (var i = 0; i < 800; i++) { selectors.push('.unused-' + group + '-' + i); }
            if (group === 17) { selectors.push('.ad'); }
            css.push(selectors.join(',') + ' { display: none !important; }');
        }
        var calls = 0;
        var scans = 0;
        var matches = Element.prototype.matches;
        var query = Document.prototype.querySelectorAll;
        Element.prototype.matches = function (selector) { calls++; return matches.call(this, selector); };
        Document.prototype.querySelectorAll = function (selector) { scans++; return query.call(this, selector); };
        window.__skipWebCosmeticStyles.replace('test', css.join('\\n'));
        calls = 0;
        scans = 0;
        for (var i = 0; i < 100; i++) { main.setAttribute('data-change', String(i)); }
        await settle();
        var batched = calls > 0 && calls <= 36 && scans === 0;
        var afterBatch = calls;
        await settle();
        var noLoop = calls === afterBatch;
        var hidden = getComputedStyle(main.children[0]).display === 'none';
        window.__skipWebCosmeticStyles.replace('test', '');
        calls = 0;
        main.children[0].style.setProperty('display', 'grid', 'important');
        await settle();
        return batched && noLoop && hidden && calls === 0
            && getComputedStyle(main.children[0]).display === 'grid';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    @MainActor
    func testDocumentStartWaitsForRootAndRepairsRemovedStylesheet() async throws {
        let result = try await run("""
        document.body.innerHTML = '<div class="ad" style="display: block !important;"></div><div class="ordinary"></div>';
        var root = document.documentElement;
        root.remove();
        window.__skipWebCosmeticStyles.replace('test', '.ad, .ordinary { display: none !important; }');
        document.appendChild(root);
        await settle();
        var hidden = getComputedStyle(document.querySelector('.ad')).display === 'none';
        document.getElementById('test')?.remove();
        await settle();
        return hidden && getComputedStyle(document.querySelector('.ordinary')).display === 'none';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    @MainActor
    func testCleanupPreservesNewPageStylesIncludingPendingMutations() async throws {
        let result = try await run("""
        document.body.innerHTML = '<div class="ad" style="display: block !important; color: red;"></div>';
        var ad = document.querySelector('.ad');
        var blocker = window.__skipWebCosmeticStyles;
        blocker.replace('test', '.ad { display: none !important; }');
        ad.style.color = 'blue';
        await settle();
        var hidden = getComputedStyle(ad).display === 'none';
        blocker.replace('test', '');
        var restored = ad.style.display === 'block' && ad.style.color === 'blue';
        blocker.replace('test', '.ad { display: none !important; }');
        ad.style.setProperty('display', 'flex', 'important');
        // Disable before the observer callback: cleanup must use the latest page value.
        blocker.replace('test', '');
        return hidden && restored && ad.style.display === 'flex' && ad.style.color === 'blue';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    @MainActor
    func testStyleSelectorsAndAncestorChangesUseAuthoredStyles() async throws {
        let result = try await run("""
        document.body.innerHTML = '<section><div class="ad" style="display: block !important;"></div></section>';
        var parent = document.querySelector('section');
        var ad = document.querySelector('.ad');
        window.__skipWebCosmeticStyles.replace('test',
            '.active .ad[style="display: block !important;"] { display: none !important; }');
        var displays = [getComputedStyle(ad).display];
        parent.className = 'active';
        await settle();
        displays.push(getComputedStyle(ad).display);
        parent.setAttribute('data-unrelated', 'changed');
        await settle();
        displays.push(getComputedStyle(ad).display);
        parent.className = '';
        await settle();
        displays.push(getComputedStyle(ad).display);
        return displays.join(',');
        """)
        XCTAssertEqual(result as? String, "block,none,none,block")
    }

    @MainActor
    func testRuleReplacementAndDisableRestoreAuthoredStyle() async throws {
        let result = try await run("""
        document.body.innerHTML = '<div class="ad" style="display:block!important; color:red"></div>';
        var ad = document.querySelector('.ad');
        var original = ad.getAttribute('style');
        var blocker = window.__skipWebCosmeticStyles;
        blocker.replace('first', '.ad { display: none !important; }');
        blocker.replace('second', '.ad { display: none !important; }');
        blocker.replace('first', '');
        var stillHidden = getComputedStyle(ad).display === 'none';
        blocker.replace('second', '.other { display: none !important; }');
        var restored = ad.getAttribute('style') === original;
        blocker.replace('second', '.ad { display: none !important; }');
        blocker.replace('second', '');
        return stillHidden && restored && ad.getAttribute('style') === original
            && !document.getElementById('second');
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    @MainActor
    func testLateInsertionAndRepeatedInlineRewritesStayHidden() async throws {
        let result = try await run("""
        window.__skipWebCosmeticStyles.replace('test-style', '.ad { display: none !important; }');
        var ad = document.createElement('div');
        ad.className = 'ad';
        ad.style.setProperty('display', 'block', 'important');
        document.body.appendChild(ad);
        var displays = [];
        await settle();
        displays.push(getComputedStyle(ad).display);
        for (var value of ['flex', 'grid', 'block']) {
            ad.style.setProperty('display', value, 'important');
            await settle();
            displays.push(getComputedStyle(ad).display);
        }
        return displays.join(',');
        """)
        XCTAssertEqual(result as? String, "none,none,none,none")
    }

    @MainActor
    func testInlineImportantOverlayIsHidden() async throws {
        let result = try await run("""
        document.body.innerHTML = '<iframe style="width: 280px !important; height: 280px !important; margin: 0px auto !important; display: block !important;"></iframe>';
        window.__skipWebCosmeticStyles.replace('test-style',
            'iframe[style^="width: 280px !important; height: 280px !important; margin:"] { display: none !important; }');
        return getComputedStyle(document.querySelector('iframe')).display;
        """)
        XCTAssertEqual(result as? String, "none")
    }

    /// Each case has its own document and awaits actual browser mutation delivery.
    @MainActor
    private func run(_ body: String) async throws -> Any? {
        let view = WKWebView()
        return try await view.callAsyncJavaScript(
            "document.open(); document.write('<html><head></head><body></body></html>'); document.close();\n"
                + AndroidCosmeticStyleScript.source
                + "\nvar settle = () => new Promise(resolve => setTimeout(resolve, 50));\n" + body,
            arguments: [:], in: nil, contentWorld: .page
        )
    }
}
#endif
