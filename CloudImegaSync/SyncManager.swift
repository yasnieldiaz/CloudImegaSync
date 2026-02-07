import Foundation
import SwiftUI
import Combine

@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @AppStorage("syncFolderPath") var syncFolderPath: String = ""
    @AppStorage("autoSync") var autoSync: Bool = true
    @AppStorage("syncInterval") var syncInterval: Int = 300 // 5 minutes

    @Published var syncStatus: SyncStatus = .idle
    @Published var uploadingCount: Int = 0
    @Published var downloadingCount: Int = 0
    @Published var syncedFilesCount: Int = 0
    @Published var recentActivities: [SyncActivity] = []

    private var syncState: SyncState
    private var fileWatcher: FileWatcher?
    private var syncTimer: Timer?
    private let stateFileURL: URL

    private init() {
        // Initialize sync state file
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("CloudImegaSync")
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        stateFileURL = appFolder.appendingPathComponent("sync_state.json")

        // Load existing state
        if let data = try? Data(contentsOf: stateFileURL),
           let state = try? JSONDecoder().decode(SyncState.self, from: data) {
            syncState = state
            syncedFilesCount = state.syncedFiles.count
        } else {
            syncState = SyncState()
        }

        // Set default sync folder in Documents
        if syncFolderPath.isEmpty {
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            syncFolderPath = documentsDir.appendingPathComponent("CloudImega").path
        }

        // Create sync folder if needed
        createSyncFolderIfNeeded()

        // Start watching for file changes
        startFileWatcher()

        // Start auto sync timer if enabled
        if autoSync {
            startAutoSync()
        }
    }

    // MARK: - Public Methods

    func setSyncFolder(_ path: String) {
        syncFolderPath = path
        createSyncFolderIfNeeded()
        startFileWatcher()
    }

    func syncNow() async {
        guard syncStatus != .syncing else { return }
        guard APIClient.shared.isAuthenticated else {
            syncStatus = .error("No autenticado")
            return
        }

        syncStatus = .syncing

        do {
            // 1. Get root folder and sync recursively
            let rootFolder = try await APIClient.shared.getRootFolder()
            try await syncFolder(rootFolder, localPath: syncFolderPath)

            syncStatus = .idle
            syncState.lastSyncDate = Date()
            saveState()

        } catch {
            syncStatus = .error(error.localizedDescription)
            addActivity(.error(error.localizedDescription), fileName: "Sync")
        }
    }

    private func syncFolder(_ contents: FolderContents, localPath: String) async throws {
        let fm = FileManager.default

        // Create local folder if needed
        if !fm.fileExists(atPath: localPath) {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
        }

        // Build a map of remote folders by name
        let remoteFoldersByName = Dictionary(uniqueKeysWithValues: contents.folders.map { ($0.name, $0) })

        // Sync subfolders recursively
        for folder in contents.folders {
            let subfolderPath = (localPath as NSString).appendingPathComponent(folder.name)
            let subfolderContents = try await APIClient.shared.getFolder(id: folder.id)
            try await syncFolder(subfolderContents, localPath: subfolderPath)
        }

        // Sync files in this folder
        for remoteFile in contents.files {
            let localFilePath = (localPath as NSString).appendingPathComponent(remoteFile.name)

            // Download if doesn't exist locally
            if !fm.fileExists(atPath: localFilePath) {
                await downloadFile(remoteFile, to: localFilePath)
            }
        }

        // Check for local items to upload/create
        if let localContents = try? fm.contentsOfDirectory(atPath: localPath) {
            for item in localContents {
                // Skip hidden files
                if item.hasPrefix(".") { continue }

                let itemPath = (localPath as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: itemPath, isDirectory: &isDir)

                if isDir.boolValue {
                    // It's a folder - check if exists on server
                    if let existingFolder = remoteFoldersByName[item] {
                        // Folder exists, sync its contents
                        let subfolderContents = try await APIClient.shared.getFolder(id: existingFolder.id)
                        try await syncFolder(subfolderContents, localPath: itemPath)
                    } else {
                        // Create folder on server and sync its contents
                        let newFolder = try await APIClient.shared.createFolder(name: item, parentId: contents.folder.id)
                        addActivity(.uploaded, fileName: "📁 \(item)")
                        // Sync the new folder's contents
                        let newFolderContents = try await APIClient.shared.getFolder(id: newFolder.id)
                        try await syncFolder(newFolderContents, localPath: itemPath)
                    }
                } else {
                    // It's a file - check if exists on server
                    let existsOnServer = contents.files.contains { $0.name == item }
                    if !existsOnServer {
                        // Upload new local file
                        await uploadFile(at: itemPath, folderId: contents.folder.id)
                    }
                }
            }
        }
    }

    func pause() {
        syncStatus = .paused
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func resume() {
        syncStatus = .idle
        if autoSync {
            startAutoSync()
        }
    }

    func openSyncFolder() {
        let url = URL(fileURLWithPath: syncFolderPath)
        NSWorkspace.shared.open(url)
    }

    /// Prepara la carpeta de sincronización después del login
    func setupAfterLogin() {
        // Crear la carpeta si no existe
        createSyncFolderIfNeeded()

        // Crear archivo de bienvenida
        createWelcomeFile()

        // Abrir la carpeta en Finder
        openSyncFolder()

        // Iniciar el file watcher
        startFileWatcher()

        // Iniciar auto sync si está habilitado
        if autoSync {
            startAutoSync()
        }
    }

    private func createWelcomeFile() {
        let welcomeURL = URL(fileURLWithPath: syncFolderPath).appendingPathComponent("LEEME.txt")

        // Solo crear si no existe
        guard !FileManager.default.fileExists(atPath: welcomeURL.path) else { return }

        let welcomeText = """
        ¡Bienvenido a CloudImega!

        Esta carpeta está sincronizada con tu cuenta de CloudImega.

        Cómo funciona:
        - Cualquier archivo que pongas aquí se subirá automáticamente a la nube
        - Los archivos de tu cuenta en la nube se descargarán aquí
        - Los cambios se sincronizan automáticamente

        Ubicación de la carpeta: \(syncFolderPath)

        Para más información, haz clic en el icono de CloudImega en la barra de menú.
        """

        try? welcomeText.write(to: welcomeURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private Methods

    private func createSyncFolderIfNeeded() {
        let url = URL(fileURLWithPath: syncFolderPath)
        if !FileManager.default.fileExists(atPath: syncFolderPath) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func startFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = FileWatcher(path: syncFolderPath) { [weak self] event in
            Task { @MainActor in
                self?.handleFileChange(event)
            }
        }
        fileWatcher?.start()
    }

    private func startAutoSync() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(syncInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
            }
        }
    }

    private func handleFileChange(_ event: FileWatcher.FileEvent) {
        guard autoSync && syncStatus == .idle else { return }

        Task {
            switch event.type {
            case .created, .modified:
                await uploadFile(at: event.path)
            case .deleted:
                await deleteRemoteFile(localPath: event.path)
            case .renamed:
                // Handle rename as delete + create
                break
            }
        }
    }


    private func uploadFile(at path: String, folderId: String? = nil) async {
        let url = URL(fileURLWithPath: path)
        uploadingCount += 1

        do {
            let cloudFile = try await APIClient.shared.uploadFile(localURL: url, folderId: folderId)

            // Update sync state
            let checksum = calculateChecksum(for: url)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = attrs[.size] as? Int64 ?? 0
            let modDate = attrs[.modificationDate] as? Date ?? Date()

            syncState.syncedFiles[path] = SyncedFileInfo(
                cloudID: cloudFile.id,
                localPath: path,
                checksum: checksum,
                lastModified: modDate,
                size: size
            )
            saveState()

            addActivity(.uploaded, fileName: url.lastPathComponent)

        } catch {
            addActivity(.error(error.localizedDescription), fileName: url.lastPathComponent)
        }

        uploadingCount -= 1
    }

    private func downloadFile(_ remoteFile: CloudFile, to localPath: String) async {
        let localURL = URL(fileURLWithPath: localPath)
        downloadingCount += 1

        do {
            try await APIClient.shared.downloadFile(id: remoteFile.id, to: localURL)

            // Update sync state
            syncState.syncedFiles[localURL.path] = SyncedFileInfo(
                cloudID: remoteFile.id,
                localPath: localURL.path,
                checksum: remoteFile.checksum ?? "",
                lastModified: Date(),
                size: remoteFile.size
            )
            saveState()

            addActivity(.downloaded, fileName: remoteFile.name)

        } catch {
            addActivity(.error(error.localizedDescription), fileName: remoteFile.name)
        }

        downloadingCount -= 1
    }

    private func deleteRemoteFile(localPath: String) async {
        guard let info = syncState.syncedFiles[localPath] else { return }

        do {
            try await APIClient.shared.deleteFile(id: info.cloudID)
            syncState.syncedFiles.removeValue(forKey: localPath)
            saveState()
            addActivity(.deleted, fileName: URL(fileURLWithPath: localPath).lastPathComponent)
        } catch {
            addActivity(.error(error.localizedDescription), fileName: URL(fileURLWithPath: localPath).lastPathComponent)
        }
    }

    private func calculateChecksum(for url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let hash = data.withUnsafeBytes { bytes in
            var result = [UInt8](repeating: 0, count: 32)
            // Simple hash for demo - in production use CryptoKit
            for (i, byte) in bytes.enumerated() {
                result[i % 32] ^= byte
            }
            return result
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(syncState) {
            try? data.write(to: stateFileURL)
        }
        syncedFilesCount = syncState.syncedFiles.count
    }

    private func addActivity(_ type: SyncActivity.ActivityType, fileName: String) {
        let activity = SyncActivity(type: type, fileName: fileName, timestamp: Date())
        recentActivities.insert(activity, at: 0)
        if recentActivities.count > 50 {
            recentActivities.removeLast()
        }
    }
}
