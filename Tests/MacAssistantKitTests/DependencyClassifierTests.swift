import XCTest
@testable import MacAssistantKit

final class DependencyClassifierTests: XCTestCase {

    private let emptyContext = DependencyClassificationContext()

    func testKnownSystemLibrary() {
        let result = DependencyClassifier.classify(path: "/usr/lib/libobjc.A.dylib", context: emptyContext)
        XCTAssertEqual(result.classification, .systemLibrary)
        XCTAssertTrue(result.isResolvedLocally)
    }

    func testSystemFrameworkPath() {
        let result = DependencyClassifier.classify(
            path: "/System/Library/Frameworks/Foundation.framework/Foundation",
            context: emptyContext
        )
        XCTAssertEqual(result.classification, .systemLibrary)
    }

    func testJailbreakKeywordUnderUsrLibIsDeviceProvided() {
        let result = DependencyClassifier.classify(path: "/usr/lib/libsubstrate.dylib", context: emptyContext)
        XCTAssertEqual(result.classification, .deviceProvided)
        XCTAssertFalse(result.isResolvedLocally)
    }

    func testUnrecognizedUsrLibIsUnknownNotGuessed() {
        let result = DependencyClassifier.classify(path: "/usr/lib/libMystery.dylib", context: emptyContext)
        XCTAssertEqual(result.classification, .unknown)
        XCTAssertFalse(result.isResolvedLocally)
    }

    func testJailbreakRootPathIsDeviceProvided() {
        let rootless = DependencyClassifier.classify(path: "/var/jb/usr/lib/libfoo.dylib", context: emptyContext)
        XCTAssertEqual(rootless.classification, .deviceProvided)

        let mobileSubstrate = DependencyClassifier.classify(
            path: "/Library/MobileSubstrate/DynamicLibraries/Foo.dylib",
            context: emptyContext
        )
        XCTAssertEqual(mobileSubstrate.classification, .deviceProvided)
    }

    func testPluginProvidedTakesPrecedence() {
        let context = DependencyClassificationContext(pluginProvidedNames: ["libplug.dylib"])
        let result = DependencyClassifier.classify(path: "/Library/foo/libplug.dylib", context: context)
        XCTAssertEqual(result.classification, .pluginProvided)
        XCTAssertTrue(result.isResolvedLocally)
    }

    func testAppEmbeddedMatch() {
        let context = DependencyClassificationContext(appEmbeddedNames: ["libcustom.dylib"])
        let result = DependencyClassifier.classify(path: "@rpath/libcustom.dylib", context: context)
        XCTAssertEqual(result.classification, .appEmbedded)
    }

    func testLoaderRelativeUnresolvedIsUnknown() {
        let result = DependencyClassifier.classify(path: "@rpath/libunknown.dylib", context: emptyContext)
        XCTAssertEqual(result.classification, .unknown)
        XCTAssertFalse(result.isResolvedLocally)
    }

    func testArbitraryPathIsUnknown() {
        let result = DependencyClassifier.classify(path: "/opt/custom/lib.dylib", context: emptyContext)
        XCTAssertEqual(result.classification, .unknown)
    }

    func testEvidenceIsPopulated() {
        let result = DependencyClassifier.classify(path: "/usr/lib/libMystery.dylib", context: emptyContext)
        XCTAssertFalse(result.evidence.isEmpty)
        XCTAssertNotEqual(result.evidence, "dep.class.usrLibUnrecognized", "evidence 应是本地化文案而非裸 key")
    }
}
