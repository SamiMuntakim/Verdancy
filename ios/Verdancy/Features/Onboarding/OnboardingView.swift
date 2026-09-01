import SwiftUI

/// Dedicated onboarding flow (iOS-PRD §8.1): one show-the-aha hook screen → a short
/// personalization quiz whose answers visibly accumulate into "your plan" → a
/// plan-assembly beat → **sign-up only on the final screen**, reframed as saving the
/// plan they just built. It's a linear funnel — the auth buttons never appear before
/// the end, so nobody can sign up mid-quiz and skip the flow. No permission prompts
/// front-loaded; the first scan (and its seedling payoff) comes *after* sign-up in
/// `FirstRunView`. Pets at home → toxicity warnings speak to *their* home.
enum PetContext {
    private static let key = "verdancy.hasPets"

    static var hasPets: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The toxicity warning, personalized when we know pets are around.
    static var toxicityWarning: String {
        hasPets
            ? "Toxic to pets. Keep it out of reach of curious paws"
            : "Toxic to pets and children if ingested"
    }
}

/// The quiz answers we keep locally for personalization (iOS-PRD §8.1: "keep any
/// quiz short"). Coarse enum-like values only — no free text — mirroring the
/// Analytics privacy rule. Backed by UserDefaults; read anywhere in the app.
enum OnboardingProfile {
    /// Coarse bucket for how many plants the user keeps.
    static var plantCount: String? {
        get { UserDefaults.standard.string(forKey: "verdancy.onboarding.plantCount") }
        set { UserDefaults.standard.set(newValue, forKey: "verdancy.onboarding.plantCount") }
    }

    /// Self-reported experience level — tunes copy tone later on.
    static var experience: String? {
        get { UserDefaults.standard.string(forKey: "verdancy.onboarding.experience") }
        set { UserDefaults.standard.set(newValue, forKey: "verdancy.onboarding.experience") }
    }

    /// How bright the user's space is — drives care + placement tips.
    static var light: String? {
        get { UserDefaults.standard.string(forKey: "verdancy.onboarding.light") }
        set { UserDefaults.standard.set(newValue, forKey: "verdancy.onboarding.light") }
    }

    /// The user's self-reported biggest struggle — the plan leans into it.
    static var struggle: String? {
        get { UserDefaults.standard.string(forKey: "verdancy.onboarding.struggle") }
        set { UserDefaults.standard.set(newValue, forKey: "verdancy.onboarding.struggle") }
    }
}

/// One selectable choice inside a quiz question.
private struct QuizOption: Identifiable {
    let value: String
    let label: String
    let icon: String
    var id: String { value }
}

/// A single-select quiz question rendered as a page in onboarding.
private struct QuizQuestion: Identifiable {
    let id: String        // analytics/storage key, e.g. "source"
    let title: String
    let subtitle: String
    /// Dashed placeholder chip in the "your plan so far" strip while unanswered.
    let pendingChip: String?
    let options: [QuizOption]
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var forward = true
    @State private var isWorking = false
    @State private var error: String?
    @State private var petsAnswer: Bool?
    @State private var showEmail = false

    /// Selected value per quiz question, keyed by `QuizQuestion.id`.
    @State private var answers: [String: String] = [:]

    /// The short quiz (iOS-PRD §8.1). Pets is a separate final page below.
    private let questions: [QuizQuestion] = [
        QuizQuestion(
            id: "plantCount",
            title: "How many plants live with you?",
            subtitle: "Your reminders and tips are sized to your collection.",
            pendingChip: "Collection size…",
            options: [
                QuizOption(value: "none", label: "No plants yet", icon: "sparkles"),
                QuizOption(value: "1_5", label: "1 to 5", icon: "leaf"),
                QuizOption(value: "6_10", label: "6 to 10", icon: "leaf.fill"),
                QuizOption(value: "11_25", label: "11 to 25", icon: "tree"),
                QuizOption(value: "25_plus", label: "More than 25", icon: "tree.fill"),
            ]
        ),
        QuizQuestion(
            id: "experience",
            title: "How experienced are you with plants?",
            subtitle: "So we can pitch our tips at the right level.",
            pendingChip: "Experience level…",
            options: [
                QuizOption(value: "new", label: "Brand new", icon: "sparkles"),
                QuizOption(value: "some", label: "Some experience", icon: "leaf.fill"),
                QuizOption(value: "expert", label: "Very experienced", icon: "crown.fill"),
            ]
        ),
        QuizQuestion(
            id: "light",
            title: "How bright is your space?",
            subtitle: "Light drives almost everything about care.",
            pendingChip: "Light level…",
            options: [
                QuizOption(value: "bright", label: "Bright and sunny", icon: "sun.max.fill"),
                QuizOption(value: "medium", label: "Medium, indirect", icon: "cloud.sun.fill"),
                QuizOption(value: "low", label: "Low light", icon: "moon.fill"),
                QuizOption(value: "mixed", label: "A mix of spots", icon: "sparkles"),
            ]
        ),
        QuizQuestion(
            id: "struggle",
            title: "What trips you up most?",
            subtitle: "We'll aim your plan straight at it.",
            pendingChip: "Your struggle…",
            options: [
                QuizOption(value: "overwater", label: "Overwatering", icon: "drop.fill"),
                QuizOption(value: "forget", label: "Forgetting to water", icon: "bell.slash.fill"),
                QuizOption(value: "pests", label: "Pests and disease", icon: "ladybug.fill"),
                QuizOption(value: "light", label: "Not enough light", icon: "cloud.sun.fill"),
            ]
        ),
    ]

