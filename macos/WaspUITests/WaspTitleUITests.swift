//
//  WaspTitleUITests.swift
//  WaspUITests
//
//  Created by luca on 13.10.2025.
//

import XCTest

final class WaspTitleUITests: WaspCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(#"title = "WaspUITestsLaunchTests""#)
    }

    @MainActor
    func testTitle() throws {
        let app = try waspApplication()
        app.launch()

        XCTAssertEqual(app.windows.firstMatch.title, "WaspUITestsLaunchTests", "Oops, `title=` doesn't work!")
    }
}
