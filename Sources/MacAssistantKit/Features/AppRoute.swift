public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard, repair, cleanup, memory, network, cheatsheet, recipes
    case deb, dylib, ipa, macApp, binary
    case environment, about

    public var id: String { rawValue }

    public var title: String {
        L("sidebar.\(rawValue)")
    }

    /// 逆向类工具仍处于 Beta 阶段,侧栏用小标签标注(不写进标题)。
    public var isBeta: Bool {
        switch self {
        case .deb, .dylib, .ipa, .macApp, .binary: return true
        default: return false
        }
    }

    public var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .repair: return "bandage"
        case .cleanup: return "trash"
        case .memory: return "memorychip"
        case .network: return "network"
        case .cheatsheet: return "terminal"
        case .recipes: return "switch.2"
        case .deb: return "shippingbox"
        case .dylib: return "link"
        case .ipa: return "syringe"
        case .macApp: return "macwindow"
        case .binary: return "cpu"
        case .environment: return "checklist"
        case .about: return "info.circle"
        }
    }

    public var destination: AppDestination {
        switch self {
        case .dashboard: return .dashboard
        case .repair: return .repair
        case .cleanup: return .cleanup
        case .memory: return .memory
        case .network: return .network
        case .cheatsheet: return .cheatsheet
        case .recipes: return .recipes
        case .deb: return .deb
        case .dylib: return .dylib
        case .ipa: return .ipa
        case .macApp: return .macApp
        case .binary: return .binary
        case .environment: return .environment
        case .about: return .about
        }
    }
}

public enum AppDestination: String, CaseIterable, Hashable, Sendable {
    case dashboard, repair, cleanup, memory, network, cheatsheet, recipes
    case deb, dylib, ipa, macApp, binary
    case environment, about

    public var sidebarItem: SidebarItem {
        switch self {
        case .dashboard: return .dashboard
        case .repair: return .repair
        case .cleanup: return .cleanup
        case .memory: return .memory
        case .network: return .network
        case .cheatsheet: return .cheatsheet
        case .recipes: return .recipes
        case .deb: return .deb
        case .dylib: return .dylib
        case .ipa: return .ipa
        case .macApp: return .macApp
        case .binary: return .binary
        case .environment: return .environment
        case .about: return .about
        }
    }
}
