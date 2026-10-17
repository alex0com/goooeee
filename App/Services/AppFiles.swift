import AppKit
import GoooeeeCore

/// Every place goooeee keeps something on this Mac, for Help → Files & Data.
///
/// The app isn't sandboxed, so these are the real folders in your home folder, not a container.
/// goooeee installs nothing outside its own app bundle: no helpers, login items, command-line
/// tools or system extensions.
enum AppFiles {
    struct Location: Identifiable {
        enum Kind {
            case folder
            case file
            /// The database and its `-wal` and `-shm` companions.
            case database
            case keychain
        }

        var id: String { title }
        var title: String
        var url: URL?
        var kind: Kind
        var contents: String
        var removal: String
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "local.goooeee.app" }

    /// The Keychain service of API keys and MCP secrets (see `KeychainSecretStore`).
    static let keychainService = "goooeee"

    static var library: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    }

    static var database: URL { AppDatabase.defaultURL }
    static var preferences: URL { library.appendingPathComponent("Preferences/\(bundleID).plist") }
    static var caches: URL { library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true) }
    static var httpStorage: URL { library.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true) }
    static var savedState: URL { library.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true) }
    static var crashReports: URL { library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true) }
    static var openedAttachments: URL { FileManager.default.temporaryDirectory.appendingPathComponent("goooeee-attachments", isDirectory: true) }
    /// Written by test builds whose code blocks had a Run button.
    static var oldScripts: URL { FileManager.default.temporaryDirectory.appendingPathComponent("goooeee-scripts", isDirectory: true) }
    static var builtInProfiles: URL? {
        Bundle.main.url(forResource: "GoooeeeKit_GoooeeeCore", withExtension: "bundle")
            .map { $0.appendingPathComponent("model-profiles.json") }
    }

    static var locations: [Location] {
        var list: [Location] = [
            Location(
                title: "The app",
                url: Bundle.main.bundleURL,
                kind: .folder,
                contents: "goooeee itself, with its built-in model profiles and libraries. Nothing is installed anywhere else.",
                removal: "Quit goooeee and move it to the Trash."
            ),
            Location(
                title: "Database",
                url: database,
                kind: .database,
                contents: "Workspaces, connections (without API keys), chats and messages with their attachments, the search index, MCP servers, your model profiles, tool permissions, the tool call log and Recently Deleted chats.",
                removal: "Deleting it removes all chats, workspaces and connections. Quit goooeee first, and copy it if you want a backup."
            ),
            Location(
                title: "Settings",
                url: preferences,
                kind: .file,
                contents: "Everything in goooeee → Settings, plus window sizes and positions.",
                removal: "Use Settings → Advanced → Reset All Settings, or `defaults delete \(bundleID)` with goooeee quit. Don't edit the file directly."
            ),
            Location(
                title: "API keys and secrets",
                url: nil,
                kind: .keychain,
                contents: "Connection API keys and MCP server secrets, in your login keychain as passwords with the name “\(keychainService)”.",
                removal: "Delete them in Keychain Access (search for “\(keychainService)”), or remove a connection's key in its General tab."
            ),
            Location(
                title: "Network cache",
                url: caches,
                kind: .folder,
                contents: "Responses cached by macOS for goooeee's network requests.",
                removal: "Safe to delete at any time."
            ),
            Location(
                title: "Network storage",
                url: httpStorage,
                kind: .folder,
                contents: "Cookies and similar data macOS keeps for goooeee's network requests.",
                removal: "Safe to delete with goooeee quit."
            ),
            Location(
                title: "Open windows",
                url: savedState,
                kind: .folder,
                contents: "Which workspace windows were open, so macOS can reopen them.",
                removal: "Safe to delete with goooeee quit; windows then don't reopen."
            ),
            Location(
                title: "Opened attachments",
                url: openedAttachments,
                kind: .folder,
                contents: "Copies of attachments you opened from a chat in another app.",
                removal: "Safe to delete. macOS also empties temporary folders on its own."
            ),
            Location(
                title: "Crash reports",
                url: crashReports,
                kind: .folder,
                contents: "Written by macOS if goooeee crashes, named goooeee-<date>.ips. Useful when reporting a problem.",
                removal: "Safe to delete the goooeee-*.ips files."
            ),
        ]
        if FileManager.default.fileExists(atPath: oldScripts.path) {
            list.append(Location(
                title: "Old scripts",
                url: oldScripts,
                kind: .folder,
                contents: "Code blocks run by an earlier test build of goooeee. This version doesn't write here.",
                removal: "Safe to delete."
            ))
        }
        return list
    }

    /// The files a location covers (the database has two companions).
    static func files(of location: Location) -> [URL] {
        guard let url = location.url else { return [] }
        if location.kind == .database {
            return [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        }
        if url == crashReports {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { $0.hasPrefix("goooeee") && $0.hasSuffix(".ips") }.map { url.appendingPathComponent($0) }
        }
        return [url]
    }

    /// Bytes on disk, or `nil` when nothing exists there yet. Walks folders, so call it off the main actor.
    nonisolated static func size(of urls: [URL]) -> Int64? {
        let manager = FileManager.default
        var total: Int64 = 0
        var found = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            found = true
            if !isDirectory.boolValue {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                continue
            }
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return found ? total : nil
    }

    static func reveal(_ location: Location) {
        guard let url = location.url else { return }
        let existing = files(of: location).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty, url != crashReports || existing.count < 20 {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        } else {
            // Not created yet: show the nearest folder that exists.
            var folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
                folder.deleteLastPathComponent()
            }
            NSWorkspace.shared.open(folder)
        }
    }

    static var keychainAccess: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess")
    }

    /// `~/Library/…` instead of `/Users/name/Library/…`.
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Commands

    private static func quoted(_ url: URL) -> String {
        "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Copies the database to a dated folder on the Desktop. goooeee has to be quit first.
    static var backupCommands: String {
        let folder = database.deletingLastPathComponent()
        return """
            backup=~/Desktop/goooeee-backup-$(date +%Y-%m-%d)
            mkdir -p "$backup"
            cp \(quoted(folder))/goooeee.sqlite* "$backup"/
            """
    }

    /// Removes everything goooeee stored, except the app and files you saved yourself.
    static var uninstallCommands: String {
        let folder = database.deletingLastPathComponent()
        return """
            defaults delete \(bundleID)
            rm -f \(quoted(folder))/goooeee.sqlite \(quoted(folder))/goooeee.sqlite-wal \(quoted(folder))/goooeee.sqlite-shm
            rmdir \(quoted(folder)) 2>/dev/null
            rm -rf \(quoted(caches)) \(quoted(httpStorage)) \(quoted(savedState)) \(quoted(openedAttachments)) \(quoted(oldScripts))
            rm -f \(quoted(crashReports))/goooeee-*.ips
            while security delete-generic-password -s \(keychainService) >/dev/null 2>&1; do :; done
            """
    }
}
