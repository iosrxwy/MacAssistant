public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard, menuBar, repair, cleanup, appUninstall, desktopIcons, appClone, memory, network, cheatsheet, recipes
    case deb, dylib, ipa, macApp, binary
    case environment, about, opensource

    public var id: String { rawValue }

    public var title: String {
        L("sidebar.\(rawValue)")
    }

    public var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .menuBar: return "wifi"
        case .repair: return "bandage"
        case .cleanup: return "trash"
        case .appUninstall: return "xmark.app"
        case .desktopIcons: return "paintpalette"
        case .appClone: return "rectangle.on.rectangle"
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
        case .opensource: return "scalemass"
        }
    }

    public var destination: AppDestination {
        switch self {
        case .dashboard: return .dashboard
        case .menuBar: return .menuBar
        case .repair: return .repair
        case .cleanup: return .cleanup
        case .appUninstall: return .appUninstall
        case .desktopIcons: return .desktopIcons
        case .appClone: return .appClone
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
        case .opensource: return .opensource
        }
    }
}

public enum AppDestination: String, CaseIterable, Hashable, Sendable {
    case dashboard, menuBar, repair, cleanup, appUninstall, desktopIcons, appClone, memory, network, cheatsheet, recipes
    case deb, dylib, ipa, macApp, binary
    case environment, about, opensource

    public var sidebarItem: SidebarItem {
        switch self {
        case .dashboard: return .dashboard
        case .menuBar: return .menuBar
        case .repair: return .repair
        case .cleanup: return .cleanup
        case .appUninstall: return .appUninstall
        case .desktopIcons: return .desktopIcons
        case .appClone: return .appClone
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
        case .opensource: return .opensource
        }
    }
}
