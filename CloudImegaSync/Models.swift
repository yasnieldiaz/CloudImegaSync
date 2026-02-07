import Foundation

// MARK: - Sync Status
enum SyncStatus: Equatable {
    case idle
    case syncing
    case paused
    case error(String)
    case offline

    var icon: String {
        switch self {
        case .idle: return "cloud.fill"
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        }
    }

    var description: String {
        switch self {
        case .idle: return "Sincronizado"
        case .syncing: return "Sincronizando..."
        case .paused: return "Pausado"
        case .error(let msg): return "Error: \(msg)"
        case .offline: return "Sin conexion"
        }
    }

    var color: String {
        switch self {
        case .idle: return "green"
        case .syncing: return "blue"
        case .paused: return "orange"
        case .error: return "red"
        case .offline: return "gray"
        }
    }
}

// MARK: - API Models
struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

struct User: Codable, Identifiable {
    let id: String
    let email: String
    let name: String
    let storageUsed: Int64
    let storageQuota: Int64
    let isAdmin: Bool
    let createdAt: String
}

struct CloudFile: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    let mimeType: String?
    let checksum: String?
    let folder_id: String?
    let isFavorite: Bool
    let createdAt: String
    let updatedAt: String
}

struct CloudFolder: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let parentID: String?
    let isFavorite: Bool
    let createdAt: String
    let updatedAt: String
}

struct FolderContents: Codable {
    let folder: CloudFolder
    let files: [CloudFile]
    let subfolders: [CloudFolder]
}

struct FilesResponse: Codable {
    let items: [CloudFile]
    let metadata: PaginationMetadata
}

struct PaginationMetadata: Codable {
    let page: Int
    let per: Int
    let total: Int
}

// MARK: - Local Sync State
struct SyncState: Codable {
    var lastSyncDate: Date?
    var syncedFiles: [String: SyncedFileInfo] // localPath -> info

    init() {
        self.lastSyncDate = nil
        self.syncedFiles = [:]
    }
}

struct SyncedFileInfo: Codable {
    let cloudID: String
    let localPath: String
    let checksum: String
    let lastModified: Date
    let size: Int64
}

// MARK: - Sync Activity
struct SyncActivity: Identifiable {
    let id = UUID()
    let type: ActivityType
    let fileName: String
    let timestamp: Date

    enum ActivityType {
        case uploaded
        case downloaded
        case deleted
        case error(String)

        var icon: String {
            switch self {
            case .uploaded: return "arrow.up.circle.fill"
            case .downloaded: return "arrow.down.circle.fill"
            case .deleted: return "trash.circle.fill"
            case .error: return "exclamationmark.circle.fill"
            }
        }
    }
}
