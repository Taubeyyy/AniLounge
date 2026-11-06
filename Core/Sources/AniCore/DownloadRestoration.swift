import Foundation

/// Missing tasks can only be identified after every background session answered.
public struct DownloadRestoration {
    private var pendingSessions: Set<String>
    private let originalDownloads: Set<UUID>
    private var restoredDownloads: Set<UUID> = []
    public init(sessionIDs: Set<String>, downloadIDs: Set<UUID>) {
        pendingSessions = sessionIDs; originalDownloads = downloadIDs
    }
    /// nil means other sessions are still outstanding (or this is a duplicate callback).
    public mutating func received(sessionID: String, downloadIDs: Set<UUID>) -> Set<UUID>? {
        guard pendingSessions.remove(sessionID) != nil else { return nil }
        restoredDownloads.formUnion(downloadIDs)
        return pendingSessions.isEmpty ? originalDownloads.subtracting(restoredDownloads) : nil
    }
}
