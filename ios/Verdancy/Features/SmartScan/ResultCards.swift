import SwiftUI

/// Identify result — the care card (iOS-PRD §3.2/§6).
struct CareCardView: View {
    let card: CareCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.commonName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(card.species.capitalized)
                    .font(.subheadline.italic())
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            if card.isUnidentified {
                Label(
                    "We're not sure about this one — try a clearer, well-lit photo of the leaves.",
                    systemImage: "questionmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(Theme.Color.warning)
            } else {
                if let water = card.waterCadenceDays {
                    CareRow(icon: "drop.fill", label: "Water", value: "Every \(water) days")
                }
                if let fert = card.fertilizeCadenceDays {
                    CareRow(icon: "leaf.fill", label: "Fertilize", value: "Every \(fert) days")
                }
                CareRow(icon: "sun.max.fill", label: "Light", value: card.lightingNeeds)
            }

            if card.toxicityLevel?.isConcerning == true {
                Label(PetContext.toxicityWarning, systemImage: "pawprint.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Color.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(
                        Theme.Color.danger.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    )
            }

            ConfidenceBadge(confidence: card.confidence)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .card()
    }
}

/// Diagnose result — the triage card (iOS-PRD §3.2).
struct DiagnosisCardView: View {
    let card: DiagnosisCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(card.issue).font(.title3.weight(.semibold))
                Spacer()
                SeverityChip(severity: card.severityLevel)
            }
            Text(card.likelyCause)
                .font(.subheadline)
                .foregroundStyle(Theme.Color.textSecondary)

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
        .card()
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
        Text(severity?.rawValue ?? "—")
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
