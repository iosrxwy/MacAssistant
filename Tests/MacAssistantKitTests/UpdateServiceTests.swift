import XCTest
@testable import MacAssistantKit

/// 检查更新的单元测试。**不联网**:所有网络往返都由注入的 transport 用固定 fixture 模拟。
final class UpdateServiceTests: XCTestCase {

    // MARK: - 测试替身

    /// `UserDefaults` 的内存替身,避免测试污染真实域、也避免用例之间互相串味。
    private final class MemoryDefaults: UpdateDefaults {
        private var storage: [String: Any] = [:]

        func object(forKey defaultName: String) -> Any? { storage[defaultName] }
        func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
        func bool(forKey defaultName: String) -> Bool { (storage[defaultName] as? Bool) ?? false }
        func double(forKey defaultName: String) -> Double { (storage[defaultName] as? Double) ?? 0 }

        func set(_ value: Any?, forKey defaultName: String) {
            if let value {
                storage[defaultName] = value
            } else {
                storage.removeValue(forKey: defaultName)
            }
        }
    }

    /// 记录 transport 收到的请求,用来断言「被节流时根本没发请求」。
    private final class RequestLog {
        var requests: [URLRequest] = []
        var count: Int { requests.count }
    }

    private func transport(
        log: RequestLog? = nil,
        _ handler: @escaping () throws -> (Data, URLResponse)
    ) -> UpdateService.Transport {
        { request in
            log?.requests.append(request)
            return try handler()
        }
    }