    /// Total steps: hook + quiz questions + pets + plan assembly + plan reveal + sign-up.
    private var totalPages: Int { 1 + questions.count + 4 }
    private var petsPage: Int { totalPages - 4 }
    private var buildPage: Int { totalPages - 3 }
    private var revealPage: Int { totalPages - 2 }
    private var authPage: Int { totalPages - 1 }
    /// Quiz step number for the "n of 4" header label (pets is the last question).
    private var questionNumber: Int? {
        if page >= 1 && page <= questions.count { return page }
        if page == petsPage { return questions.count + 1 }
        return nil
    }

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: false) {
                    currentPage
                        .id(page)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.top, Theme.Space.xl)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .frame(maxHeight: .infinity)

                footer
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xl)
            }
        }
        .onAppear {
            #if DEBUG
            // Screenshot: jump straight to the personalized plan reveal with a
            // representative set of answers (mock mode only).
            if AppConfig.useMockAuth, CommandLine.arguments.contains("-onboardingReveal") {
                answers = ["plantCount": "6_10", "experience": "some",
                           "light": "medium", "struggle": "overwater"]
                petsAnswer = true
                PetContext.hasPets = true
                page = revealPage
                Analytics.log("onboarding_viewed")
                return
            }
            #endif
            // Someone who already onboarded on this device is here to sign back in
            // (they signed out, or their session expired) — drop them on the auth
            // page instead of replaying the intro and quiz, rehydrating their old
            // answers so the plan card still reflects *their* home. Back still
            // works if they want to walk through it again.
            if AppModel.hasOnboarded {
                page = authPage
                if let v = OnboardingProfile.plantCount { answers["plantCount"] = v }
                if let v = OnboardingProfile.experience { answers["experience"] = v }
                if let v = OnboardingProfile.light { answers["light"] = v }
                if let v = OnboardingProfile.struggle { answers["struggle"] = v }
                petsAnswer = PetContext.hasPets
            }
            Analytics.log("onboarding_viewed")
        }
        .sheet(isPresented: $showEmail) {
            EmailAuthView().environment(app)
        }
    }

    // MARK: Chrome (progress + back)

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.Color.surface, in: Circle())
            }
            .opacity(page == 0 || page == buildPage ? 0 : 1)
            .disabled(page == 0 || page == buildPage)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Color.separator)
                    Capsule()
                        .fill(Theme.leafGradient)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 6)

            // Question count during the quiz; a clear frame elsewhere keeps the bar centered.
            Group {
                if let n = questionNumber {
                    Text("\(n) of \(questions.count + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 38, height: 32)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.m)
        .animation(.easeOut(duration: 0.2), value: page)
    }

    private var progress: CGFloat { CGFloat(page + 1) / CGFloat(totalPages) }

    // MARK: Pages

    @ViewBuilder
    private var currentPage: some View {
        if page == 0 {
            hookPage
        } else if page <= questions.count {
            questionPage(questions[page - 1])
        } else if page == petsPage {
            petsQuiz
        } else if page == buildPage {
            PlanBuildView(rows: planBuildRows) {
                if page == buildPage { goNext() }
            }
        } else if page == revealPage {
            planRevealHero
        } else {
            planSaveHero
        }
    }

    // MARK: Hook (page 0) — the website hero, in-app (verdancy.app: visual first
    // on small screens, then pill → headline → lede; same tokens both themes)

    private var hookPage: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: Theme.Space.l)
            // Quiet masthead — the first place the name and mark appear, above the
            // website hero it's recreating.
            BrandLockup()
            HeroScanCard()
            VStack(spacing: Theme.Space.m) {
                TreesLivePill()

                (Text("You grow plants.\n").foregroundStyle(Theme.Color.textPrimary)
                 + Text("We grow forests.").foregroundStyle(Theme.leafGradient))
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: Theme.Space.l)
        }
        // Center the hero in the scroll viewport so it reads as a poster, not a
        // top-anchored column with dead space above the footer. Cancel the scroll
        // content's top padding so "fill the viewport" means the true viewport.
        .padding(.top, -Theme.Space.xl)
        .containerRelativeFrame(.vertical)
    }

    /// A single-select quiz question: eyebrow, title, subtitle, then a vertical list
    /// of option rows. Tapping an option records it and advances.
    private func questionPage(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("SHAPING YOUR CARE PLAN")
                    .font(.caption.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(Theme.Color.leaf)
                Text(question.title)
                    .font(.title.weight(.bold))
                Text(question.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            VStack(spacing: Theme.Space.s) {
                ForEach(question.options) { option in
                    OptionRow(
                        label: option.label,
                        icon: option.icon,
                        selected: answers[question.id] == option.value
                    ) {
                        answer(question, option)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answer(_ question: QuizQuestion, _ option: QuizOption) {
        answers[question.id] = option.value
        switch question.id {
        case "plantCount": OnboardingProfile.plantCount = option.value
        case "experience": OnboardingProfile.experience = option.value
        case "light": OnboardingProfile.light = option.value
        case "struggle": OnboardingProfile.struggle = option.value
        default: break
        }
        Analytics.log("quiz_answered", ["question": question.id, "answer": option.value])
        Haptics.success()
        // Gently advance so the quiz feels like a flow, not a form.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { goNext() }
    }

    private var petsQuiz: some View {
        VStack(spacing: Theme.Space.xl) {
            IconBadge(systemImage: "pawprint.fill", size: 128, tint: Theme.Color.terracotta)
            VStack(spacing: Theme.Space.m) {
                Text("Any pets at home?")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("We'll flag any plant that isn't safe for curious paws.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            HStack(spacing: Theme.Space.m) {
                QuizChoice(label: "Yes", icon: "pawprint.fill",
                           selected: petsAnswer == true) { answerPets(true) }
                QuizChoice(label: "No", icon: "house.fill",
                           selected: petsAnswer == false) { answerPets(false) }
            }
        }
    }

    private func answerPets(_ hasPets: Bool) {
        petsAnswer = hasPets
        PetContext.hasPets = hasPets
        Analytics.log("quiz_answered", ["question": "pets", "answer": hasPets ? "yes" : "no"])
        Haptics.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { goNext() }
    }

    // MARK: Plan assembly + the personalized plan

    /// The plan facts the quiz earned, reused by the assembly page and the summary
    /// card — so what the user watched being built is exactly what they're asked to
    /// save. Watering is always conservative (iOS-PRD §6: overwatering kills).
    private var planBuildRows: [PlanBuildView.Row] {
        var rows: [PlanBuildView.Row] = []
        rows.append(.init(icon: "leaf.fill", text: collectionLine))
        rows.append(.init(icon: "sun.max.fill", text: lightLine.title))
        rows.append(.init(icon: struggleLine.icon, text: struggleLine.title))
        rows.append(.init(icon: "bell.fill", text: paceLine.title))
        rows.append(.init(icon: "pawprint.fill",
                          text: petsAnswer == true ? "Pet-safety alerts switched on"
                                                   : "Toxicity flags on every scan"))
        return rows
    }

    /// Biggest-struggle → the plan line that leans straight into it, with the glyph
    /// that names the problem (a generic bullseye reads as a camera lens).
    private var struggleLine: (icon: String, tone: Theme.Tone, title: String, detail: String) {
        switch answers["struggle"] {
        case "overwater":
            return ("drop.fill", .water, "Overwater-proof watering",
                    "We space watering out and warn before you pour")
        case "forget":
            return ("alarm.fill", .forest, "Reminders that reach you",
                    "Nudges timed so a watering never slips")
        case "pests":
            return ("ladybug.fill", .ember, "Early pest & disease checks",
                    "Diagnose trouble from a photo before it spreads")
        case "light":
            return ("lightbulb.fill", .sun, "Light-first placement",
                    "We flag when a plant needs a brighter spot")
        default:
            return ("target", .forest, "Aimed at your weak spot",
                    "Your plan leans into what trips you up")
        }
    }

    /// Light level → placement and watering guidance for their space.
    private var lightLine: (title: String, detail: String) {
        switch answers["light"] {
        case "bright":
            return ("Tuned for bright rooms", "Sun-loving picks, watering paced to match")
        case "medium":
            return ("Tuned for indirect light", "The sweet spot for most houseplants")
        case "low":
            return ("Low-light friendly", "Shade-tolerant picks and gentler watering")
        case "mixed":
            return ("Balanced for mixed light", "Placement tips room by room")
        default:
            return ("Matched to your light", "Placement tips for your space")
        }
    }

    /// The pacing sentence under `collectionLine` on the reveal card.
    private var collectionDetail: String {
        switch answers["plantCount"] {
        case "none": return "We start slow and build as you add more"
        case "1_5": return "A light routine that won't take over your week"
        case "6_10": return "Enough structure to keep a full shelf on track"
        case "11_25", "25_plus": return "Built to keep a big collection from slipping"
        default: return "Care paced to how much you keep"
        }
    }

    private var collectionLine: String {
        switch answers["plantCount"] {
        case "none": return "Ready for your very first plant"
        case "1_5": return "Sized for 1 to 5 plants"
        case "6_10": return "Sized for 6 to 10 plants"
        case "11_25": return "Sized for 11 to 25 plants"
        case "25_plus": return "Sized for a 25+ plant jungle"
        default: return "Sized to your collection"
        }
    }

    private var paceLine: (title: String, detail: String) {
        switch answers["experience"] {
        case "expert":
            return ("Expert-level care depth", "Tips that skip the basics")
        case "some":
            return ("Reminders at your pace", "Tips that build on what you know")
        default:
            return ("Gentle reminders, beginner pace", "Tips pitched for your first plants")
        }
    }

    /// The "aha" reveal (the article's Personalized Plan Reveal): their numbers and
    /// their tailored plan, assembled from the quiz they just answered — so the next
    /// screen asks them to save *their own plan*, not to buy ours. This is also the
    /// peak-delight moment where we request an App Store rating (once), before the
    /// paywall, to seed social proof.
    private var planRevealHero: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Your care plan is ready")
                    .font(.largeTitle.weight(.bold))
                Text("Built from your answers. Tuned to your home, your plants, "
                     + "and what trips you up.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            // Their numbers, on the house strip the Trees tab uses for its own
            // headline figures — the quiz turned into a plan at a glance.
            HeroStatStrip(stats: [
                .init(value: collectionStat, label: "your plants"),
                .init(value: "\(revealRows.count)", label: "care rules"),
                .init(value: "30", label: "days planned"),
            ])

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    GlyphTile(systemImage: "house.fill", tone: .leaf, size: 26)
                    Text("Made for your home")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.Color.leafDeep)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.l)
                .background(Theme.Color.leaf.opacity(0.10))

                VStack(spacing: 0) {
                    ForEach(Array(revealRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(Theme.Color.separator) }
                        planRow(row)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Color.separator.opacity(0.7), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { Analytics.log("plan_revealed") }
    }

    /// One tailored promise in the reveal card.
    private struct RevealRow: Identifiable {
        let id = UUID()
        let icon: String
        let tone: Theme.Tone
        let title: String
        let detail: String
    }

    /// The reveal's rows, built once so the "care rules" figure above the card
    /// counts the rules actually printed on it.
    private var revealRows: [RevealRow] {
        var rows: [RevealRow] = []
        rows.append(.init(icon: "leaf.fill", tone: .leaf,
                          title: collectionLine, detail: collectionDetail))
        // The standing conservative-watering promise, unless the user's own
        // weak spot is overwatering — then the tailored row below says the same
        // thing better, and printing both reads like padding.
        if answers["struggle"] != "overwater" {
            rows.append(.init(
                icon: "drop.fill", tone: .water,
                title: "Conservative watering windows",
                detail: "Overwatering is the #1 plant killer, so we water less often"))
        }
        rows.append(.init(icon: "sun.max.fill", tone: .sun,
                          title: lightLine.title, detail: lightLine.detail))
        rows.append(.init(icon: struggleLine.icon, tone: struggleLine.tone,
                          title: struggleLine.title, detail: struggleLine.detail))
        rows.append(.init(
            icon: petsAnswer == true ? "pawprint.fill" : "shield.fill", tone: .ember,
            title: petsAnswer == true ? "Pet-safety alerts on every scan"
                                      : "Toxicity flags on every scan",
            detail: petsAnswer == true
                ? "Toxic plants called out before they come home"
                : "Know what's safe before it comes home"))
        rows.append(.init(icon: "bell.fill", tone: .leaf,
                          title: paceLine.title, detail: paceLine.detail))
        return rows
    }

    /// Short collection value for the reveal's stat row.
    private var collectionStat: String {
        switch answers["plantCount"] {
        case "none": return "First"
        case "1_5": return "1–5"
        case "6_10": return "6–10"
        case "11_25": return "11–25"
        case "25_plus": return "25+"
        default: return "Your"
        }
    }

    /// The final page: the *only* place auth appears — framed as saving the plan
    /// they just watched being built. Buttons live in `footer`.
    private var planSaveHero: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // Returning users (signed out) land straight here, so this is where they
            // meet the brand — a quiet lockup above the sign-up.
            BrandLockup()
                .padding(.bottom, Theme.Space.s)
            ZStack {
                Circle().fill(Theme.Color.leaf.opacity(0.14)).frame(width: 72, height: 72)
                Image(systemName: "bookmark.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Theme.Color.leaf)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Save your plan")
                    .font(.title.weight(.bold))
                Text("Create a free account to keep your plan, then scan your first plant. No credit card.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planRow(_ row: RevealRow) -> some View {
        HStack(spacing: Theme.Space.m) {
            GlyphTile(systemImage: row.icon, tone: row.tone, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.subheadline.weight(.semibold))
                Text(row.detail).font(.footnote).foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    // MARK: Footer (Continue on the hook, plan chips during the quiz, auth at the end)

    @ViewBuilder
    private var footer: some View {
        if page == 0 {
            VStack(spacing: Theme.Space.m) {
                Button("Get started") { goNext() }
                    .buttonStyle(.primary)
                Text("Free to start · No credit card")
                    .font(.caption2)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        } else if page <= questions.count || page == petsPage {
            planSoFarStrip
        } else if page == revealPage {
            VStack(spacing: Theme.Space.m) {
                Button("Save my plan") { goNext() }
                    .buttonStyle(.primary)
                Text("Free to start · No credit card")
                    .font(.caption2)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        } else if page == authPage {
            authButtons
        }
        // The plan-assembly page advances itself — no footer.
    }

    /// The investment strip: answers visibly accumulate into the plan, so each tap
    /// buys something the sign-up page later asks them to save.
    private var planSoFarStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Your plan so far")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            FlowChips(chips: earnedChips, pending: pendingChip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var earnedChips: [String] {
        var chips: [String] = []
        if answers["plantCount"] != nil { chips.append(collectionLine) }
        if answers["experience"] != nil { chips.append(paceLine.title) }
        if answers["light"] != nil { chips.append(lightLine.title) }
        if answers["struggle"] != nil { chips.append(struggleLine.title) }
        if let pets = petsAnswer {
            chips.append(pets ? "Pet-safety alerts on" : "Toxicity flags on")
        }
        return chips
    }

    private var pendingChip: String? {
        if page >= 1 && page <= questions.count { return questions[page - 1].pendingChip }
        if page == petsPage { return "Pets at home…" }
        return nil
    }

    private var authButtons: some View {
        VStack(spacing: Theme.Space.m) {
            AppleSignInButton(isWorking: isWorking) {
                await signIn("apple") { try await app.signInWithApple() }
            }
            GoogleSignInButton(isWorking: isWorking) {
                await signIn("google") { try await app.signInWithGoogle() }
            }
            Button("Continue with email") { showEmail = true }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Color.textSecondary)
                .disabled(isWorking)
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.Color.danger)
            }
            // Markdown links so "Terms" and "Privacy Policy" are actually tappable
            // at the moment of consent, not just named.
            Text(.init(
                "No credit card to sign up. By continuing you agree to our " +
                "[Terms of Service](\(AppConfig.termsURL.absoluteString)) and " +
                "[Privacy Policy](\(AppConfig.privacyURL.absoluteString))."))
                .font(.caption2)
                .foregroundStyle(Theme.Color.textSecondary)
                .tint(Theme.Color.leaf)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Navigation

    private func goNext() {
        guard page < authPage else { return }
        forward = true
        withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
    }

    private func goBack() {
        guard page > 0 else { return }
        forward = false
        // The plan-assembly beat auto-advances, so never land on it going back
        // (from the reveal page, step straight back to the pets question).
        var target = page - 1
        if target == buildPage { target = petsPage }
        withAnimation(.easeInOut(duration: 0.28)) { page = target }
    }

    private func signIn(_ method: String, _ action: @escaping () async throws -> Void) async {
        isWorking = true
        error = nil
        Analytics.log("sign_in_started", ["method": method])
        do {
            try await action()
            Analytics.log("sign_in_succeeded", ["method": method])
        } catch {
            self.error = "Sign in failed. Please try again."
            Analytics.log("sign_in_failed", ["method": method])
        }
        isWorking = false
    }
}

// MARK: - Hook visual (ported from the verdancy.app hero phone mock)

/// The website hero's phone screen, rendered natively: scan photo with the plant
/// art, corner brackets and a glowing sweep line, then the identification result
/// panel — plus the two floating badges. Values are lifted from the site source
/// (Verdancy-Web `index.astro` / `verdancy.css`), not approximated.
/// The trust badge above the headline: a live-pulsing dot + a small tree glyph on a
/// leaf-tinted capsule. Signals that the tree count is real and publicly verifiable,
/// not a marketing figure.
private struct TreesLivePill: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // "live" dot: a solid core with an expanding, fading ring behind it.
            ZStack {
                Circle()
                    .fill(Theme.Color.leaf.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 0.9)
                Circle()
                    .fill(Theme.Color.leaf)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 20, height: 20)

            Text("Real trees, publicly counted")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.leaf)

            Image(systemName: "tree.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Color.leaf)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .background(Theme.Color.leaf.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Color.leaf.opacity(0.28), lineWidth: 1))
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct HeroScanCard: View {
    @Environment(\.colorScheme) private var scheme
    @State private var sweepDown = false

    /// `.scan-photo` background: #EAF6EC→#cfe9d4 light, #1f2a1e→#16201a dark.
    private var photoGradient: LinearGradient {
        let colors = scheme == .dark
            ? [Color(red: 0.122, green: 0.165, blue: 0.118), Color(red: 0.086, green: 0.125, blue: 0.102)]
            : [Color(red: 0.918, green: 0.965, blue: 0.925), Color(red: 0.812, green: 0.914, blue: 0.831)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            // .glow: soft radial leaf halo behind the card.
            RadialGradient(
                colors: [Theme.Color.leaf.opacity(0.18), .clear],
                center: .center, startRadius: 20, endRadius: 230
            )

            VStack(spacing: 0) {
                scanPhoto
                scanResult
            }
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Theme.Color.separator, lineWidth: 1)
            )
            .shadow(color: Theme.Color.leafDeep.opacity(0.16), radius: 25, y: 9)
            .padding(.horizontal, Theme.Space.xl)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                sweepDown = true
            }
        }
    }

    private var scanPhoto: some View {
        ZStack {
            photoGradient
            PlantArt()
                .padding(Theme.Space.xxl)
            CornerBrackets()
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(18)
            // .scan-sweep: a glowing line drifting down the frame and back.
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.Color.leaf)
                    .frame(height: 3)
                    .shadow(color: Theme.Color.leaf.opacity(0.9), radius: 7)
                    .padding(.horizontal, 18)
                    .offset(y: sweepDown ? geo.size.height - 22 : 22)
            }
        }
        .frame(height: 208)
        .clipped()
    }

    private var scanResult: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calathea orbifolia")
                        .font(.system(size: 17, weight: .bold))
                    Text("Marantaceae · Prayer-plant family")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
                Text("96%")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Color.leaf)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.Color.leaf.opacity(0.12), in: Capsule())
            }
            HStack(spacing: Theme.Space.s) {
                chip(icon: "checkmark", label: "Pet-safe")
                chip(icon: nil, label: "Easy care")
            }
            VStack(alignment: .leading, spacing: 10) {
                careItem(icon: "drop", bold: "Water", rest: "in 4 days")
                careItem(icon: "sun.max", bold: "Light", rest: "bright, indirect")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
    }

    private func chip(icon: String?, label: String) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
            }
            Text(label).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.Color.leaf)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.Color.leaf.opacity(0.12), in: Capsule())
    }

    private func careItem(icon: String, bold: String, rest: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.Color.leaf)
                .frame(width: 20)
            (Text("\(bold) ").fontWeight(.semibold).foregroundStyle(Theme.Color.textPrimary)
             + Text(rest).foregroundStyle(Theme.Color.textSecondary))
                .font(.system(size: 13.5))
        }
    }
}

