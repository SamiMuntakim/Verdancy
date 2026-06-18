import Foundation

struct Endpoint {
    let method: String
    let path: String
    var body: Data?

    init(_ method: String, _ path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }
}

/// Async/await wrapper over `URLSession` (iOS-PRD §4). Attaches the Cognito JWT to
/// every call, refreshes + retries once on a 401, decodes typed `Codable` (snake_case
/// → camelCase), and maps status codes to `APIError`.
final class APIClient {
    private let baseURL: URL
    private let auth: AuthService
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = AppConfig.apiBaseURL, auth: AuthService, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = d
        // Request bodies use explicit CodingKeys — keep default key encoding.
        self.encoder = JSONEncoder()
    }

    // MARK: - Typed endpoints

    func createUser() async throws {
        _ = try await sendRaw(Endpoint("POST", "/users"))
    }

    func listPlants() async throws -> [Plant] {
        try await send(Endpoint("GET", "/plants"), as: PlantsResponse.self).plants
    }

    func identify(imageBase64: String) async throws -> CareCard {
        try await send(Endpoint("POST", "/identify", body: encode(IdentifyRequest(image: imageBase64))),
                       as: CareCard.self)
    }

    func diagnose(imageBase64: String) async throws -> DiagnosisCard {
        try await send(Endpoint("POST", "/diagnose", body: encode(IdentifyRequest(image: imageBase64))),
                       as: DiagnosisCard.self)
    }

    func createUpload(kind: String, plantId: String? = nil) async throws -> UploadTicket {
        try await send(Endpoint("POST", "/uploads", body: encode(UploadRequest(kind: kind, plantId: plantId))),
                       as: UploadTicket.self)
    }

    func savePlant(_ request: CreatePlantRequest) async throws -> Plant {
        try await send(Endpoint("POST", "/plants", body: encode(request)), as: Plant.self)
    }

    func logCare(plantId: String, type: CareType) async throws {
        _ = try await sendRaw(Endpoint("POST", "/plants/\(plantId)/care",
                                       body: encode(CareRequest(type: type.rawValue))))
    }

    func deletePlant(plantId: String) async throws {
        _ = try await sendRaw(Endpoint("DELETE", "/plants/\(plantId)"))
    }

    func addPhoto(plantId: String, imageRef: String, caption: String?) async throws {
        _ = try await sendRaw(Endpoint("POST", "/plants/\(plantId)/photos",
                                       body: encode(AddPhotoRequest(imageRef: imageRef, caption: caption))))
    }

    func recordMilestone(_ id: String) async throws -> TreeStatus {
        try await send(Endpoint("POST", "/milestones", body: encode(MilestoneRequest(milestoneId: id))),
                       as: TreeStatus.self)
    }

    func trees() async throws -> TreeStatus {
        try await send(Endpoint("GET", "/me/trees"), as: TreeStatus.self)
    }

    func buddy(species: String) async throws -> BuddyResponse {
        try await send(Endpoint("POST", "/buddy", body: encode(BuddyRequest(species: species))),
                       as: BuddyResponse.self)
    }

    // MARK: - Direct S3 (presigned URLs — bytes never go through the API)

    func uploadImage(to urlString: String, jpeg: Data) async throws {
        guard let url = URL(string: urlString) else { throw APIError.badRequest("Bad upload URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await session.upload(for: req, from: jpeg)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.network("Image upload failed")
        }
    }

    func download(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.badRequest("Bad download URL") }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.network("Image download failed")
        }
        return data
    }

    // MARK: - Core

    private func send<Response: Decodable>(_ endpoint: Endpoint, as type: Response.Type) async throws -> Response {
        let data = try await sendRaw(endpoint)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    @discardableResult
    private func sendRaw(_ endpoint: Endpoint) async throws -> Data {
        var (data, http) = try await perform(endpoint, forceRefresh: false)
        if http.statusCode == 401 {
            (data, http) = try await perform(endpoint, forceRefresh: true)
        }
        try Self.validate(http, data: data)
        return data
    }

    private func perform(_ endpoint: Endpoint, forceRefresh: Bool) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appending(path: endpoint.path))
        req.httpMethod = endpoint.method
        if let body = endpoint.body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let token = try await auth.idToken(forceRefresh: forceRefresh)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw APIError.network("No HTTP response")
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    private static func validate(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300: return
        case 400: throw APIError.badRequest(Self.errorMessage(data))
        case 401: throw APIError.unauthorized
        case 402: throw APIError.paywall
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        case 429: throw APIError.rateLimited
        default: throw APIError.server(http.statusCode)
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
    }
}
