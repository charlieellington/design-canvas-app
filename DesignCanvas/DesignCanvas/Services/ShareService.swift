// HTTP client for Stage 13's `/api/share/*` endpoints. Single source of truth
// for the wire shape; ShareUploadOrchestrator sequences the calls.
//
// No default backend. Configure DesignCanvasShareBaseURL explicitly to enable uploads.
//
// URLSession config: 30s request timeout, 300s resource timeout — flaky WiFi
// fails fast so retry kicks in rather than hanging.

import AppKit
import Foundation

enum ShareError: LocalizedError {
    case http(status: Int, body: String)
    case decode(message: String)
    case network(underlying: Error)
    case missingResponse
    case disabled

    var errorDescription: String? {
        switch self {
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(160))"
        case .decode(let m): return "Decode: \(m)"
        case .network(let e): return "Network: \(e.localizedDescription)"
        case .missingResponse: return "Missing response"
        case .disabled: return "Sharing requires a separately operated backend. Configure DesignCanvasShareBaseURL before creating a link."
        }
    }
}

struct CreatedShare: Decodable {
    let id: String
    let deleteToken: String
    let uploadToken: String
    let expiresAt: String
    let contentVersion: Int
    let idempotent: Bool?
}

struct FinaliseResult: Decodable {
    let id: String
    let url: String
    let frameCount: Int
    let contentVersion: Int
    let frameImages: [FinaliseFrame]
}

struct FinaliseFrame: Decodable {
    let id: String
    let clientFrameId: String
    let frameType: String
    let sourceIdentifier: String
    let displayName: String?
}

@MainActor
final class ShareService {

    static let shared = ShareService()

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    var baseURL: URL? { BuildPolicy.shareBaseURL() }

    // MARK: - POST /api/share/create

    func createShare(payload: SharePayloadWire, idempotencyKey: UUID) async throws -> CreatedShare {
        guard let baseURL else { throw ShareError.disabled }
        let url = baseURL.appendingPathComponent("/api/share/create")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "x-dc-request")
        req.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "idempotency-key")
        req.httpBody = try encoder.encode(payload)
        return try await send(req, decode: CreatedShare.self)
    }

    // MARK: - PUT /api/share/[id]/image

    /// Upload a single frame's JPEG bytes. All metadata is multipart form data.
    func uploadFrame(
        shareID: String,
        uploadToken: String,
        clientFrameId: UUID,
        frameType: String,
        sourceIdentifier: String,
        displayName: String?,
        contentHash: String?,
        width: Double,
        height: Double,
        viewportWidth: Int,
        viewportHeight: Int,
        x: Double,
        y: Double,
        displayOrder: Int,
        jpegData: Data,
    ) async throws {
        guard let baseURL else { throw ShareError.disabled }
        let url = baseURL.appendingPathComponent("/api/share/\(shareID)/image")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(uploadToken)", forHTTPHeaderField: "Authorization")
        let boundary = "dc-boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = NSMutableData()
        appendField(body, boundary: boundary, name: "clientFrameId", value: clientFrameId.uuidString)
        appendField(body, boundary: boundary, name: "frameType", value: frameType)
        appendField(body, boundary: boundary, name: "sourceIdentifier", value: sourceIdentifier)
        if let displayName { appendField(body, boundary: boundary, name: "displayName", value: displayName) }
        if let contentHash { appendField(body, boundary: boundary, name: "contentHash", value: contentHash) }
        appendField(body, boundary: boundary, name: "width", value: String(width))
        appendField(body, boundary: boundary, name: "height", value: String(height))
        appendField(body, boundary: boundary, name: "viewportWidth", value: String(viewportWidth))
        appendField(body, boundary: boundary, name: "viewportHeight", value: String(viewportHeight))
        appendField(body, boundary: boundary, name: "x", value: String(x))
        appendField(body, boundary: boundary, name: "y", value: String(y))
        appendField(body, boundary: boundary, name: "displayOrder", value: String(displayOrder))
        // file
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpegData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body as Data

        let (_, response) = try await session.upload(for: req, from: req.httpBody ?? Data())
        try ensureOK(response, body: Data())
    }

    // MARK: - POST /api/share/[id]/finalise

    func finaliseShare(shareID: String, uploadToken: String) async throws -> FinaliseResult {
        guard let baseURL else { throw ShareError.disabled }
        let url = baseURL.appendingPathComponent("/api/share/\(shareID)/finalise")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(uploadToken)", forHTTPHeaderField: "Authorization")
        req.setValue("1", forHTTPHeaderField: "x-dc-request")
        req.httpBody = Data("{}".utf8)
        return try await send(req, decode: FinaliseResult.self)
    }

    // MARK: - Helpers

    private func send<T: Decodable>(_ req: URLRequest, decode: T.Type) async throws -> T {
        do {
            let (data, response) = try await session.data(for: req)
            try ensureOK(response, body: data)
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw ShareError.decode(message: error.localizedDescription)
            }
        } catch let err as ShareError {
            throw err
        } catch {
            throw ShareError.network(underlying: error)
        }
    }

    private func ensureOK(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ShareError.missingResponse }
        if !(200..<300).contains(http.statusCode) {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            throw ShareError.http(status: http.statusCode, body: bodyString)
        }
    }

    private func appendField(_ body: NSMutableData, boundary: String, name: String, value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }
}

// MARK: - Wire payload for POST /create

/// Mirrors Stage 13's `SharePayloadInputSchema`. Strict — every field required.
struct SharePayloadWire: Encodable {
    let schemaVersion: Int
    let title: String?
    let styling: StylingConfig
    let frames: [FrameWire]
    let initialView: InitialView?
    let pageId: String?
}

/// Discriminated frame type — Stage 13 `FrameSchema`.
enum FrameWire: Encodable {
    case route(RouteFrameWire)
    case markdown(StaticFrameWire)
    case image(StaticFrameWire)

    private enum CodingKeys: String, CodingKey { case type }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .route(let r):
            try c.encode("route", forKey: .type)
            try r.encode(to: encoder)
        case .markdown(let m):
            try c.encode("markdown", forKey: .type)
            try m.encode(to: encoder)
        case .image(let i):
            try c.encode("image", forKey: .type)
            try i.encode(to: encoder)
        }
    }
}

struct RouteFrameWire: Encodable {
    let clientFrameId: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let displayName: String?
    let routePath: String
}

struct StaticFrameWire: Encodable {
    let clientFrameId: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let displayName: String?
    let contentHash: String?
}