/// The hero's plant illustration, ported path-for-path from the site's inline SVG
/// (200×200 viewBox): a stem, four gradient leaves, and a light sprout leaf.
private struct PlantArt: View {
    private static let leafGradient = LinearGradient(
        colors: [Color(red: 0.435, green: 0.706, blue: 0.467),   // #6FB477
                 Color(red: 0.173, green: 0.361, blue: 0.2)],     // #2C5C33
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 200
            let dx = (size.width - 200 * s) / 2
            let dy = (size.height - 200 * s) / 2
            let t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)

            func draw(_ path: Path, opacity: Double, gradient: Bool = true, color: Color = .clear) {
                let scaled = path.applying(t)
                if gradient {
                    context.opacity = opacity
                    context.fill(scaled, with: .linearGradient(
                        Gradient(colors: [Color(red: 0.435, green: 0.706, blue: 0.467),
                                          Color(red: 0.173, green: 0.361, blue: 0.2)]),
                        startPoint: CGPoint(x: dx, y: dy),
                        endPoint: CGPoint(x: dx + 200 * s, y: dy + 200 * s)))
                } else {
                    context.opacity = opacity
                    context.fill(scaled, with: .color(color))
                }
                context.opacity = 1
            }

            // Stem: M100 175c0-40-4-70-4-70
            var stem = Path()
            stem.move(to: CGPoint(x: 100, y: 175))
            stem.addCurve(to: CGPoint(x: 96, y: 105),
                          control1: CGPoint(x: 100, y: 135), control2: CGPoint(x: 96, y: 105))
            context.stroke(stem.applying(t),
                           with: .color(Color(red: 0.243, green: 0.494, blue: 0.275)), // #3E7E46
                           style: StrokeStyle(lineWidth: 5 * s, lineCap: .round))

