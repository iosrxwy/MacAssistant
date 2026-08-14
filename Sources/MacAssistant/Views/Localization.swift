import Foundation
import MacAssistantKit

/// App target 的字符串查表入口，命中的是 `Sources/MacAssistant/Localization/*.lproj`。
/// Kit 层有同名函数查自己的表，两张表互不干扰。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    MALocalizedString(key, arguments: arguments, bundle: .module)
}

func L(_ key: String, arguments: [CVarArg]) -> String {
    MALocalizedString(key, arguments: arguments, bundle: .module)
}
