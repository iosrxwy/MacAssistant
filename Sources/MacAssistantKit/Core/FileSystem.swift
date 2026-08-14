import Foundation

/// 文件系统相关的通用工具。
public enum FileSystemHelper {

    /// 在系统临时目录下创建一个带前缀的唯一工作目录。
    public static func makeTemporaryDirectory(prefix: String = "MacAssistant") throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    public static func uniqueOutputURL(basedOn proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let directory = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        for index in 2...10_000 {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }

    public static func withSecurityScopedAccess<T>(
        to urls: [URL],
        _ body: () throws -> T
    ) rethrows -> T {
        let uniqueURLs = Array(Set(urls))
        let accessed = uniqueURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// 把沙盒/TCC 的笼统错误转成包含具体路径和系统设置入口的提示。
    public static func userFacingAccessError(_ error: Error, paths: [URL]) -> String {
        let listedPaths = Array(Set(paths.map(\.standardizedFileURL.path))).sorted()
            .map { "• \($0)" }
            .joined(separator: "\n")
        let prefix = listedPaths.isEmpty ? "" : L("fs.access.pathsPrefix", listedPaths)
        return prefix
            + L("fs.access.selectedFilesEnough")
            + L("fs.access.systemSettingsHint")
            + L("fs.access.fullDiskAccessNote")
            + L("fs.access.underlyingError", error.localizedDescription)
    }

    public static func isAccessPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            let permissionCodes: Set<Int> = [
                CocoaError.fileReadNoPermission.rawValue,
                CocoaError.fileWriteNoPermission.rawValue
            ]
            if permissionCodes.contains(nsError.code) { return true }
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("permission denied") || message.contains("operation not permitted")
    }

    /// 递归计算目录或文件占用的字节数。
    public static func size(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
        }

        var total: Int64 = 0
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// 人类可读的容量字符串,如 "1.2 GB"。
    public static func humanReadableSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        // 关掉 "Zero KB" 这类非数值写法，界面上要的是能和其他行对齐的数字。
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// 判断路径是否为目录。
    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 在目录中递归查找符合条件的第一个文件。
    public static func firstFile(in directory: URL, where predicate: (URL) -> Bool) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where predicate(url) {
            return url
        }
        return nil
    }

    /// 递归查找目录下所有满足条件的文件。
    public static func allFiles(in directory: URL, where predicate: (URL) -> Bool) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator where predicate(url) {
            result.append(url)
        }
        return result
    }
}
