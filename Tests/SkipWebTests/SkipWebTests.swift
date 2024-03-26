// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import XCTest
import OSLog
import Foundation
import SkipWeb

let logger: Logger = Logger(subsystem: "SkipWeb", category: "Tests")

// SKIP INSERT: @org.junit.runner.RunWith(androidx.test.ext.junit.runners.AndroidJUnit4::class)
// SKIP INSERT: @androidx.test.annotation.UiThreadTest
final class SkipWebTests: XCTestCase {

    func testSkipWeb() throws {
        logger.log("running testSkipWeb")
        XCTAssertEqual(1 + 2, 3, "basic test")
        
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("SkipWeb", testData.testModuleName)
    }

    func testWebEngine() async throws {
        if isRobolectric {
            throw XCTSkip("cannot run WebEngine in Robolectric")
        }

        //assertMainThread()

        let engine = await WebEngine()

        func html(title: String, body: String = "") -> String {
            "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
        }

        if isAndroid {
            throw XCTSkip("TODO: implement Android side")
        }

        // needed before JS can be evaluated?
        //try await engine.loadHTML(html(title: "Initial Load"))

        // FIXME: Android times out and cancels coroutine after 10 seconds
        let three = try await engine.evaluate(js: "1+2")
        XCTAssertEqual("3", three)


        // try async load with both HTML string and file URL loading and ensure the DOM is updated

        do {
            let title = "Hello HTML String!"
            try await engine.loadHTML(html(title: title))
            let title1 = try await engine.evaluate(js: "document.title")
            XCTAssertEqual(title, title1)
        }

        do {
            let fileURL = URL.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("html")

            let title = "Hello HTML File!"
            try html(title: title).write(to: fileURL, atomically: false, encoding: .utf8)

            try await engine.load(url: fileURL)
            let title2 = try await engine.evaluate(js: "document.title")
            XCTAssertEqual(title, title2)
        }
    }

    func assertMainThread() {
        #if !SKIP
        XCTAssertTrue(Thread.isMainThread)
        #else
        XCTAssertTrue((android.os.Looper.myLooper() == android.os.Looper.getMainLooper()), "test case must be run on main thread: \(android.os.Looper.myLooper()) vs. \(android.os.Looper.getMainLooper())") // or else: java.lang.RuntimeException: WebView cannot be initialized on a thread that has no Looper.
        #endif
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