            // Left leaf: M96 118c-20-6-34-26-32-52 24 2 40 22 40 48
            var leafL = Path()
            leafL.move(to: CGPoint(x: 96, y: 118))
            leafL.addCurve(to: CGPoint(x: 64, y: 66),
                           control1: CGPoint(x: 76, y: 112), control2: CGPoint(x: 62, y: 92))
            leafL.addCurve(to: CGPoint(x: 104, y: 114),
                           control1: CGPoint(x: 88, y: 68), control2: CGPoint(x: 104, y: 88))
            draw(leafL, opacity: 0.95)

            // Right leaf: M104 112c22-4 36-24 36-50-24 0-42 20-42 46
            var leafR = Path()
            leafR.move(to: CGPoint(x: 104, y: 112))
            leafR.addCurve(to: CGPoint(x: 140, y: 62),
                           control1: CGPoint(x: 126, y: 108), control2: CGPoint(x: 140, y: 88))
            leafR.addCurve(to: CGPoint(x: 98, y: 108),
                           control1: CGPoint(x: 116, y: 62), control2: CGPoint(x: 98, y: 82))
            draw(leafR, opacity: 1)

            // Lower-left leaf: M98 128c-24 2-42 18-46 44 26 4 48-12 52-38
            var leafBL = Path()
            leafBL.move(to: CGPoint(x: 98, y: 128))
            leafBL.addCurve(to: CGPoint(x: 52, y: 172),
                            control1: CGPoint(x: 74, y: 130), control2: CGPoint(x: 56, y: 146))
            leafBL.addCurve(to: CGPoint(x: 104, y: 134),
                            control1: CGPoint(x: 78, y: 176), control2: CGPoint(x: 100, y: 160))
            draw(leafBL, opacity: 0.85)

