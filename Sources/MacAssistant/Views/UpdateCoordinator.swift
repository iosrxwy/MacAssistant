import AppKit
import Foundation
import SwiftUI
import MacAssistantKit

/// 「检查更新」的界面状态机。逻辑都在 `MacAssistantKit.UpdateService` 里,这里只负责
/// 把结果翻译成弹窗和「关于」页上的文案。
@MainActor
final class UpdateCoordinator: ObservableObject {

    enum ManualState: Equatable {
        case idle
        case checking
        case finished(String)
    }

    /// 非 nil 时展示更新弹窗。
    @Published private(set) var pendingUpdate: UpdateInfo?
    @Published private(set) var manualState: ManualState = .idle
    @Published var automaticCheckEnabled: Bool {
        didSet { preferences.automaticCheckEnabled = automaticCheckEnabled }
    }

    let currentVersion: String
    private let preferences: UpdatePreferences
    private let service: UpdateService

    init(preferences: UpdatePreferences = UpdatePreferences()) {
        let version = AppVersionSource.current
        self.currentVersion = version
        self.preferences = preferences
        self.service = UpdateService(currentVersion: version, preferences: preferences)
        self.automaticCheckEnabled = preferences.automaticCheckEnabled
    }

    var isChecking: Bool { manualState == .checking }

    /// 弹窗的 `isPresented` 绑定;用户点任意按钮或按 Esc 都会把它置回 false。
    var isShowingUpdateAlert: Bool {
        get { pendingUpdate != nil }
        set { if !newValue { pendingUpdate = nil } }
    }

    var statusText: String {
        switch manualState {
        case .idle:
            return automaticCheckEnabled
                ? "自动检查每天最多一次，也可以随时手动检查。"
                : "自动检查已关闭，可随时手动检查。"
        case .checking:
            return "正在检查…"
        case .finished(let message):
            return message
        }
    }

    /// 启动时调用。整个过程异步,失败静默,不阻塞界面。
    func runAutomaticCheckIfDue() async {
        guard !Self.isDisabledByEnvironment else { return }
        guard case .prompt(let info) = await service.runAutomaticCheck() else { return }
        pendingUpdate = info
    }

    func runManualCheck() async {
        guard !isChecking else { return }
        manualState = .checking
        let result = await service.runManualCheck()
        manualState = .finished(result.message)
        if case .updateAvailable(let info) = result {
            pendingUpdate = info
        }
    }

    func alertMessage(for info: UpdateInfo) -> String {
        var lines = ["当前版本 \(currentVersion)，最新版本 \(info.version)。"]
        let summary = info.releaseNotesSummary()
        if !summary.isEmpty { lines.append(summary) }
        return lines.joined(separator: "\n\n")
    }

    func openPendingRelease() {
        if let pendingUpdate { NSWorkspace.shared.open(pendingUpdate.releaseURL) }
        pendingUpdate = nil
    }

    /// 记住这个版本号,之后不再为它自动弹窗;更高的版本仍然会提示。
    func skipPendingVersion() {
        if let pendingUpdate { preferences.skip(pendingUpdate) }
        self.pendingUpdate = nil
    }

    func remindLater() {
        pendingUpdate = nil
    }

    /// 图标探测和自动化测试不该打网络。
    private static var isDisabledByEnvironment: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["MACASSISTANT_ICON_PROBE"] == "1"
            || environment["MACASSISTANT_DISABLE_UPDATE_CHECK"] == "1"
    }
}
