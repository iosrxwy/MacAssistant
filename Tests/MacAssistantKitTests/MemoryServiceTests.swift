import XCTest
@testable import MacAssistantKit

final class MemoryServiceTests: XCTestCase {
    /// 断言里写死了中文文案,不固定语言的话在英文系统上会失败。
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testParseVMStatUsesReportedPageSize() {
        let text = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free: 100.
        Pages active: 200.
        Pages occupied by compressor: 30.
        File-backed pages: 40.
        """
        let result = MemoryService.parseVMStat(text)
        XCTAssertEqual(result.pageSize, 16_384)
        XCTAssertEqual(result.pages["Pages free"], 100)
        XCTAssertEqual(result.pages["Pages occupied by compressor"], 30)
    }

    func testUsedBytesMatchesActivityMonitorMethodology() {
        // 真实机器采样：24GB 物理内存，free+speculative 仅约 112MB。
        let text = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                3730.
        Pages active:                            568577.
        Pages inactive:                          564806.
        Pages speculative:                         3436.
        Pages wired down:                        315087.
        Pages purgeable:                          25062.
        File-backed pages:                       210276.
        Anonymous pages:                         926543.
        Pages occupied by compressor:             57520.
        """
        let parsed = MemoryService.parseVMStat(text)
        // 已用 = 匿名 − 可清除 + 联动 + 压缩 = 1_274_088 页 ≈ 19.4GB，
        // 而不是“物理内存 − 空闲页” ≈ 23.9GB（那会让已用永远接近 100%）。
        XCTAssertEqual(
            MemoryService.usedBytes(pages: parsed.pages, pageSize: parsed.pageSize),
            1_274_088 * 16_384
        )
        // 已缓存文件 = 文件页 + 可清除页。
        XCTAssertEqual(
            MemoryService.cachedFilesBytes(pages: parsed.pages, pageSize: parsed.pageSize),
            235_338 * 16_384
        )
    }

    func testUsedBytesIgnoresFileCacheAndClampsPurgeable() {
        // 大量文件缓存不应计入已用；purgeable 大于匿名页时做饱和处理而不是下溢。
        let pages: [String: UInt64] = [
            "Anonymous pages": 100,
            "Pages purgeable": 300,
            "Pages wired down": 50,
            "Pages occupied by compressor": 20,
            "File-backed pages": 100_000,
            "Pages free": 10
        ]
        XCTAssertEqual(MemoryService.usedBytes(pages: pages, pageSize: 16_384), 70 * 16_384)
    }

    func testParseSwapAndPressure() {
        XCTAssertEqual(
            MemoryService.parseSwapUsage("total = 4096.00M  used = 1536.50M  free = 2559.50M"),
            1_611_137_024
        )
        XCTAssertEqual(
            MemoryService.parsePressureFreePercent("System-wide memory free percentage: 43%"),
            43
        )
        XCTAssertEqual(MemoryService.pressureLevel(freePercent: 43), .healthy)
        XCTAssertEqual(MemoryService.pressureLevel(freePercent: 15), .warning)
        XCTAssertEqual(MemoryService.pressureLevel(freePercent: 5), .critical)
    }

    func testParsePSSortsRSSAndFiltersUser() {
        let text = """
          100  501  2048 /Applications/A.app/Contents/MacOS/A
          101    0 99999 /usr/libexec/system
          102  501  4096 /Applications/B App.app/Contents/MacOS/B App
        """
        let processes = MemoryService.parsePS(text, currentUserID: 501)
        XCTAssertEqual(processes.map(\.pid), [102, 100])
        XCTAssertEqual(processes.first?.rssBytes, 4_194_304)
        XCTAssertEqual(processes.first?.name, "B App")
    }

    func testApplicationBundleResolverFindsOwningApp() {
        XCTAssertEqual(
            ProcessApplicationResolver.applicationBundlePath(
                forExecutablePath: "/Applications/Telegram.app/Contents/MacOS/Telegram"
            ),
            "/Applications/Telegram.app"
        )
    }

    func testApplicationBundleResolverMapsNestedHelperToOutermostHost() {
        let path = "/Applications/Cursor.app/Contents/Frameworks/"
            + "Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)"
        XCTAssertEqual(
            ProcessApplicationResolver.applicationBundlePath(
                forExecutablePath: path
            ),
            "/Applications/Cursor.app"
        )
        XCTAssertEqual(
            ProcessApplicationResolver.applicationBundlePaths(forExecutablePath: path),
            [
                "/Applications/Cursor.app",
                "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app"
            ]
        )
    }

    func testApplicationBundleResolverFallsBackForNonAppExecutable() {
        XCTAssertNil(
            ProcessApplicationResolver.applicationBundlePath(
                forExecutablePath: "/usr/libexec/exampled"
            )
        )
    }

    func testProcessIconCacheKeyDeduplicatesProcessesFromTheSameApp() {
        let key = ProcessIconCacheKey(pid: 42, bundlePath: "/Applications/A.app")
        XCTAssertEqual(key, ProcessIconCacheKey(pid: 43, bundlePath: "/Applications/A.app"))
        XCTAssertNotEqual(key, ProcessIconCacheKey(pid: 42, bundlePath: "/Applications/B.app"))
        XCTAssertNotEqual(
            ProcessIconCacheKey(pid: 42, bundlePath: nil),
            ProcessIconCacheKey(pid: 43, bundlePath: nil)
        )
    }

    func testProcPIDPathResolvesCurrentProcessWithoutAffectingFallbackCallers() {
        let path = MemoryService.processExecutablePath(
            pid: ProcessInfo.processInfo.processIdentifier
        )
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.hasPrefix("/") == true)
        XCTAssertNil(MemoryService.processExecutablePath(pid: -1))
    }

    func testPIDProtectionRejectsInvalidSelfAndCriticalProcesses() {
        XCTAssertThrowsError(try MemoryService.validatePID(1, processName: "launchd", ownPID: 500))
        XCTAssertThrowsError(try MemoryService.validatePID(500, processName: "MacAssistant", ownPID: 500))
        XCTAssertThrowsError(try MemoryService.validatePID(88, processName: "WindowServer", ownPID: 500))
        XCTAssertNoThrow(try MemoryService.validatePID(999, processName: "Example", ownPID: 500))
    }

    func testByteFormattingIsNonEmpty() {
        XCTAssertFalse(MemoryService.formatBytes(1_073_741_824).isEmpty)
    }

    func testPurgeIsDeveloperFileCacheOperationNotMemoryRelease() {
        let operation = MemoryService.purgeOperation
        XCTAssertEqual(operation.kind, .developerFileCacheBenchmark)
        XCTAssertTrue(operation.title.contains("文件缓存"))
        XCTAssertTrue(operation.explanation.contains("匿名内存"))
        XCTAssertTrue(operation.explanation.contains("不保证提速"))
        XCTAssertFalse(operation.title.contains("释放内存"))
        XCTAssertFalse(operation.explanation.contains("一键释放"))
    }

    func testProductLinksAreExact() {
        XCTAssertEqual(ProductLinks.github.absoluteString, "https://github.com/iosrxwy/MacAssistant")
        XCTAssertEqual(ProductLinks.releaseChannel.absoluteString, "https://t.me/iosrxwy")
        XCTAssertEqual(ProductLinks.altSignProject.absoluteString, "https://github.com/rileytestut/AltSign")
        XCTAssertEqual(ProductLinks.altStoreGitHub.absoluteString, "https://github.com/altstoreio/AltStore")
    }
}