            // Lower-right leaf: M102 132c24 0 44 14 50 40-26 6-50-8-56-34
            var leafBR = Path()
            leafBR.move(to: CGPoint(x: 102, y: 132))
            leafBR.addCurve(to: CGPoint(x: 152, y: 172),
                            control1: CGPoint(x: 126, y: 132), control2: CGPoint(x: 146, y: 146))
            leafBR.addCurve(to: CGPoint(x: 96, y: 138),
                            control1: CGPoint(x: 126, y: 178), control2: CGPoint(x: 102, y: 164))
            draw(leafBR, opacity: 0.9)

            // Sprout: M100 96c-14 0-24-14-24-34 18 0 28 14 28 34  (#8FD69A)
            var sprout = Path()
            sprout.move(to: CGPoint(x: 100, y: 96))
            sprout.addCurve(to: CGPoint(x: 76, y: 62),
                            control1: CGPoint(x: 86, y: 96), control2: CGPoint(x: 76, y: 82))
            sprout.addCurve(to: CGPoint(x: 104, y: 96),
                            control1: CGPoint(x: 94, y: 62), control2: CGPoint(x: 104, y: 76))
            draw(sprout, opacity: 0.9, gradient: false,
                 color: Color(red: 0.561, green: 0.839, blue: 0.604)) // #8FD69A
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Four L-shaped viewfinder brackets (site `.scan-frame`: 26px arms), drawn in
/// the padded rect.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let arm: CGFloat = 26
        // Top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // Top-right
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // Bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}

// MARK: - Plan assembly (the investment beat)

/// "Growing your care plan…": the quiz answers check themselves off one by one
/// around the dormant seedling, then the page advances itself. Pure theater — the
/// personalization is instant — but it converts the quiz into a *thing they own*
/// before the sign-up page asks them to save it.
private struct PlanBuildView: View {
    struct Row: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
    }

