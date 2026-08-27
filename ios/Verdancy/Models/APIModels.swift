import Foundation

// MARK: - Responses

struct PlantsResponse: Codable {
    let plants: [Plant]
}

struct TreeStatus: Codable, Hashable {
    let treesPledged: Int
    let milestones: [String]
    /// Real Tree-Nation plantings with per-tree certificates (`GET /me/trees` →
    /// `planted`). Optional: absent from older disk snapshots.
    let planted: [PlantedTree]?

    init(treesPledged: Int, milestones: [String], planted: [PlantedTree]? = nil) {
        self.treesPledged = treesPledged
        self.milestones = milestones
        self.planted = planted
    }

    /// Newest first — the order the forest screen renders.
    var plantings: [PlantedTree] {
        (planted ?? []).sorted { ($0.plantedDate ?? .distantPast) > ($1.plantedDate ?? .distantPast) }
    }

    static let empty = TreeStatus(treesPledged: 0, milestones: [])
}

/// One real tree from `GET /me/trees` → `planted`. `certificateUrl` is the
/// user-visible proof of an actual planting (iOS-PRD §10: provable, never vague),
/// so it's the link the forest screen leads with. Every field is optional — a
/// planting still renders if the partner hasn't filled one in.
struct PlantedTree: Codable, Hashable, Identifiable {
    let collectUrl: String?
    let certificateUrl: String?
    let speciesName: String?
    let projectName: String?
    let reason: String?
    let plantedAt: String?

    var id: String {
        certificateUrl ?? collectUrl ?? "\(speciesName ?? "tree")-\(plantedAt ?? "")"
    }

    var plantedDate: Date? { ISO.date(plantedAt) }
    var certificateURL: URL? { certificateUrl.flatMap(URL.init(string:)) }
    var collectURL: URL? { collectUrl.flatMap(URL.init(string:)) }

    var displaySpecies: String { speciesName ?? "A tree" }

    /// Humanized grant reason (`streak_7` → "7-day care streak").
    var displayReason: String? {
        guard let reason, !reason.isEmpty else { return nil }
        if reason.hasPrefix("streak_"), let days = Int(reason.dropFirst("streak_".count)) {
            return "\(days)-day care streak"
        }
        if reason == "referral_joined" { return "Joined via invite" }
        if reason.hasPrefix("referral_") { return "Invited a friend" }
        return reason.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// `POST /checkin` — the server computes the streak from its own UTC date, so
/// calling more than once a day is a safe no-op.
struct CheckinResponse: Codable {
    let streak: Int
    let treeGranted: Bool
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

/// `GET /plants/{id}/photos` entry (growth timeline).
struct PhotoEntry: Codable, Identifiable, Hashable {
    let takenAt: String?
    let caption: String?
    let downloadUrl: String?
    var id: String { takenAt ?? UUID().uuidString }
}

struct PhotosResponse: Codable {
    let photos: [PhotoEntry]
}

/// `GET /me/referral` — the caller's shareable invite code.
struct ReferralCode: Codable {
    let code: String
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
    let taxonomy: Taxonomy?
    let confidence: String?

    enum CodingKeys: String, CodingKey {
        case imageRef = "image_ref"
        case commonName = "common_name"
        case species
        case nickname
        case toxicity
        case taxonomy
        case confidence
    }

    /// Build a save request from an identify result. Identify carries identity
    /// only now — the care schedule is generated later from the plant's
    /// environment (`POST /plants/{id}/care-plan`).
    init(from card: CareCard, imageRef: String, nickname: String?) {
        self.imageRef = imageRef
        self.commonName = card.commonName
        self.species = card.species
        self.nickname = nickname
        self.toxicity = card.toxicity
        self.taxonomy = card.taxonomy
        self.confidence = card.confidence
    }
}

// MARK: - Personalized care

/// The "Finish personalizing care" form state (kept concise on purpose). Maps to
/// the snake_case body the care-plan endpoint expects via `CarePlanRequest`.
struct Personalization: Hashable {
    var potSize: PotSize = .medium
    var hasDrainage: Bool = true
    var soilType: SoilType = .regular
    var indoor: Bool = true
    var directSunlight: Bool = false
    var directSunlightHours: Int = 2
    var windowOrientation: WindowOrientation? = nil
    var distanceFromWindow: WindowDistance = .within3ft
    var growLight: Bool = false

    enum PotSize: String, CaseIterable, Identifiable, Hashable {
        case small = "Small", medium = "Medium", large = "Large"
        var id: String { rawValue }
        /// A concrete hint the model can size a water amount from.
        var apiValue: String {
            switch self {
            case .small: return "Small (≤4 in / 10 cm diameter)"
            case .medium: return "Medium (5–8 in / 12–20 cm diameter)"
            case .large: return "Large (9+ in / 23+ cm diameter)"
            }
        }
    }

    enum SoilType: String, CaseIterable, Identifiable, Hashable {
        case regular = "Regular", wellDraining = "Well-draining", moisture = "Moisture-retaining"
        var id: String { rawValue }
    }

    enum WindowOrientation: String, CaseIterable, Identifiable, Hashable {
        case north = "North", south = "South", east = "East", west = "West"
        var id: String { rawValue }
    }

    enum WindowDistance: String, CaseIterable, Identifiable, Hashable {
        case onSill = "On the sill", within3ft = "Within 3 ft"
        case within6ft = "3–6 ft away", farther = "More than 6 ft"
        var id: String { rawValue }
    }
}

/// `POST /plants/{id}/care-plan` body — explicit snake_case keys (the shared
/// request encoder does no key conversion).
struct CarePlanRequest: Encodable {
    let potSize: String?
    let hasDrainage: Bool?
    let soilType: String?
    let indoor: Bool?
    let directSunlight: Bool?
    let directSunlightHours: Int?
    let windowOrientation: String?
    let distanceFromWindow: String?
    let growLight: Bool?

    enum CodingKeys: String, CodingKey {
        case potSize = "pot_size"
        case hasDrainage = "has_drainage"
        case soilType = "soil_type"
        case indoor
        case directSunlight = "direct_sunlight"
        case directSunlightHours = "direct_sunlight_hours"
        case windowOrientation = "window_orientation"
        case distanceFromWindow = "distance_from_window"
        case growLight = "grow_light"
    }

    init(_ p: Personalization) {
        potSize = p.potSize.apiValue
        hasDrainage = p.hasDrainage
        soilType = p.soilType.rawValue
        indoor = p.indoor
        directSunlight = p.directSunlight
        directSunlightHours = p.directSunlight ? p.directSunlightHours : 0
        windowOrientation = p.windowOrientation?.rawValue
        distanceFromWindow = p.distanceFromWindow.rawValue
        growLight = p.growLight
    }
}

struct CareRequest: Encodable {
    let type: String
}

/// `PATCH /plants/{id}` — only set fields are sent (synthesized `encodeIfPresent`
/// omits nils), so untouched attributes are left alone.
struct UpdatePlantRequest: Encodable {
    let nickname: String?
    let waterCadenceDays: Int?
    let fertilizeCadenceDays: Int?
    let pruneCadenceDays: Int?

    enum CodingKeys: String, CodingKey {
        case nickname
        case waterCadenceDays = "water_cadence_days"
        case fertilizeCadenceDays = "fertilize_cadence_days"
        case pruneCadenceDays = "prune_cadence_days"
    }
}

struct AddPhotoRequest: Encodable {
    let imageRef: String
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case imageRef = "image_ref"
        case caption
    }
}


struct BuddyRequest: Encodable {
    let species: String
}

struct RedeemInviteRequest: Encodable {
    let code: String
}
