import XCTest
@testable import HelloCore

final class GreetingTests: XCTestCase {
    func testMessageIncludesName() {
        XCTAssertTrue(Greeting.message(for: "Ada").hasPrefix("Hello, Ada, from macOS "))
    }

    func testMessageIncludesMajorVersion() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        XCTAssertTrue(Greeting.message(for: "x").contains("macOS \(major)."))
    }

    func testViewBuilds() {
        _ = GreetingView(name: "Ada").body
    }
}