    let rows: [Row]
    let onFinished: () -> Void

    @State private var shownRows = 0
    @State private var ringProgress: CGFloat = 0.1

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            ZStack {
                Circle()
                    .fill(Theme.Color.leaf.opacity(0.08))
                    .frame(width: 150, height: 150)
                Circle()
                    .stroke(Theme.Color.separator, lineWidth: 7)
                    .frame(width: 150, height: 150)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Theme.Color.leaf, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(-90))
                Image(BudSprites.dormant)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 84, height: 84)
            }
            .padding(.top, Theme.Space.xxl)

            VStack(spacing: Theme.Space.s) {
                Text("Growing your care plan…")
                    .font(.title2.weight(.bold))
                Text("Putting your answers to work.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().overlay(Theme.Color.separator) }
                    HStack(spacing: Theme.Space.m) {
                        if i < shownRows {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.Color.leaf)
                        } else {
                            ProgressView().tint(Theme.Color.leaf)
                                .frame(width: 22, height: 22)
                        }
                        Text(row.text)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(i < shownRows ? Theme.Color.textPrimary
                                                           : Theme.Color.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Theme.Space.m)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .card()
        }
        .onAppear {
            Analytics.log("plan_build_shown")
            // Real delays, not animation delays: the checkmark/spinner swap is
            // structural, so the value change itself must be staggered.
            for i in 1...rows.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55 * Double(i)) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        shownRows = i
                        ringProgress = 0.1 + 0.9 * CGFloat(i) / CGFloat(rows.count)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55 * Double(rows.count) + 0.9) {
                onFinished()
            }
        }
    }
}

