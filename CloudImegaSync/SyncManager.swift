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
            // 1. Get list of remote files
            let remoteFiles = try await fetchAllRemoteFiles()

            // 2. Get list of local files
            let localFiles = getLocalFiles()

            // 3. Compare and sync
            await syncFiles(local: localFiles, remote: remoteFiles)

            syncStatus = .idle
            syncState.lastSyncDate = Date()
            saveState()

        } catch {
            syncStatus = .error(error.localizedDescription)
            addActivity(.error(error.localizedDescription), fileName: "Sync")
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

    private func fetchAllRemoteFiles() async throws -> [CloudFile] {
        var allFiles: [CloudFile] = []
        var page = 1
        let perPage = 100

        while true {
            let response = try await APIClient.shared.listFiles(page: page, perPage: perPage)
            allFiles.append(contentsOf: response.items)

            if response.items.count < perPage {
                break
            }
            page += 1
        }

        return allFiles
    }

    private func getLocalFiles() -> [URL] {
        let url = URL(fileURLWithPath: syncFolderPath)
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var files: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            if let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile {
                files.append(fileURL)
            }
        }
        return files
    }

    private func syncFiles(local: [URL], remote: [CloudFile]) async {
        // Create a map of remote files by name for quick lookup
        let remoteByName = Dictionary(uniqueKeysWithValues: remote.map { ($0.name, $0) })
        let localByName = Dictionary(uniqueKeysWithValues: local.map { ($0.lastPathComponent, $0) })

        // Files to upload (local but not remote)
        for localURL in local {
            let name = localURL.lastPathComponent
            if remoteByName[name] == nil {
                await uploadFile(at: localURL.path)
            } else if let remoteFile = remoteByName[name] {
                // Check if local is newer
                if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    let formatter = ISO8601DateFormatter()
                    if let remoteDate = formatter.date(from: remoteFile.updatedAt),
                       modDate > remoteDate {
                        await uploadFile(at: localURL.path)
                    }
                }
            }
        }

        // Files to download (remote but not local)
        for remoteFile in remote {
            if localByName[remoteFile.name] == nil {
                await downloadFile(remoteFile)
            }
        }

        syncedFilesCount = syncState.syncedFiles.count
    }

    private func uploadFile(at path: String) async {
        let url = URL(fileURLWithPath: path)
        uploadingCount += 1

        do {
            let cloudFile = try await APIClient.shared.uploadFile(localURL: url)

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

    private func downloadFile(_ remoteFile: CloudFile) async {
        let localURL = URL(fileURLWithPath: syncFolderPath).appendingPathComponent(remoteFile.name)
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
