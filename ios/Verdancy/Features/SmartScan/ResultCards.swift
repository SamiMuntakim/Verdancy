import SwiftUI

/// Identify result — identity only: name, taxonomy, and pet toxicity (iOS-PRD §3.2/§6).
/// The care schedule comes later, tailored to the plant's environment.
///
/// The hero of the scan flow (and the natural App Store screenshot): the user's own
/// photo carries the card, with the verdict — name, confidence, pet-safety — read
/// straight off it. Pass `jpeg` for the full-bleed photo header; without it the card
/// falls back to a text header (previews, or any caller lacking the image).
struct CareCardView: View {
    let card: CareCard
    var jpeg: Data? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if card.isUnidentified {
                    unidentifiedGuidance
                } else {
                    petSafetyVerdict
                    if let taxonomy = card.taxonomy { taxonomyChips(taxonomy) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Color.separator.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 6)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let jpeg, let image = UIImage(data: jpeg) {
            photoHeader(image)
        } else {
            textHeader
        }
    }

    /// Full-bleed photo with a bottom scrim, the name reversed out over it, and a
    /// frosted confidence badge floated top-trailing — the "we found it in *your*
    /// photo" moment.
    private func photoHeader(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 170)
            }
            .overlay(alignment: .topTrailing) {
                confidencePill.padding(Theme.Space.m)
            }
            .overlay(alignment: .bottomLeading) {
                nameBlock(onPhoto: true).padding(Theme.Space.l)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: Theme.Radius.card,
                    topTrailingRadius: Theme.Radius.card, style: .continuous))
    }

    private var textHeader: some View {
        HStack(alignment: .top) {
            nameBlock(onPhoto: false)
            Spacer()
            confidencePill
        }
        .padding(Theme.Space.l)
        .padding(.bottom, 0)
    }

    private func nameBlock(onPhoto: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.commonName)
                .font(.title.weight(.bold))
                .foregroundStyle(onPhoto ? .white : Theme.Color.textPrimary)
            Text(card.taxonomy?.scientificName ?? card.species.capitalized)
                .font(.subheadline.italic())
                .foregroundStyle(onPhoto ? .white.opacity(0.9) : Theme.Color.textSecondary)
        }
        .shadow(color: onPhoto ? .black.opacity(0.35) : .clear, radius: 8, y: 1)
    }

    /// Frosted so it reads on any photo. Hidden for unidentified plants — a
    /// "Low confidence" badge over an unknown plant reads as a failure, and the
    /// body guidance already owns that state.
    @ViewBuilder
    private var confidencePill: some View {
        if !card.isUnidentified {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(confidenceColor)
                Text("\(card.confidence) match")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(jpeg != nil ? .white : Theme.Color.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule())
        }
    }

    private var confidenceColor: Color {
        switch card.confidence.lowercased() {
        case "high": return Theme.Color.leaf
        case "medium": return Theme.Color.warning
        default: return Theme.Color.terracotta
        }
    }

    // MARK: Body

    private var unidentifiedGuidance: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("We're not sure about this one")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Try a clearer, well-lit photo of the leaves — or save it as Unidentified for now.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Verdancy's signature safety check — shown as a warning when toxic, and as a
    /// positive affirmation when safe (the reassuring state that sells the value,
    /// and photographs well). Silent only when toxicity is genuinely unknown.
    @ViewBuilder
    private var petSafetyVerdict: some View {
        if card.toxicityLevel?.isConcerning == true {
            safetyRow(
                icon: "pawprint.fill", tint: Theme.Color.danger,
                title: "Toxic if ingested", detail: PetContext.toxicityWarning)
        } else if card.toxicityLevel == .low || card.toxicityLevel == Toxicity.none {
            safetyRow(
                icon: "checkmark.shield.fill", tint: Theme.Color.leaf,
                title: PetContext.hasPets ? "Pet-safe" : "Non-toxic",
                detail: PetContext.hasPets
                    ? "Safe to keep around curious paws."
                    : "Safe around pets and children.")
        }
    }

    private func safetyRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(detail).font(.caption).foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }

    private func taxonomyChips(_ taxonomy: Taxonomy) -> some View {
        HStack(spacing: Theme.Space.m) {
            taxonomyChip(label: "Family", value: taxonomy.family)
            taxonomyChip(label: "Genus", value: taxonomy.genus)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func taxonomyChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.Color.leaf.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

/// Diagnose result — the triage card (iOS-PRD §3.2). Mirrors `CareCardView`: the
/// user's own photo is the card's header, with the issue and severity read straight
/// off it, so identify and diagnose share one visual language. Pass `jpeg` for the
/// photo hero; without it the card falls back to a text header (previews).
struct DiagnosisCardView: View {
    let card: DiagnosisCard
    var jpeg: Data? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(card.likelyCause)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(card.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Theme.Color.leaf))
                            Text(step).font(.subheadline)
                        }
                    }
                }
                ConfidenceBadge(confidence: card.confidence)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Color.separator.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 6)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let jpeg, let image = UIImage(data: jpeg) {
            photoHeader(image)
        } else {
            textHeader
        }
    }

    /// Full-bleed photo with a bottom scrim, the issue reversed out over it, and a
    /// frosted severity pill floated top-trailing — the "here's what's wrong, in
    /// *your* photo" moment. Shorter than the identify hero (210 vs 260) to keep the
    /// numbered steps in view.
    private func photoHeader(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 150)
            }
            .overlay(alignment: .topTrailing) {
                severityPill.padding(Theme.Space.m)
            }
            .overlay(alignment: .bottomLeading) {
                issueBlock(onPhoto: true).padding(Theme.Space.l)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: Theme.Radius.card,
                    topTrailingRadius: Theme.Radius.card, style: .continuous))
    }

    private var textHeader: some View {
        HStack(alignment: .top) {
            issueBlock(onPhoto: false)
            Spacer()
            SeverityChip(severity: card.severityLevel)
        }
        .padding(Theme.Space.l)
    }

    private func issueBlock(onPhoto: Bool) -> some View {
        Text(card.issue)
            .font(.title2.weight(.bold))
            .foregroundStyle(onPhoto ? .white : Theme.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: onPhoto ? .black.opacity(0.35) : .clear, radius: 8, y: 1)
    }

    /// Frosted so it reads on any photo — a severity dot + label, matching the
    /// identify card's confidence pill.
    private var severityPill: some View {
        HStack(spacing: 5) {
            Circle().fill(severityColor).frame(width: 7, height: 7)
            Text(card.severityLevel?.rawValue ?? "—")
                .font(.caption.weight(.semibold))
                .foregroundStyle(jpeg != nil ? .white : Theme.Color.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule())
    }

    private var severityColor: Color {
        switch card.severityLevel {
        case .critical: return Theme.Color.danger
        case .moderate: return Theme.Color.warning
        case .minor, .healthy: return Theme.Color.leaf
        case nil: return Theme.Color.textSecondary
        }
    }
}

struct CareRow: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 28, height: 28)
                .background(Theme.Color.leaf.opacity(0.12), in: Circle())
            Text(label).foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct ConfidenceBadge: View {
    let confidence: String

    private var dotColor: Color {
        switch confidence.lowercased() {
        case "high": return Theme.Color.leaf
        case "medium": return Theme.Color.warning
        default: return Theme.Color.terracotta
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Text("\(confidence) confidence")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.Color.separator.opacity(0.5))
        .clipShape(Capsule())
        .foregroundStyle(Theme.Color.textSecondary)
    }
}

struct SeverityChip: View {
    let severity: Severity?
    var body: some View {
        Text(severity?.rawValue ?? "-")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch severity {
        case .critical: return Theme.Color.danger
        case .moderate: return Theme.Color.warning
        case .minor: return Theme.Color.leaf
        case .healthy: return Theme.Color.leaf
        case nil: return Theme.Color.textSecondary
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            CareCardView(card: .sample)
            CareCardView(card: .sampleUnknown)
            DiagnosisCardView(card: .sample)
        }
        .padding()
    }
}
