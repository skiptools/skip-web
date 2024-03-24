// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import XCTest
import OSLog
import Foundation
import SkipWeb

let logger: Logger = Logger(subsystem: "SkipWeb", category: "Tests")

@available(macOS 13, *)
final class SkipWebTests: XCTestCase {
    func testSkipWeb() throws {
        logger.log("running testSkipWeb")
        XCTAssertEqual(1 + 2, 3, "basic test")
        
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("SkipWeb", testData.testModuleName)
    }

    func testWebEngine() throws {
        if isRobolectric {
            throw XCTSkip("cannot run WebEngine in Robolectric")
        }

        if isAndroid {
            throw XCTSkip("FIXME: WebView cannot be initialized on a thread that has no Looper")
        }

        let engine = WebEngine()
        engine.reload()
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
