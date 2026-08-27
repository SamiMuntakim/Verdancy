import Foundation

// MARK: - Responses

struct PlantsResponse: Codable {
    let plants: [Plant]
}

struct TreeStatus: Codable, Hashable {
    let treesPledged: Int
    let milestones: [String]
    /// Care tasks completed while genuinely due, and the next total that earns a
    /// tree — server-computed, so the Trees tab can show real progress.
    let careOnTime: Int?
    let nextCareMilestone: Int?
    let streak: Int?
    let streakTreeInterval: Int?
    /// Real Tree-Nation plantings with per-tree certificates (`GET /me/trees` →
    /// `planted`). Optional: absent from older disk snapshots.
    let planted: [PlantedTree]?

    init(treesPledged: Int, milestones: [String], planted: [PlantedTree]? = nil,
         careOnTime: Int? = nil, nextCareMilestone: Int? = nil,
         streak: Int? = nil, streakTreeInterval: Int? = nil) {
        self.treesPledged = treesPledged
        self.milestones = milestones
        self.planted = planted
        self.careOnTime = careOnTime
        self.nextCareMilestone = nextCareMilestone
        self.streak = streak
        self.streakTreeInterval = streakTreeInterval
    }

    /// Newest first — the order the forest screen renders.
    var plantings: [PlantedTree] {
        (planted ?? []).sorted { ($0.plantedDate ?? .distantPast) > ($1.plantedDate ?? .distantPast) }
    }

    /// Combined lifetime CO₂ absorption of every planted tree, in kg (0 = unknown).
    var lifetimeCo2Kg: Int { plantings.compactMap(\.lifeTimeCo2).reduce(0, +) }

    /// Distinct planting countries, in planting order ("Tanzania", …).
    var countries: [String] {
        var seen = Set<String>()
        return plantings.compactMap { tree in
            guard let c = tree.country, !c.isEmpty, seen.insert(c).inserted else { return nil }
            return c
        }
    }

    static let empty = TreeStatus(treesPledged: 0, milestones: [])
}

/// One real tree from `GET /me/trees` → `planted`. `certificateUrl` is the
/// user-visible proof of an actual planting (iOS-PRD §10: provable, never vague),
/// `collectUrl` lets the user claim the tree into their own Tree-Nation forest,
/// and the species photo / country / project link / lifetime CO2 make it feel
/// like a tree rather than a counter. Every field is optional — a planting still
/// renders if the partner hasn't filled one in.
struct PlantedTree: Codable, Hashable, Identifiable {
    let collectUrl: String?
    let certificateUrl: String?
    let speciesName: String?
    let commonName: String?
    let speciesImage: String?
    let projectName: String?
    let projectUrl: String?
    let country: String?
    let lifeTimeCo2: Int?
    let reason: String?
    let plantedAt: String?

    init(collectUrl: String? = nil, certificateUrl: String? = nil,
         speciesName: String? = nil, commonName: String? = nil, speciesImage: String? = nil,
         projectName: String? = nil, projectUrl: String? = nil, country: String? = nil,
         lifeTimeCo2: Int? = nil, reason: String? = nil, plantedAt: String? = nil) {
        self.collectUrl = collectUrl
        self.certificateUrl = certificateUrl
        self.speciesName = speciesName
        self.commonName = commonName
        self.speciesImage = speciesImage
        self.projectName = projectName
        self.projectUrl = projectUrl
        self.country = country
        self.lifeTimeCo2 = lifeTimeCo2
        self.reason = reason
        self.plantedAt = plantedAt
    }

    var id: String {
        certificateUrl ?? collectUrl ?? "\(speciesName ?? "tree")-\(plantedAt ?? "")"
    }

    var plantedDate: Date? { ISO.date(plantedAt) }
    var certificateURL: URL? { certificateUrl.flatMap(URL.init(string:)) }
    var collectURL: URL? { collectUrl.flatMap(URL.init(string:)) }
    var projectURL: URL? { projectUrl.flatMap(URL.init(string:)) }
    var speciesImageURL: URL? { speciesImage.flatMap(URL.init(string:)) }

    /// Friendly name first ("Grey Mangrove"), latin as the fallback.
    var displaySpecies: String { commonName ?? speciesName ?? "A tree" }
    /// Latin name, only when it adds something beyond the headline.
    var displayLatin: String? { commonName != nil ? speciesName : nil }

    /// Humanized grant reason (`streak_7` → "7-day care streak").
    var displayReason: String? {
        guard let reason, !reason.isEmpty else { return nil }
        if reason.hasPrefix("streak_"), let days = Int(reason.dropFirst("streak_".count)) {
            return "\(days)-day care streak"
        }
        if reason == "referral_joined" { return "Joined via invite" }
        if reason.hasPrefix("referral_") { return "Invited a friend" }
        if reason.hasPrefix("care_"), let n = Int(reason.dropFirst("care_".count)) {
            return "\(n) care tasks on time"
        }
        if reason == "annual_subscription" { return "Annual subscription" }
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

// MARK: - Community forest (`GET /trees/community`)

/// Every tree Verdancy has planted, as Tree-Nation's own public profile reports
/// it. This is deliberately the partner's number rather than a count we derive:
/// it's the same figure anyone can check at `profileUrl`, which is what makes it
/// proof instead of marketing.
struct CommunityForest: Codable, Hashable {
    let totalTrees: Int
    let co2Tons: Double
    let profileUrl: String
    let trees: [CommunityTree]

    var profileURL: URL? { URL(string: profileUrl) }
    /// Tonnes read oddly below 1 t; grams below 1 kg are noise. Pick the unit.
    var co2Display: String {
        co2Tons >= 1 ? String(format: "%.1f t", co2Tons) : "\(Int((co2Tons * 1000).rounded())) kg"
    }
    static let empty = CommunityForest(totalTrees: 0, co2Tons: 0, profileUrl: "", trees: [])
}

/// One entry in the community feed. Tree-Nation groups plantings, so `quantity`
/// can exceed 1, and their `message` already names the species, project and
/// country — we show their sentence rather than re-deriving one from prose.
struct CommunityTree: Codable, Hashable, Identifiable {
    let id: Int
    let quantity: Int
    let message: String?
    let image: String?
    let plantedAt: String?
    let certificateUrl: String?
    let collectUrl: String?

    var plantedDate: Date? { ISO.date(plantedAt) }
    var certificateURL: URL? { certificateUrl.flatMap(URL.init(string:)) }
}
