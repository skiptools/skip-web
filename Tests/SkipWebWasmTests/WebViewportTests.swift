// Copyright 2023-2026 Skip
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import SkipWebWasm

final class WebViewportTests: XCTestCase {
    func testResponsiveBreakpoints() {
        XCTAssertEqual(WebViewportSnapshot(width: 375, height: 812).breakpoint, .compact)
        XCTAssertEqual(WebViewportSnapshot(width: 600, height: 900).breakpoint, .medium)
        XCTAssertEqual(WebViewportSnapshot(width: 839, height: 900).breakpoint, .medium)
        XCTAssertEqual(WebViewportSnapshot(width: 840, height: 900).breakpoint, .expanded)
    }
}