    private func response(
        _ status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: ProductLinks.Repository.latestReleaseAPI,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    /// 贴近 GitHub 真实返回体:字段名、多余字段、null 值都保留原样。
    private func releaseJSON(
        tag: String = "v1.2.0",
        name: String = "v1.2.0 清理与修复增强",
        body: String = "## 新增\\n- 系统清理支持按体积排序\\n\\n## 修复\\n- 修复 Intel 机器上的路径判断",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> Data {
        Data(#"""
        {
          "url": "https://api.github.com/repos/iosrxwy/MacAssistant/releases/155229981",
          "assets_url": "https://api.github.com/repos/iosrxwy/MacAssistant/releases/155229981/assets",
          "upload_url": "https://uploads.github.com/repos/iosrxwy/MacAssistant/releases/155229981/assets{?name,label}",
          "html_url": "https://github.com/iosrxwy/MacAssistant/releases/tag/\#(tag)",
          "id": 155229981,
          "author": {
            "login": "iosrxwy",
            "id": 10293847,
            "type": "User",
            "site_admin": false
          },
          "node_id": "RE_kwDOKq8fLs4JTmSd",
          "tag_name": "\#(tag)",
          "target_commitish": "main",
          "name": "\#(name)",
          "draft": \#(draft),
          "prerelease": \#(prerelease),
          "created_at": "2026-08-10T09:12:33Z",
          "published_at": "2026-08-10T09:20:41Z",
          "assets": [
            {
              "url": "https://api.github.com/repos/iosrxwy/MacAssistant/releases/assets/1",
              "id": 1,
              "name": "MacAssistant.dmg",
              "content_type": "application/x-apple-diskimage",
              "size": 18234112,
              "download_count": 42,
              "browser_download_url": "https://github.com/iosrxwy/MacAssistant/releases/download/\#(tag)/MacAssistant.dmg"
            }
          ],
          "tarball_url": "https://api.github.com/repos/iosrxwy/MacAssistant/tarball/\#(tag)",
          "zipball_url": "https://api.github.com/repos/iosrxwy/MacAssistant/zipball/\#(tag)",
          "body": "\#(body)"
        }
        """#.utf8)
    }

    private func makeService(
        currentVersion: String = "1.0.0",
        defaults: MemoryDefaults = MemoryDefaults(),
        transport: @escaping UpdateService.Transport
    ) -> (UpdateService, UpdatePreferences) {
        let preferences = UpdatePreferences(defaults: defaults)
        let service = UpdateService(
            currentVersion: currentVersion,
            preferences: preferences,
            transport: transport
        )
        return (service, preferences)
    }

    private func version(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AppVersion {
        try XCTUnwrap(AppVersion(raw), "应当能解析版本号 \(raw)", file: file, line: line)
    }

    // MARK: - 版本号比较

    /// 最典型的坑:字符串比较会得出 "1.10.0" < "1.9.0"。
    func testNumericSegmentsCompareAsIntegersNotStrings() throws {
        XCTAssertGreaterThan(try version("1.10.0"), try version("1.9.0"))
        XCTAssertGreaterThan(try version("1.0.10"), try version("1.0.9"))
        XCTAssertGreaterThan(try version("2.0.0"), try version("1.99.99"))
        XCTAssertGreaterThan(try version("1.100.0"), try version("1.99.0"))
        XCTAssertTrue(AppVersion.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(AppVersion.isNewer("1.9.0", than: "1.10.0"))
    }

    func testVPrefixIsEquivalent() throws {
        XCTAssertEqual(try version("v1.2.0"), try version("1.2.0"))
        XCTAssertEqual(try version("V1.2.0"), try version("1.2.0"))
        XCTAssertGreaterThan(try version("v1.3.0"), try version("1.2.0"))
        XCTAssertFalse(AppVersion.isNewer("v1.0.0", than: "1.0.0"))
    }

    func testDifferentComponentCountsAreZeroPadded() throws {
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertEqual(try version("1"), try version("1.0.0"))
        XCTAssertEqual(try version("1.2.0.0"), try version("1.2.0"))
        XCTAssertGreaterThan(try version("1.2.1"), try version("1.2"))
        XCTAssertGreaterThan(try version("1.2.0.1"), try version("1.2.0"))
    }

    /// semver:带预发布后缀的版本小于同号正式版。
    func testPrereleaseSortsBelowRelease() throws {
        XCTAssertLessThan(try version("1.2.0-beta.1"), try version("1.2.0"))
        XCTAssertLessThan(try version("1.2.0-rc.1"), try version("1.2.0"))
        XCTAssertGreaterThan(try version("1.2.0-beta.1"), try version("1.1.9"))
        XCTAssertFalse(AppVersion.isNewer("1.2.0-beta.1", than: "1.2.0"))
        XCTAssertTrue(AppVersion.isNewer("1.2.0", than: "1.2.0-beta.1"))
    }

    func testPrereleaseIdentifiersOrdering() throws {
        XCTAssertLessThan(try version("1.2.0-alpha"), try version("1.2.0-beta"))
        XCTAssertLessThan(try version("1.2.0-beta.1"), try version("1.2.0-beta.2"))
        XCTAssertLessThan(try version("1.2.0-beta.2"), try version("1.2.0-beta.10"))
        // 段数少的更小。
        XCTAssertLessThan(try version("1.2.0-beta"), try version("1.2.0-beta.1"))
        // 纯数字段小于字母段。
        XCTAssertLessThan(try version("1.2.0-1"), try version("1.2.0-alpha"))
        XCTAssertTrue(try version("1.2.0-beta.1").isPrerelease)
        XCTAssertFalse(try version("1.2.0").isPrerelease)
    }

    /// 构建元数据不参与优先级比较。
    func testBuildMetadataIsIgnored() throws {
        XCTAssertEqual(try version("1.2.0+20260810"), try version("1.2.0"))
        XCTAssertEqual(try version("v1.2.0-beta.1+sha.abc"), try version("1.2.0-beta.1"))
    }

    func testInvalidVersionStringsFailToParse() {
        let invalid = [
            "", "   ", "abc", "v", "V", "beta",
            "1..2", "1.2.", ".1.2", "1.2.x", "1.2.0-",
            "-1.2.0", "1.-2.0", "1.2.0-beta!", "nightly", "latest",
            "１.２.０",                                   // 全角数字
            "99999999999999999999.0.0"                    // 超出 Int 范围
        ]
        for raw in invalid {
            XCTAssertNil(AppVersion(raw), "不应解析成功: \(raw)")
        }
    }

    func testWhitespaceIsTolerated() throws {
        XCTAssertEqual(try version("  1.2.0\n"), try version("1.2.0"))
        XCTAssertEqual(try version("\tv1.2.0 "), try version("1.2.0"))
    }

    func testCanonicalStringNormalizesForm() throws {
        XCTAssertEqual(try version("v1.2").canonical, "1.2.0")
        XCTAssertEqual(try version("1").canonical, "1.0.0")
        XCTAssertEqual(try version("1.2.0.0").canonical, "1.2.0")
        XCTAssertEqual(try version("1.2.3.4").canonical, "1.2.3.4")
        XCTAssertEqual(try version("v1.2.0-beta.1+abc").canonical, "1.2.0-beta.1")
        XCTAssertEqual(try version("v1.2.0").description, "1.2.0")
    }

    /// 解析不了就当没有更新,绝不能误报。
    func testUnparsableVersionsNeverReportAnUpdate() {
        XCTAssertFalse(AppVersion.isNewer("nightly", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("2.0.0", than: "开发版"))
        XCTAssertFalse(AppVersion.isNewer("", than: ""))
    }

    // MARK: - 当前版本来源

    func testVersionSourcePrefersInfoPlistValue() {
        XCTAssertEqual(AppVersionSource.resolve(infoDictionaryVersion: "2.3.4"), "2.3.4")
        XCTAssertEqual(AppVersionSource.resolve(infoDictionaryVersion: " 2.3.4 "), "2.3.4")
    }

    /// `swift run` / Xcode 直接跑没有 Info.plist,必须回退而不是崩溃。
    func testVersionSourceFallsBackWhenPlistMissingOrGarbage() {
        XCTAssertEqual(AppVersionSource.resolve(infoDictionaryVersion: nil),
                       AppVersionSource.fallbackVersion)
        XCTAssertEqual(AppVersionSource.resolve(infoDictionaryVersion: ""),
                       AppVersionSource.fallbackVersion)
        XCTAssertEqual(AppVersionSource.resolve(infoDictionaryVersion: "开发版"),
                       AppVersionSource.fallbackVersion)
        XCTAssertNotNil(AppVersion(AppVersionSource.fallbackVersion))
    }

    /// 兜底常量必须和 `Resources/AppVersion.txt`(即 Info.plist 里的版本)保持一致。
    func testFallbackVersionMatchesRepositoryVersionFile() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MacAssistantKitTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // 仓库根
        let versionFile = repositoryRoot.appendingPathComponent("Resources/AppVersion.txt")
        guard let contents = try? String(contentsOf: versionFile, encoding: .utf8) else {
            throw XCTSkip("源码树不可用,跳过版本文件一致性校验")
        }
        XCTAssertEqual(
            contents.trimmingCharacters(in: .whitespacesAndNewlines),
            AppVersionSource.fallbackVersion,
            "Resources/AppVersion.txt 改了就要同步 AppVersionSource.fallbackVersion"
        )
    }

    // MARK: - 仓库常量

    func testRepositoryURLsDeriveFromSingleSource() {
        XCTAssertEqual(ProductLinks.Repository.slug, "iosrxwy/MacAssistant")
        XCTAssertEqual(ProductLinks.Repository.homepage.absoluteString,
                       "https://github.com/iosrxwy/MacAssistant")
        XCTAssertEqual(ProductLinks.Repository.releasesPage.absoluteString,
                       "https://github.com/iosrxwy/MacAssistant/releases")
        XCTAssertEqual(ProductLinks.Repository.latestReleaseAPI.absoluteString,
                       "https://api.github.com/repos/iosrxwy/MacAssistant/releases/latest")
        // 「关于」页那个账号链接也要跟着 owner 走。
        XCTAssertEqual(ProductLinks.github, ProductLinks.Repository.homepage)
    }

    // MARK: - 请求构造

    func testRequestCarriesHeadersGitHubRequires() {
        let request = UpdateService.makeRequest(currentVersion: "1.0.0")
        XCTAssertEqual(request.url, ProductLinks.Repository.latestReleaseAPI)
        XCTAssertEqual(request.httpMethod, "GET")
        // 没有 User-Agent 时 GitHub 直接 403。
        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(userAgent, "MacAssistant/1.0.0 (+https://github.com/iosrxwy/MacAssistant)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(UpdateService.requestTimeout, 10)
        XCTAssertNil(request.httpBody, "检查更新不应发送任何数据")
    }

    func testActualRequestIsTheConfiguredOne() async throws {
        let log = RequestLog()
        let (service, _) = makeService(
            currentVersion: "1.0.0",
            transport: transport(log: log) { (self.releaseJSON(), self.response(200)) }
        )
        _ = try await service.checkForUpdate()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.requests.first?.url, ProductLinks.Repository.latestReleaseAPI)
        XCTAssertNotNil(log.requests.first?.value(forHTTPHeaderField: "User-Agent"))
    }

    // MARK: - JSON 解析

    func testDecodesRealisticGitHubReleasePayload() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseJSON())
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.htmlURL.absoluteString,
                       "https://github.com/iosrxwy/MacAssistant/releases/tag/v1.2.0")
        XCTAssertEqual(release.name, "v1.2.0 清理与修复增强")
        XCTAssertEqual(release.publishedAt, "2026-08-10T09:20:41Z")
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.body?.hasPrefix("## 新增"), true)
        XCTAssertEqual(release.body?.contains("\n"), true, "JSON 里的 \\n 应还原成真正的换行")
        XCTAssertEqual(
            release.publishedDate,
            ISO8601DateFormatter().date(from: "2026-08-10T09:20:41Z")
        )
    }

    func testDecodesReleaseWithNullNameAndBody() throws {
        let json = Data(#"""
        {
          "tag_name": "v1.5.0",
          "html_url": "https://github.com/iosrxwy/MacAssistant/releases/tag/v1.5.0",
          "name": null,
          "body": null,
          "published_at": null,
          "draft": false,
          "prerelease": false
        }
        """#.utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertNil(release.name)
        XCTAssertNil(release.body)
        XCTAssertNil(release.publishedDate)

        // 没有 name 时用版本号兜底标题。
        guard case .updateAvailable(let info) =
                UpdateService.evaluate(release: release, currentVersion: "1.0.0") else {
            return XCTFail("应当判定为有更新")
        }
        XCTAssertEqual(info.title, "版本 1.5.0")
        XCTAssertEqual(info.releaseNotes, "")
    }

    func testMissingDraftAndPrereleaseFlagsDefaultToFalse() throws {
        let json = Data(#"""
        {
          "tag_name": "v1.5.0",
          "html_url": "https://github.com/iosrxwy/MacAssistant/releases/tag/v1.5.0"
        }
        """#.utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
    }

    func testReleaseNotesSummaryTruncates() throws {
        let release = try JSONDecoder().decode(
            GitHubRelease.self,
            from: releaseJSON(body: "第一行\\n\\n第二行\\n第三行\\n第四行")
        )
        guard case .updateAvailable(let info) =
                UpdateService.evaluate(release: release, currentVersion: "1.0.0") else {
            return XCTFail("应当判定为有更新")
        }
        // 空行被丢掉,前两行原样保留。
        XCTAssertEqual(info.releaseNotesSummary(maxLines: 2), "第一行\n第二行…")
        XCTAssertEqual(info.releaseNotesSummary(maxLines: 99), "第一行\n第二行\n第三行\n第四行")
        XCTAssertEqual(info.releaseNotesSummary(maxLines: 99, maxCharacters: 3), "第一行…")
    }

    // MARK: - HTTP 状态码分类

    /// 仓库还没建 / 还没发过 release 都是 404 —— 这是当前的真实情况,必须当成正常状态。
    func test404IsNoReleasePublishedNotAnError() async throws {
        let (service, _) = makeService(
            transport: transport { (Data(#"{"message":"Not Found"}"#.utf8), self.response(404)) }
        )
        let outcome = try await service.checkForUpdate()
        XCTAssertEqual(outcome, .noReleasePublished)

        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .noRelease)
        XCTAssertEqual(manual.message, "项目暂无发布版本。")
    }

    func test403WithExhaustedRateLimitIsRateLimited() async {
        let (service, _) = makeService(
            transport: transport {
                (Data(#"{"message":"API rate limit exceeded"}"#.utf8),
                 self.response(403, headers: ["X-RateLimit-Remaining": "0",
                                              "X-RateLimit-Limit": "60"]))
            }
        )
        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .failed(.rateLimited))
        XCTAssertEqual(manual.message, "GitHub 接口访问次数已达上限，请稍后再试。")
    }

    func test403WithoutRateLimitHeaderIsForbidden() async {
        let (service, _) = makeService(
            transport: transport {
                (Data(#"{"message":"Forbidden"}"#.utf8),
                 self.response(403, headers: ["X-RateLimit-Remaining": "37"]))
            }
        )
        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .failed(.forbidden))
        XCTAssertEqual(manual.message, "GitHub 拒绝了本次请求（403），请稍后再试。")
    }

    func test429IsRateLimitedEvenWithoutHeader() async {
        let (service, _) = makeService(
            transport: transport { (Data(), self.response(429)) }
        )
        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .failed(.rateLimited))
    }

    func testOtherStatusCodesReportServerError() async {
        let (service, _) = makeService(
            transport: transport { (Data(), self.response(503)) }
        )
        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .failed(.server(status: 503)))
        XCTAssertEqual(manual.message, "GitHub 服务返回异常（HTTP 503），请稍后再试。")
    }

    /// 超时 / DNS 失败 / 无网络 / 代理不通,对用户来说是同一件事。
    func testNetworkFailuresCollapseIntoOneCategory() async {
        let codes: [URLError.Code] = [
            .timedOut, .notConnectedToInternet, .cannotFindHost,
            .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
            .secureConnectionFailed
        ]
        for code in codes {
            let (service, _) = makeService(
                transport: transport { throw URLError(code) }
            )
            let manual = await service.runManualCheck()
            XCTAssertEqual(manual, .failed(.network), "URLError.\(code) 应归为网络类")
            XCTAssertEqual(manual.message, "无法连接 GitHub，请检查网络或代理设置。")
        }
    }

    func testNonHTTPResponseIsTreatedAsNetworkFailure() async {
        let (service, _) = makeService(
            transport: transport {
                (Data(), URLResponse(url: ProductLinks.Repository.latestReleaseAPI,
                                     mimeType: nil,
                                     expectedContentLength: 0,
                                     textEncodingName: nil))
            }
        )
        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .failed(.network))
    }

    func testMalformedJSONIsItsOwnCategory() async {
        let (service, _) = makeService(
            transport: transport { (Data("<html>502 Bad Gateway</html>".utf8), self.response(200)) }
        )
        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .failed(.decoding))
        XCTAssertEqual(manual.message, "GitHub 返回的数据无法解析，可能是接口有变化。")
    }

    func testValidJSONMissingRequiredFieldIsDecodingError() async {
        let (service, _) = makeService(
            transport: transport { (Data(#"{"name":"没有 tag_name"}"#.utf8), self.response(200)) }
        )
        let manual = await service.runManualCheck()
        XCTAssertEqual(manual, .failed(.decoding))
    }

    // MARK: - 是否算「有更新」

    func testNewerReleaseIsOffered() async throws {
        let (service, _) = makeService(
            currentVersion: "1.0.0",
            transport: transport { (self.releaseJSON(tag: "v1.2.0"), self.response(200)) }
        )
        guard case .updateAvailable(let info) = try await service.checkForUpdate() else {
            return XCTFail("应当判定为有更新")
        }
        XCTAssertEqual(info.version, "1.2.0")
        XCTAssertEqual(info.tagName, "v1.2.0")
        XCTAssertEqual(info.releaseURL.absoluteString,
                       "https://github.com/iosrxwy/MacAssistant/releases/tag/v1.2.0")
        XCTAssertEqual(info.title, "v1.2.0 清理与修复增强")
    }

    func testSameVersionIsUpToDate() async throws {
        let (service, _) = makeService(
            currentVersion: "1.2.0",
            transport: transport { (self.releaseJSON(tag: "v1.2.0"), self.response(200)) }
        )
        let outcome = try await service.checkForUpdate()
        XCTAssertEqual(outcome, .upToDate(currentVersion: "1.2.0"))
    }

    func testOlderRemoteReleaseIsNotAnUpdate() async throws {
        let (service, _) = makeService(
            currentVersion: "2.0.0",
            transport: transport { (self.releaseJSON(tag: "v1.9.0"), self.response(200)) }
        )
        let outcome = try await service.checkForUpdate()
        XCTAssertEqual(outcome, .upToDate(currentVersion: "2.0.0"))
    }

    /// 策略:draft 和 prerelease 一律不提示。`releases/latest` 本就不该返回它们,
    /// 真收到了说明状态异常,给 ad-hoc 开发构建推未定稿版本只会添乱。
    func testDraftReleaseIsNeverOffered() async throws {
        let (service, _) = makeService(
            currentVersion: "1.0.0",
            transport: transport { (self.releaseJSON(tag: "v9.9.9", draft: true), self.response(200)) }
        )
        let outcome = try await service.checkForUpdate()
        XCTAssertEqual(outcome, .upToDate(currentVersion: "1.0.0"))
    }

    func testPrereleaseIsNeverOffered() async throws {
        let (service, _) = makeService(
            currentVersion: "1.0.0",
            transport: transport {
                (self.releaseJSON(tag: "v9.9.9", prerelease: true), self.response(200))
            }
        )
        let outcome = try await service.checkForUpdate()
        XCTAssertEqual(outcome, .upToDate(currentVersion: "1.0.0"))
    }

    func testUnparsableTagIsTreatedAsNoUpdate() async throws {
        for tag in ["nightly", "release-2026", "latest"] {
            let (service, _) = makeService(
                currentVersion: "1.0.0",
                transport: transport { (self.releaseJSON(tag: tag), self.response(200)) }
            )
            let outcome = try await service.checkForUpdate()
            XCTAssertEqual(outcome,
                           .upToDate(currentVersion: "1.0.0"),
                           "tag \(tag) 解析不了就不该报有更新")
        }
    }

    // MARK: - 节流(每天最多一次)

    func testAutomaticCheckIsSkippedWithin24Hours() async {
        let defaults = MemoryDefaults()
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (service, preferences) = makeService(
            defaults: defaults,
            transport: transport(log: log) { (self.releaseJSON(), self.response(200)) }
        )
        preferences.lastCheckDate = now.addingTimeInterval(-23 * 60 * 60)

        let decision = await service.runAutomaticCheck(now: now)
        XCTAssertEqual(decision, .silent)
        XCTAssertEqual(log.count, 0, "节流生效时根本不该发请求")
    }

    func testAutomaticCheckRunsAfter24Hours() async {
        let defaults = MemoryDefaults()
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (service, preferences) = makeService(
            defaults: defaults,
            transport: transport(log: log) {
                (self.releaseJSON(tag: "v1.2.0"), self.response(200))
            }
        )
        preferences.lastCheckDate = now.addingTimeInterval(-24 * 60 * 60 - 1)

        let decision = await service.runAutomaticCheck(now: now)
        XCTAssertEqual(log.count, 1)
        guard case .prompt(let info) = decision else { return XCTFail("应当提示更新") }
        XCTAssertEqual(info.version, "1.2.0")
        XCTAssertEqual(preferences.lastCheckDate, now, "检查后要刷新时间戳")
    }

    func testFirstEverCheckIsAlwaysDue() async {
        let defaults = MemoryDefaults()
        let preferences = UpdatePreferences(defaults: defaults)
        XCTAssertNil(preferences.lastCheckDate)
        XCTAssertTrue(preferences.isCheckDue(now: Date()))
    }

    /// 系统时间被往回调过时,不能因为「上次检查在未来」而永远不再检查。
    func testClockMovedBackwardsStillAllowsCheck() {
        let preferences = UpdatePreferences(defaults: MemoryDefaults())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        preferences.lastCheckDate = now.addingTimeInterval(60 * 60 * 24 * 30)
        XCTAssertTrue(preferences.isCheckDue(now: now))
    }

    func testAutomaticCheckRespectsDisabledSwitch() async {
        let defaults = MemoryDefaults()
        let log = RequestLog()
        let (service, preferences) = makeService(
            defaults: defaults,
            transport: transport(log: log) { (self.releaseJSON(), self.response(200)) }
        )
        XCTAssertTrue(preferences.automaticCheckEnabled, "默认应当开启")
        preferences.automaticCheckEnabled = false

        let decision = await service.runAutomaticCheck()
        XCTAssertEqual(decision, .silent)
        XCTAssertEqual(log.count, 0)
    }

    /// 自动检查必须静默失败:任何错误都不能变成弹窗。
    func testAutomaticCheckFailsSilently() async {
        let failures: [() throws -> (Data, URLResponse)] = [
            { throw URLError(.notConnectedToInternet) },
            { (Data(), self.response(403, headers: ["X-RateLimit-Remaining": "0"])) },
            { (Data("not json".utf8), self.response(200)) },
            { (Data(), self.response(500)) }
        ]
        for failure in failures {
            let (service, _) = makeService(defaults: MemoryDefaults(),
                                           transport: transport(failure))
            let decision = await service.runAutomaticCheck()
            XCTAssertEqual(decision, .silent)
        }
    }

    /// 离线时也要把额度算掉,否则每次启动都白等一轮超时。
    func testAutomaticCheckRecordsTimestampEvenWhenItFails() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (service, preferences) = makeService(
            defaults: MemoryDefaults(),
            transport: transport { throw URLError(.timedOut) }
        )
        let decision = await service.runAutomaticCheck(now: now)
        XCTAssertEqual(decision, .silent)
        XCTAssertEqual(preferences.lastCheckDate, now)
        XCTAssertFalse(preferences.isCheckDue(now: now))
    }

    func test404DoesNotProduceAnAutomaticPrompt() async {
        let (service, _) = makeService(
            transport: transport { (Data(#"{"message":"Not Found"}"#.utf8), self.response(404)) }
        )
        let decision = await service.runAutomaticCheck()
        XCTAssertEqual(decision, .silent)
    }

    // MARK: - 跳过此版本

    func testSkippedVersionIsNoLongerPrompted() async {
        let defaults = MemoryDefaults()
        let (service, preferences) = makeService(
            currentVersion: "1.0.0",
            defaults: defaults,
            transport: transport { (self.releaseJSON(tag: "v1.2.0"), self.response(200)) }
        )
        guard case .prompt(let info) = await service.runAutomaticCheck(now: Date()) else {
            return XCTFail("第一次应当提示")
        }
        preferences.skip(info)
        XCTAssertEqual(preferences.skippedVersion, "1.2.0")

        // 换一天再检查,同一个版本不该再弹。
        let later = Date().addingTimeInterval(48 * 60 * 60)
        let decision = await service.runAutomaticCheck(now: later)
        XCTAssertEqual(decision, .silent)
    }

    func testHigherVersionIsStillPromptedAfterSkip() async {
        let defaults = MemoryDefaults()
        let preferences = UpdatePreferences(defaults: defaults)
        preferences.skippedVersion = "1.2.0"

        let (service, _) = makeService(
            currentVersion: "1.0.0",
            defaults: defaults,
            transport: transport { (self.releaseJSON(tag: "v1.3.0"), self.response(200)) }
        )
        guard case .prompt(let info) = await service.runAutomaticCheck() else {
            return XCTFail("更高的版本仍然要提示")
        }
        XCTAssertEqual(info.version, "1.3.0")
    }

    /// 跳过记录存的是规范化版本号,`v1.2.0` 和 `1.2` 都能对上。
    func testSkipMatchingIsFormatInsensitive() {
        let preferences = UpdatePreferences(defaults: MemoryDefaults())
        preferences.skippedVersion = "1.2.0"

        func info(_ version: String) -> UpdateInfo {
            UpdateInfo(version: version,
                       tagName: "v" + version,
                       releaseURL: ProductLinks.Repository.releasesPage,
                       title: "t",
                       releaseNotes: "",
                       publishedAt: nil)
        }
        XCTAssertFalse(preferences.shouldPrompt(for: info("1.2.0")))
        XCTAssertFalse(preferences.shouldPrompt(for: info("1.2")))
        XCTAssertFalse(preferences.shouldPrompt(for: info("1.1.0")))
        XCTAssertTrue(preferences.shouldPrompt(for: info("1.2.1")))
        XCTAssertTrue(preferences.shouldPrompt(for: info("1.10.0")))

        preferences.clearSkippedVersion()
        XCTAssertNil(preferences.skippedVersion)
        XCTAssertTrue(preferences.shouldPrompt(for: info("1.2.0")))
    }

    // MARK: - 手动检查

    /// 手动检查是用户主动发起的,节流和「已跳过」都不该拦它。
    func testManualCheckIgnoresThrottleAndSkipList() async {
        let defaults = MemoryDefaults()
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (service, preferences) = makeService(
            currentVersion: "1.0.0",
            defaults: defaults,
            transport: transport(log: log) {
                (self.releaseJSON(tag: "v1.2.0"), self.response(200))
            }
        )
        preferences.lastCheckDate = now.addingTimeInterval(-60)
        preferences.skippedVersion = "1.2.0"

        let result = await service.runManualCheck(now: now)
        XCTAssertEqual(log.count, 1, "手动检查必须真的发请求")
        guard case .updateAvailable(let info) = result else {
            return XCTFail("手动检查应当如实报告有新版本")
        }
        XCTAssertEqual(info.version, "1.2.0")
        XCTAssertEqual(result.message, "发现新版本 1.2.0，可前往 GitHub 查看。")
    }

    func testManualCheckUpToDateMessage() async {
        let (service, _) = makeService(
            currentVersion: "1.2.0",
            transport: transport { (self.releaseJSON(tag: "v1.2.0"), self.response(200)) }
        )
        let result = await service.runManualCheck()
        XCTAssertEqual(result, .upToDate(currentVersion: "1.2.0"))
        XCTAssertEqual(result.message, "已是最新版本（1.2.0）。")
    }

    /// 每一类失败都要有自己的中文文案,不能糊成一句「失败」。
    func testEveryErrorHasItsOwnChineseMessage() {
        let errors: [UpdateCheckError] = [
            .network, .rateLimited, .forbidden, .decoding, .server(status: 500)
        ]
        let messages = errors.map(\.message)
        XCTAssertEqual(Set(messages).count, errors.count, "文案不能重复")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.contains(where: { $0.unicodeScalars.contains { $0.value > 0x4E00 } }),
                          "应当是中文文案: \(message)")
        }
    }
}
