import Foundation

extension BoardSession {
    /// Read a fresh mount snapshot and requested directories in one serial job.
    /// Filesystem failures remain explicit per directory, never an empty success.
    func refreshDirectories(paths: [String]) throws -> FileTreeRefresh {
        let available = try volumes()
        var requested = Set(available.map(\.path))
        for path in paths {
            // /sd is an optional mount: never revisit a stale SD branch when
            // discovery has just reported that mount as absent/unavailable.
            if (path == "/sd" || path.hasPrefix("/sd/")), !available.contains(where: { $0.path == "/sd" }) { continue }
            guard let volume = available.sorted(by: { $0.path.count > $1.path.count }).first(where: {
                $0.path == "/" || path == $0.path || path.hasPrefix($0.path + "/")
            }) else { continue }
            var current = path
            while current != volume.path && current != "/" && !current.isEmpty {
                requested.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
            requested.insert(volume.path)
        }
        let ordered = requested.sorted {
            let left = $0.split(separator: "/").count, right = $1.split(separator: "/").count
            return left != right ? left < right : $0 < $1
        }
        var directories: [String: Result<[RemoteEntry], Error>] = [:]
        for path in ordered {
            let parent = (path as NSString).deletingLastPathComponent
            if let parentResult = directories[parent] {
                switch parentResult {
                case .failure(let error):
                    directories[path] = .failure(error)
                    continue
                case .success(let entries):
                    if !available.contains(where: { $0.path == path }) && !entries.contains(where: { $0.path == path && $0.isDirectory }) {
                        directories[path] = .failure(M5Error.filesystem(path: path, code: 2))
                        continue
                    }
                }
            }
            do { directories[path] = .success(try list(path: path)) }
            catch let error as M5Error {
                // Only an actual filesystem failure permits continuing with
                // another mount. A broken serial protocol is not a partial tree.
                guard case .filesystem = error else { throw error }
                directories[path] = .failure(error)
            }
        }
        return FileTreeRefresh(volumes: available, directories: directories)
    }
}