/// Wrapping row of plan chips: solid for earned facts, dashed for the one in
/// progress. Simple leading-aligned flow — the chip count is tiny.
private struct FlowChips: View {
    let chips: [String]
    let pending: String?

    var body: some View {
        FlowLayout(spacing: Theme.Space.s) {
            ForEach(chips, id: \.self) { chip in
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                    Text(chip).font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.Color.leafDeep)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 6)
                .background(Theme.Color.leaf.opacity(0.12), in: Capsule())
            }
            if let pending {
                Text(pending)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().strokeBorder(
                            Theme.Color.separator,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            }
        }
    }
}

/// Minimal wrapping layout for the chip strip.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrange(proposal: proposal, subviews: subviews)
        for (subview, point) in zip(subviews, placement.points) {
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

/// A full-width, single-line selectable row for multi-option quiz questions:
/// leading glyph, label, and a checkmark once chosen.
private struct OptionRow: View {
    let label: String
    let icon: String
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 24)
                    .foregroundStyle(selected ? Theme.Color.leaf : Theme.Color.textSecondary)
                Text(label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.leaf)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(selected ? Theme.Color.leaf.opacity(0.15) : Theme.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(selected ? Theme.Color.leaf : Theme.Color.separator,
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

private struct QuizChoice: View {
    let label: String
    let icon: String
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.l)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(selected ? Theme.Color.leaf.opacity(0.15) : Theme.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(selected ? Theme.Color.leaf : Theme.Color.separator,
                                  lineWidth: selected ? 2 : 1)
            )
            .foregroundStyle(selected ? Theme.Color.leaf : Theme.Color.textPrimary)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// HIG-styled Sign in with Apple trigger. Tapping it runs the native
/// `ASAuthorizationController` system sheet (see `NativeAppleAuthService`) — the
/// styling here matches Apple's button; the sheet itself is the system UI.
struct AppleSignInButton: View {
    let isWorking: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "apple.logo")
                    Text("Sign in with Apple").fontWeight(.medium)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(Color.white)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .disabled(isWorking)
    }
}

/// "Sign in with Google" trigger, styled to Google's Sign-In branding guidelines:
/// the official multi-color "G" mark (asset `GoogleLogo`, unmodified), the exact
/// neutral light/dark button colors, and the canonical label. Runs OAuth + PKCE in
/// an in-app browser (`GoogleSignInController`).
struct GoogleSignInButton: View {
    @Environment(\.colorScheme) private var scheme
    let isWorking: Bool
    let action: () async -> Void

    private var isDark: Bool { scheme == .dark }
    // Google's specified button colors.
    private var background: Color {
        isDark ? Color(red: 0.075, green: 0.075, blue: 0.078) : .white // #131314 / #FFFFFF
    }
    private var stroke: Color {
        isDark
            ? Color(red: 0.557, green: 0.569, blue: 0.561) // #8E918F
            : Color(red: 0.455, green: 0.467, blue: 0.459) // #747775
    }
    private var label: Color {
        isDark
            ? Color(red: 0.890, green: 0.890, blue: 0.890) // #E3E3E3
            : Color(red: 0.122, green: 0.122, blue: 0.122) // #1F1F1F
    }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 10) {
                Image("GoogleLogo")
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: 18, height: 18)
                Text("Sign in with Google").font(.system(size: 17, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(label)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
        }
        .disabled(isWorking)
    }
}

#Preview {
    OnboardingView().environment(AppModel(auth: MockAuthService()))
}
