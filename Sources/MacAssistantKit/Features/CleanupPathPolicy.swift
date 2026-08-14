import Foundation
import Darwin

public enum CleanupPathError: LocalizedError, Equatable {
    case invalidURL
    case outsideHome
    case outsideAllowedRoots
    case protectedRoot
    case missing
    case permissionDenied
    case symbolicLink
    case changedSinceScan

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return L("cleanup.path.error.invalid-url")
        case .outsideHome: return L("cleanup.path.error.outside-home")
        case .outsideAllowedRoots: return L("cleanup.path.error.outside-allowed-roots")
        case .protectedRoot: return L("cleanup.path.error.protected-root")
        case .missing: return L("cleanup.path.error.missing")
        case .permissionDenied: return L("cleanup.path.error.permission-denied")
        case .symbolicLink: return L("cleanup.path.error.symbolic-link")
        case .changedSinceScan: return L("cleanup.path.error.changed-since-scan")
        }
    }
}

/// 清理文件的唯一边界守卫：限定 home/允许根，拒绝 symlink，并以 dev+inode 复核 TOCTOU。
/// home 与允许根的 canonical 形式在构造时计算一次；validate 每次只需解析待检路径本身。
public struct CleanupPathPolicy: Sendable {
    public let homeDirectory: URL
    public let allowedRoots: [URL]

    private let homeComponents: [String]
    private let canonicalHome: URL
    private let canonicalHomeComponents: [String]
    private let allowedRootComponents: [[String]]
    private let canonicalRootComponents: [[String]]

    public init(homeDirectory: URL, allowedRoots: [URL]) {
        let home = homeDirectory.standardizedFileURL
        self.homeDirectory = home
        self.allowedRoots = allowedRoots.map(\.standardizedFileURL)
        homeComponents = home.pathComponents
        canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL
        canonicalHomeComponents = canonicalHome.pathComponents
        allowedRootComponents = self.allowedRoots.map(\.pathComponents)
        canonicalRootComponents = self.allowedRoots.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        }
    }

    public func validate(_ url: URL) throws -> CleanupValidatedPath {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw CleanupPathError.invalidURL
        }

        let requested = url.standardizedFileURL
        let requestedComponents = requested.pathComponents
        guard requestedComponents != homeComponents else {
            throw CleanupPathError.protectedRoot
        }
        guard isDescendantOrEqual(requestedComponents, of: homeComponents) else {
            throw CleanupPathError.outsideHome
        }
        guard allowedRootComponents.contains(where: {
            isDescendantOrEqual(requestedComponents, of: $0)
        }) else {
            throw CleanupPathError.outsideAllowedRoots
        }

        let fileInfo = try identity(at: requested)
        guard !fileInfo.isSymbolicLink else {
            throw CleanupPathError.symbolicLink
        }

        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        let canonicalComponents = canonical.pathComponents
        guard canonicalComponents != canonicalHomeComponents,
              isDescendantOrEqual(canonicalComponents, of: canonicalHomeComponents)
        else {
            throw CleanupPathError.outsideHome
        }
        guard canonicalRootComponents.contains(where: {
            isDescendantOrEqual(canonicalComponents, of: $0)
        }) else {
            throw CleanupPathError.outsideAllowedRoots
        }

        return CleanupValidatedPath(
            requestedURL: requested,
            canonicalURL: canonical,
            identity: fileInfo.identity,
            isDirectory: fileInfo.isDirectory
        )
    }

    public func revalidate(_ path: CleanupValidatedPath) throws {
        let current = try validate(path.requestedURL)
        guard current.canonicalURL == path.canonicalURL,
              current.identity == path.identity,
              current.isDirectory == path.isDirectory
        else {
            throw CleanupPathError.changedSinceScan
        }
    }

    public func isReadable(_ path: CleanupValidatedPath) -> Bool {
        FileManager.default.isReadableFile(atPath: path.canonicalURL.path)
    }

    public func isWritable(_ path: CleanupValidatedPath) -> Bool {
        FileManager.default.isWritableFile(atPath: path.canonicalURL.path)
    }

    public func contains(_ child: CleanupValidatedPath, within root: CleanupValidatedPath) -> Bool {
        child.requestedURL != root.requestedURL
            && isDescendantOrEqual(child.requestedURL, of: root.requestedURL)
            && isDescendantOrEqual(child.canonicalURL, of: root.canonicalURL)
    }

    private func identity(
        at url: URL
    ) throws -> (identity: CleanupFileIdentity, isDirectory: Bool, isSymbolicLink: Bool) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR:
                throw CleanupPathError.missing
            case EACCES, EPERM:
                throw CleanupPathError.permissionDenied
            default:
                throw CleanupPathError.permissionDenied
            }
        }

        let kind = info.st_mode & mode_t(S_IFMT)
        return (
            CleanupFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)),
            kind == mode_t(S_IFDIR),
            kind == mode_t(S_IFLNK)
        )
    }

    private func isDescendantOrEqual(_ candidate: URL, of root: URL) -> Bool {
        isDescendantOrEqual(
            candidate.standardizedFileURL.pathComponents,
            of: root.standardizedFileURL.pathComponents
        )
    }

    private func isDescendantOrEqual(_ candidate: [String], of root: [String]) -> Bool {
        guard candidate.count >= root.count else { return false }
        return candidate.starts(with: root)
    }
}
