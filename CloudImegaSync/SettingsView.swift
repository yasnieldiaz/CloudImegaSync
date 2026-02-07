import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var apiClient: APIClient

    @State private var selectedFolder: String = ""
    @State private var showFolderPicker = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            accountTab
                .tabItem {
                    Label("Cuenta", systemImage: "person.circle")
                }

            advancedTab
                .tabItem {
                    Label("Avanzado", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 450, height: 300)
        .preferredColorScheme(.light) // Siempre modo claro
        .onAppear {
            selectedFolder = syncManager.syncFolderPath
        }
    }

    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Carpeta de sincronizacion")
                            .font(.headline)
                        Text(selectedFolder)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Cambiar...") {
                        selectFolder()
                    }
                }

                Toggle("Sincronizacion automatica", isOn: $syncManager.autoSync)

                Picker("Intervalo de sincronizacion", selection: $syncManager.syncInterval) {
                    Text("1 minuto").tag(60)
                    Text("5 minutos").tag(300)
                    Text("15 minutos").tag(900)
                    Text("30 minutos").tag(1800)
                    Text("1 hora").tag(3600)
                }

                Toggle("Iniciar al arrancar el sistema", isOn: .constant(false))
                    .disabled(true)
            }
        }
        .padding()
    }

    // MARK: - Account Tab
    private var accountTab: some View {
        Form {
            if let user = apiClient.currentUser {
                Section {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name)
                                .font(.headline)
                            Text(user.email)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Almacenamiento")
                            .font(.subheadline)
                        ProgressView(value: Double(user.storageUsed), total: Double(user.storageQuota))
                        HStack {
                            Text(formatBytes(user.storageUsed))
                            Spacer()
                            Text("de \(formatBytes(user.storageQuota))")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Servidor")
                        Spacer()
                        Text(apiClient.serverURL)
                            .foregroundColor(.secondary)
                    }

                    Button("Cerrar sesion", role: .destructive) {
                        apiClient.logout()
                    }
                }
            } else {
                VStack {
                    Text("No has iniciado sesion")
                        .foregroundColor(.secondary)
                    Button("Iniciar sesion") {
                        // Show login
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Advanced Tab
    private var advancedTab: some View {
        Form {
            Section {
                HStack {
                    Text("Archivos sincronizados")
                    Spacer()
                    Text("\(syncManager.syncedFilesCount)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Ultima sincronizacion")
                    Spacer()
                    Text("Hace 5 minutos")
                        .foregroundColor(.secondary)
                }

                Button("Forzar sincronizacion completa") {
                    Task {
                        await syncManager.syncNow()
                    }
                }

                Button("Abrir logs", role: .none) {
                    // Open logs
                }
            }

            Section("Exclusiones") {
                Text("Archivos y carpetas excluidos de la sincronizacion")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading) {
                    Text(".DS_Store")
                    Text(".git/")
                    Text("node_modules/")
                    Text("*.tmp")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Helpers
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Selecciona la carpeta para sincronizar"
        panel.prompt = "Seleccionar"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url.path
            syncManager.setSyncFolder(url.path)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncManager.shared)
        .environmentObject(APIClient.shared)
}
