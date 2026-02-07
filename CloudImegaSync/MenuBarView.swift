import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var apiClient: APIClient
    @State private var showingLogin = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cloud.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("CloudImega")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if apiClient.isAuthenticated {
                authenticatedView
            } else {
                loginPromptView
            }
        }
        .frame(width: 320)
        .preferredColorScheme(.light) // Siempre modo claro
        .sheet(isPresented: $showingLogin) {
            LoginView()
                .environmentObject(apiClient)
        }
    }

    // MARK: - Status Badge
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(syncManager.syncStatus.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch syncManager.syncStatus {
        case .idle: return .green
        case .syncing: return .blue
        case .paused: return .orange
        case .error: return .red
        case .offline: return .gray
        }
    }

    // MARK: - Authenticated View
    private var authenticatedView: some View {
        VStack(spacing: 0) {
            // User info
            if let user = apiClient.currentUser {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(user.email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
            }

            Divider()

            // Sync folder
            Button(action: { syncManager.openSyncFolder() }) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Carpeta de sincronizacion")
                            .font(.subheadline)
                        Text(syncManager.syncFolderPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Divider()

            // Stats
            HStack(spacing: 20) {
                statItem(icon: "checkmark.circle.fill", value: "\(syncManager.syncedFilesCount)", label: "Sincronizados")
                if syncManager.uploadingCount > 0 {
                    statItem(icon: "arrow.up.circle.fill", value: "\(syncManager.uploadingCount)", label: "Subiendo")
                }
                if syncManager.downloadingCount > 0 {
                    statItem(icon: "arrow.down.circle.fill", value: "\(syncManager.downloadingCount)", label: "Descargando")
                }
            }
            .padding()

            Divider()

            // Recent activity
            if !syncManager.recentActivities.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actividad reciente")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    ForEach(syncManager.recentActivities.prefix(3)) { activity in
                        HStack {
                            Image(systemName: activity.type.icon)
                                .foregroundColor(activityColor(activity.type))
                                .font(.caption)
                            Text(activity.fileName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(timeAgo(activity.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 8)

                Divider()
            }

            // Actions
            VStack(spacing: 0) {
                actionButton(icon: "arrow.triangle.2.circlepath", title: "Sincronizar ahora") {
                    Task {
                        await syncManager.syncNow()
                    }
                }
                .disabled(syncManager.syncStatus == .syncing)

                if syncManager.syncStatus == .paused {
                    actionButton(icon: "play.fill", title: "Reanudar") {
                        syncManager.resume()
                    }
                } else {
                    actionButton(icon: "pause.fill", title: "Pausar") {
                        syncManager.pause()
                    }
                }

                Divider()

                actionButton(icon: "gear", title: "Preferencias...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }

                actionButton(icon: "rectangle.portrait.and.arrow.right", title: "Cerrar sesion") {
                    apiClient.logout()
                }

                Divider()

                actionButton(icon: "xmark.circle", title: "Salir") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: - Login Prompt
    private var loginPromptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No has iniciado sesion")
                .font(.headline)

            Text("Inicia sesion para sincronizar tus archivos con CloudImega")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Iniciar sesion") {
                showingLogin = true
            }
            .buttonStyle(.borderedProminent)

            Divider()

            actionButton(icon: "xmark.circle", title: "Salir") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
    }

    // MARK: - Helpers
    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                Text(value)
                    .font(.headline)
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func activityColor(_ type: SyncActivity.ActivityType) -> Color {
        switch type {
        case .uploaded: return .green
        case .downloaded: return .blue
        case .deleted: return .orange
        case .error: return .red
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "ahora" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

#Preview {
    MenuBarView()
        .environmentObject(SyncManager.shared)
        .environmentObject(APIClient.shared)
}
