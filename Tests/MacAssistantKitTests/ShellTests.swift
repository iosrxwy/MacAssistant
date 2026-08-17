import XCTest
@testable import MacAssistantKit

final class ShellTests: XCTestCase {
    func testRunEchoProducesOutput() throws {
        let result = try Shell.run("/bin/echo", ["hello"])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.trimmedOutput, "hello")
    }

    func testWhichFindsCommonTool() {
        XCTAssertNotNil(Shell.which("ls"))
    }

    func testFailingCommandReportsNonZeroExit() throws {
        let result = try Shell.run("/bin/sh", ["-c", "exit 7"])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.succeeded)
    }
}
