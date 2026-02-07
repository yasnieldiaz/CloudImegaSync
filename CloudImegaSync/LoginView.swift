import SwiftUI

struct LoginView: View {
    @EnvironmentObject var apiClient: APIClient
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = "https://cloudimega.com"
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            // Logo
            VStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                Text("CloudImega")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Sincronizacion de archivos")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            // Form
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Servidor")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://cloudimega.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Correo electronico")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("correo@ejemplo.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Contrasena")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Contrasena", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: login) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        }
                        Text(isLoading ? "Iniciando sesion..." : "Iniciar sesion")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || email.isEmpty || password.isEmpty)
            }
            .padding(.horizontal, 24)

            Spacer()

            // Footer
            VStack(spacing: 4) {
                Text("No tienes cuenta?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Link("Registrate en cloudimega.com", destination: URL(string: "https://cloudimega.com/auth/register")!)
                    .font(.caption)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 340, height: 450)
        .preferredColorScheme(.light) // Siempre modo claro
    }

    private func login() {
        isLoading = true
        errorMessage = nil

        // Update server URL
        apiClient.serverURL = serverURL

        Task {
            do {
                _ = try await apiClient.login(email: email, password: password)
                dismiss()

                // Trigger initial sync
                await SyncManager.shared.syncNow()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(APIClient.shared)
}
