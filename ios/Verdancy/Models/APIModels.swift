import Foundation

// MARK: - Responses

struct PlantsResponse: Codable {
    let plants: [Plant]
}

struct TreeStatus: Codable, Hashable {
    let treesPledged: Int
    let milestones: [String]

    static let empty = TreeStatus(treesPledged: 0, milestones: [])
}

/// `POST /uploads` → presigned PUT ticket.
struct UploadTicket: Codable {
    let imageRef: String
    let uploadUrl: String
    let plantId: String
}

/// `POST /buddy` response.
struct BuddyResponse: Codable {
    let species: String
    let status: String
    let spriteUrl: String?
    let styleVersion: Int?
}

// MARK: - Request bodies
// Explicit CodingKeys so payloads match the backend field names exactly: snake_case
// for stored attributes, camelCase for `plantId` / `milestoneId` / `kind` / `type`.

struct IdentifyRequest: Encodable {
    let image: String // base64
}

struct UploadRequest: Encodable {
    let kind: String // "plant" | "photo"
    let plantId: String?
}

struct CreatePlantRequest: Encodable {
    let imageRef: String
    let commonName: String
    let species: String
    let nickname: String?
    let toxicity: String?
    let waterCadenceDays: Int?
    let fertilizeCadenceDays: Int?
    let lightingNeeds: String?
    let fertilizerInfo: String?
    let confidence: String?

    enum CodingKeys: String, CodingKey {
        case imageRef = "image_ref"
        case commonName = "common_name"
        case species
        case nickname
        case toxicity
        case waterCadenceDays = "water_cadence_days"
        case fertilizeCadenceDays = "fertilize_cadence_days"
        case lightingNeeds = "lighting_needs"
        case fertilizerInfo = "fertilizer_info"
        case confidence
    }

    /// Build a save request from an identify result, dropping cadences when the
    /// plant is unidentified (iOS-PRD §6 — no fake schedule).
    init(from card: CareCard, imageRef: String, nickname: String?) {
        self.imageRef = imageRef
        self.commonName = card.commonName
        self.species = card.species
        self.nickname = nickname
        self.toxicity = card.toxicity
        self.waterCadenceDays = card.isUnidentified ? nil : card.waterCadenceDays
        self.fertilizeCadenceDays = card.isUnidentified ? nil : card.fertilizeCadenceDays
        self.lightingNeeds = card.lightingNeeds
        self.fertilizerInfo = card.fertilizerInfo
        self.confidence = card.confidence
    }
}

struct CareRequest: Encodable {
    let type: String
}

struct AddPhotoRequest: Encodable {
    let imageRef: String
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case imageRef = "image_ref"
        case caption
    }
}

struct MilestoneRequest: Encodable {
    let milestoneId: String
}

struct BuddyRequest: Encodable {
    let species: String
}
