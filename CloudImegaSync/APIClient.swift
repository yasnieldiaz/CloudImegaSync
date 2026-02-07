import Foundation
import SwiftUI

@MainActor
class APIClient: ObservableObject {
    static let shared = APIClient()

    @AppStorage("serverURL") var serverURL: String = "https://cloudimega.com"
    @AppStorage("accessToken") private var accessToken: String = ""
    @AppStorage("refreshToken") private var refreshToken: String = ""
    @Published var currentUser: User?
    @Published var isAuthenticated: Bool = false
    private var isRefreshing = false

    private init() {
        if !accessToken.isEmpty {
            Task {
                await validateToken()
            }
        }
    }

    /// Auto-refresh token
    private func refreshAccessToken() async -> Bool {
        guard !refreshToken.isEmpty, !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let url = URL(string: serverURL + "/api/v1/auth/refresh") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["refreshToken": refreshToken])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return false }
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            accessToken = authResponse.accessToken
            refreshToken = authResponse.refreshToken
            print("[API] Token refreshed")
            return true
        } catch { return false }
    }

    var baseURL: URL {
        URL(string: serverURL)!
    }

    // MARK: - Authentication

    func login(email: String, password: String) async throws -> User {
        guard let url = URL(string: serverURL + "/api/v1/auth/login") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["email": email, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.loginFailed
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        accessToken = authResponse.accessToken
        refreshToken = authResponse.refreshToken
        currentUser = authResponse.user
        isAuthenticated = true

        return authResponse.user
    }

    func logout() {
        accessToken = ""
        refreshToken = ""
        currentUser = nil
        isAuthenticated = false
    }

    private func validateToken() async {
        guard !accessToken.isEmpty else { return }

        do {
            let user = try await getProfile()
            currentUser = user
            isAuthenticated = true
        } catch {
            logout()
        }
    }

    func getProfile() async throws -> User {
        let data = try await request(endpoint: "/api/v1/auth/me")
        return try JSONDecoder().decode(User.self, from: data)
    }

    // MARK: - Files

    func listFiles(folderId: String? = nil, page: Int = 1, perPage: Int = 100) async throws -> FilesResponse {
        var endpoint = "/api/v1/files?page=\(page)&perPage=\(perPage)"
        if let folderId = folderId {
            endpoint += "&folderId=\(folderId)"
        }
        let data = try await request(endpoint: endpoint)
        return try JSONDecoder().decode(FilesResponse.self, from: data)
    }

    func getFolder(id: String) async throws -> FolderContents {
        let data = try await request(endpoint: "/api/v1/folders/\(id)/contents")
        return try JSONDecoder().decode(FolderContents.self, from: data)
    }

    func getRootFolder() async throws -> FolderContents {
        // First get root folder ID
        let rootData = try await request(endpoint: "/api/v1/folders/root")
        let rootFolder = try JSONDecoder().decode(CloudFolder.self, from: rootData)
        // Then get its contents
        return try await getFolder(id: rootFolder.id)
    }

    func uploadFile(localURL: URL, folderId: String? = nil, retry: Bool = true) async throws -> CloudFile {
        guard let url = URL(string: serverURL + "/api/v1/files") else {
            throw APIError.uploadFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let fileName = localURL.lastPathComponent
        let fileData = try Data(contentsOf: localURL)
        let mimeType = mimeTypeForPath(localURL.path)

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // Add folderId if provided
        if let folderId = folderId {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"folderId\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(folderId)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.uploadFailed
        }

        if httpResponse.statusCode == 401 && retry {
            if await refreshAccessToken() {
                return try await uploadFile(localURL: localURL, folderId: folderId, retry: false)
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.uploadFailed
        }

        return try JSONDecoder().decode(CloudFile.self, from: data)
    }

    func downloadFile(id: String, to localURL: URL) async throws {
        guard let url = URL(string: serverURL + "/api/v1/files/\(id)/download") else {
            throw APIError.downloadFailed
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.downloadFailed
        }

        try data.write(to: localURL)
    }

    func deleteFile(id: String) async throws {
        guard let url = URL(string: serverURL + "/api/v1/files/\(id)") else {
            throw APIError.deleteFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.deleteFailed
        }
    }

    func createFolder(name: String, parentId: String? = nil) async throws -> CloudFolder {
        guard let url = URL(string: serverURL + "/api/v1/folders") else {
            throw APIError.createFolderFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["name": name]
        if let parentId = parentId {
            body["parentId"] = parentId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.createFolderFailed
        }

        return try JSONDecoder().decode(CloudFolder.self, from: data)
    }

    // MARK: - Private helpers

    private func request(endpoint: String, method: String = "GET", retry: Bool = true) async throws -> Data {
        guard let url = URL(string: serverURL + endpoint) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 && retry {
            if await refreshAccessToken() {
                return try await self.request(endpoint: endpoint, method: method, retry: false)
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        return data
    }

    private func mimeTypeForPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "pdf": "application/pdf",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "mp3": "audio/mpeg",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "txt": "text/plain",
            "html": "text/html",
            "css": "text/css",
            "js": "application/javascript",
            "json": "application/json",
            "zip": "application/zip"
        ]
        return mimeTypes[ext] ?? "application/octet-stream"
    }
}

// MARK: - Errors
enum APIError: LocalizedError {
    case loginFailed
    case invalidResponse
    case httpError(Int)
    case uploadFailed
    case downloadFailed
    case deleteFailed
    case createFolderFailed

    var errorDescription: String? {
        switch self {
        case .loginFailed: return "Error de inicio de sesion"
        case .invalidResponse: return "Respuesta invalida del servidor"
        case .httpError(let code): return "Error HTTP: \(code)"
        case .uploadFailed: return "Error al subir archivo"
        case .downloadFailed: return "Error al descargar archivo"
        case .deleteFailed: return "Error al eliminar archivo"
        case .createFolderFailed: return "Error al crear carpeta"
        }
    }
}
