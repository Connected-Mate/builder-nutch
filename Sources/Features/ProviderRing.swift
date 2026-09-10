import SwiftUI

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
///
/// When that provider is doing something right now, a second, much thinner arc
/// appears *inside* the ring, in the gap between the glyph and the track. It is
/// deliberately a different radius, a different weight and a neutral colour, so
/// it reads as a separate fact rather than as the usage number moving.
struct ProviderRing: View {
    /// Nil when the provider reports what is left but never says out of what —
    /// there is no arc to draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    let glyph: ProviderGlyph
    var displayMode: UsageDisplayMode = .used
    var isStale: Bool = false
    /// Blocked right now. Shown as spent whatever the arc says, because that is
    /// what it means for you — a ring reading 16% while the account is paused
    /// is technically true and practically a lie.
    var isBlocked: Bool = false
    var activity: ActivitySummary?
    /// A fetch this cell asked for, in flight.
    var isRefreshing: Bool = false
    /// Names a newly raised problem this ring is the subject of, and nothing
    /// else. Set, the glyph flashes three times and then holds; the red
    /// gradient behind it is what carries the state from there on.
    var attentionFlash: String? = nil
    /// Names a problem this ring's account has just recovered from. One soft
    /// swell, against the green skin.
    var resolvedPulse: String? = nil
    /// This account cannot take a session as it stands — an expired login, a
    /// blocked Keychain, a profile that is simply not connected.
    ///
    /// The ring then stops being a measurement and becomes a symptom: the mark
    /// goes red, the track dims and the arc is not drawn at all. Whatever this
    /// account last reported is no longer true of it, and a percentage that is
    /// no longer true is worse than no percentage.
    var needsAttention: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0

    private var band: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: usedFraction ?? 0)
    }
    private var sweep: CGFloat {
        guard let usedFraction else { return 0 }
        if isBlocked { return displayMode == .remaining ? 0 : 1 }
        return CGFloat(displayMode.fraction(fromUsedFraction: usedFraction))
    }

    var body: some View {
        ZStack {
            // Dimming applies to the usage reading only. Whether Claude is
            // working right now is known first-hand and stays at full strength
            // even when the percentage behind it has gone stale.
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)
                    .opacity(needsAttention ? 0.5 : 1)

                if usedFraction != nil, !needsAttention {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: sweep)
                        .stroke(
                            band.color,
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        // Refreshing spins the reading itself rather than
                        // overlaying a separate spinner: the thing being
                        // refetched is the thing that should move, and a second
                        // arc on the same track only competes with it.
                        .rotationEffect(.degrees(-90 + spin))
                        // A ring that snaps to a new value reads as a glitch; one
                        // that sweeps reads as a measurement being taken.
                        .animation(NotchMotion.reading, value: sweep)
                        .animation(NotchMotion.reading, value: band)
                }

                ProviderGlyphView(glyph: glyph)
                    // The whole message, in one mark. The brand logos render in
                    // their own colours, so this has to be a tint rather than a
                    // foreground style the image is free to ignore.
                    .foregroundStyle(needsAttention ? Palette.alert : Palette.textPrimary)
                    .modifier(BrokenGlyphTint(active: needsAttention))
                    // A spent limit dims its glyph so the ring reads as "waiting".
                    .opacity(band == .exhausted ? 0.35 : 1)
                    // The flash goes on the glyph alone, not on the ring: the
                    // ring is a measurement, and a measurement that pulses
                    // reads as a number nobody is sure of.
                    .attentionFlash(trigger: attentionFlash)
                    .resolvedPulse(trigger: resolvedPulse)
            }
            .opacity(isStale ? 0.45 : 1)

            if let activity, activity.state != .idle {
                ActivityArc(summary: activity)
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        // Pressed in while it works, and released when the answer lands. The
        // ring is the button, so the ring is what should feel pressed.
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Exactly one turn, and it stops by itself.
            //
            // The obvious spelling is a `repeatForever` linear spin started on
            // the way in and cancelled on the way out — but `repeatForever` does
            // not stop when you set the value back, and if the value you set is
            // the one it is already animating toward, nothing changes and it
            // simply keeps going. The ring then spins for ever after a refresh
            // that finished half a second in.
            //
            // A single finite turn has no cancellation problem at all: 360° is
            // the same angle as 0°, so it lands exactly where the reading
            // belongs. It eases out, so it settles rather than stopping dead.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) {
                spin += 360
            }
        }
    }
}

/// Forces a brand mark to the alert colour.
///
/// `foregroundStyle` alone is not enough. The provider marks are the real
/// service logos and render `.original`, which is the whole point of them —
/// they keep their own colours and ignore a tint. A broken account has to read
/// as broken whichever logo it wears, so the mark is used as a mask and the
/// colour is drawn through it.
private struct BrokenGlyphTint: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            Palette.alert.mask(content)
        } else {
            content
        }
    }
}

/// The inner indicator: a short arc that spins while work is happening, and a
/// full pulsing ring when something is blocked waiting on you.
private struct ActivityArc: View {
    let summary: ActivitySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var pulsing = false

    /// How much of the circle the moving arc covers.
    private let arcFraction: CGFloat = 0.25

    private var inset: CGFloat {
        (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2
    }

    var body: some View {
        Group {
            switch summary.state {
            case .working: spinner
            case .waiting: pulse
            case .idle:    EmptyView()
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }

    private var spinner: some View {
        Circle()
            .inset(by: inset)
            .trim(from: 0, to: arcFraction)
            .stroke(
                summary.color,
                style: StrokeStyle(lineWidth: NotchLayout.activityStroke, lineCap: .round)
            )
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
            .onDisappear { spinning = false }
    }

    private var pulse: some View {
        Circle()
            .inset(by: inset)
            .stroke(summary.color, lineWidth: NotchLayout.activityStroke)
            .opacity(pulsing ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
    }
}

/// A ring and the percent burned underneath it.
struct ProviderCell: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    var isRefreshing: Bool = false
    var displayMode: UsageDisplayMode = .used
    /// Passed straight through to the ring's glyph — see `ProviderRing`.
    var attentionFlash: String? = nil
    var resolvedPulse: String? = nil
    var needsAttention: Bool = false

    /// A dash, not "0%": nothing read is not the same as nothing used. Nothing
    /// at all when the account is broken — see `ProviderRing.needsAttention`.
    private var percentText: String {
        if needsAttention { return "" }
        return snapshot.hasReading ? snapshot.headlineText(for: displayMode) : "—"
    }

    /// The label as drawn, so a test can state the rule without a renderer.
    var percentTextForTesting: String { percentText }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                usedFraction: snapshot.hasReading ? snapshot.ringFraction : nil,
                glyph: snapshot.glyph,
                displayMode: displayMode,
                isStale: snapshot.status.isStale || !snapshot.hasReading,
                isBlocked: snapshot.block != nil,
                activity: activity,
                isRefreshing: isRefreshing,
                attentionFlash: attentionFlash,
                resolvedPulse: resolvedPulse,
                needsAttention: needsAttention
            )
            // Kept even when empty. The stack's geometry is measured in
            // `NotchLayout`, and a cell that quietly lost a line would slide
            // its ring off the centres every hover band and tooltip tail is
            // aimed at.
            Text(percentText)
                .font(Typography.percent)
                .foregroundStyle(Palette.textPrimary)
                // Never squeezed: across a horizontal edge the cell is only as
                // wide as the ring, and a label wider than that would be
                // truncated rather than allowed to overhang into the spacing
                // that is already there for it.
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: NotchLayout.percentLineHeight)
                .contentTransition(.numericText())
                .animation(NotchMotion.reading, value: percentText)
        }
        .frame(height: NotchLayout.cellExtent)
    }
}

/// The provider stays one continuous block. Holding its ring unfolds the
/// accounts in rotation order, using the same ring and spacing as the normal
/// provider list, so no detached menu obscures the app underneath.
struct InlineAccountRotation: View {
    let picker: NotchAccountPicker
    let snapshot: ProviderSnapshot
    let edge: NotchEdge
    let displayMode: UsageDisplayMode
    let onChooseNext: (UUID) -> Void

    /// Whether anybody can actually take over.
    ///
    /// Everything that draws the handover reads this, not just the badge. The
    /// connector and the rule are claims in their own right — a line drawn from
    /// the first cell to the second says *that* account hands over to *this*
    /// one — so during a spell when nobody can take over they have to go too.
    /// Leaving them up would point the picture at an account carrying no badge,
    /// which is the exact contradiction the badge was fixed to remove.
    ///
    /// Nil used to be rare. It is not: a rate-limited or stale reading counts
    /// as unknown rather than exhausted, so there are now ordinary minutes with
    /// no usable successor at all.
    private var hasNext: Bool { Self.drawsHandover(picker.accounts) }

    /// The rule itself, so it can be stated without a renderer.
    static func drawsHandover(_ accounts: [NotchAccountItem]) -> Bool {
        accounts.contains { $0.isNext }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if picker.accounts.count > 2, hasNext {
                queueDivider
            }
            if edge.isVertical {
                VStack(spacing: 0) { verticalAccountCells }
            } else {
                HStack(spacing: 0) { horizontalAccountCells }
            }
        }
        .animation(NotchMotion.glide, value: picker.accounts.map(\.id))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// The quiet path between NOW and NEXT makes the automatic handoff read as
    /// one flow while keeping both rings individually draggable.
    private var handoffConnector: some View {
        let stroke = Design.px(5)
        return Capsule()
            .fill(Palette.textSecondary.opacity(0.72))
            .frame(
                width: edge.isVertical ? stroke : nil,
                height: edge.isVertical ? nil : stroke
            )
    }

    /// A fixed rule separates the active handoff from the rest of the loop.
    /// The current account cannot be dragged, so this stays directly below
    /// NEXT while later accounts move around underneath it.
    private var queueDivider: some View {
        let position = 2 * NotchLayout.cellAlong(for: edge)
            + 1.5 * NotchLayout.cellSpacing
        return Capsule()
            .fill(Palette.textSecondary.opacity(0.72))
            .frame(
                width: edge.isVertical ? NotchLayout.glyphSize : NotchLayout.hairline,
                height: edge.isVertical ? NotchLayout.hairline : NotchLayout.glyphSize
            )
            .offset(
                x: edge.isVertical
                    ? (NotchLayout.ringDiameter - NotchLayout.glyphSize) / 2
                    : position - NotchLayout.hairline / 2,
                y: edge.isVertical
                    ? position - NotchLayout.hairline / 2
                    : (NotchLayout.cellExtent - NotchLayout.glyphSize) / 2
            )
    }

    private var verticalAccountCells: some View {
        ForEach(Array(picker.accounts.enumerated()), id: \.element.id) { index, account in
            accountCell(account)
            if index < picker.accounts.count - 1 {
                ZStack { if index == 0, hasNext { handoffConnector } }
                    .frame(height: NotchLayout.cellSpacing)
            }
        }
    }

    private var horizontalAccountCells: some View {
        ForEach(Array(picker.accounts.enumerated()), id: \.element.id) { index, account in
            accountCell(account)
                .frame(width: NotchLayout.cellAlong(for: edge))
            if index < picker.accounts.count - 1 {
                ZStack { if index == 0, hasNext { handoffConnector } }
                    .frame(width: NotchLayout.cellSpacing)
            }
        }
    }

    /// Only ever a percentage, or nothing.
    ///
    /// A number's width is bounded by construction — four characters at the
    /// most. A status word's is bounded by nothing, and the one that shipped
    /// ran past the edge of the notch and onto the desktop.
    static func label(for account: NotchAccountItem) -> String {
        guard account.usage != "—" else { return "" }
        return account.usage.components(separatedBy: " ").first ?? ""
    }

    private func accountCell(_ account: NotchAccountItem) -> some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                usedFraction: account.usedFraction,
                glyph: picker.provider.glyph,
                displayMode: displayMode,
                isStale: account.usedFraction == nil,
                needsAttention: account.needsAttention
            )
            .overlay(alignment: .bottom) {
                if account.isCurrent || account.isNext {
                    Text(account.isCurrent ? "NOW" : "NEXT")
                        .font(AppTheme.font(size: Design.fontSize(capPixels: 13), weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, Design.px(12))
                        .padding(.vertical, Design.px(5))
                        .background(Palette.notch, in: Capsule())
                        .overlay(Capsule().stroke(Palette.textSecondary, lineWidth: Design.px(2)))
                        .offset(y: Design.px(11))
                }
            }
            // No word here, ever. The cell is only as wide as the ring, and a
            // status word is as long as whatever language it is written in —
            // "Usage unavailable short" ran clean out of the notch and over the
            // desktop. A percentage fits by construction; nothing else does, so
            // nothing else is drawn. The reason lives in the hover card, which
            // has room for a sentence.
            Text(Self.label(for: account))
                .font(Typography.percent)
                .foregroundStyle(account.isCurrent ? Palette.textPrimary : Palette.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: NotchLayout.percentLineHeight)
        }
        .frame(height: NotchLayout.cellExtent)
        .contentShape(Rectangle())
        .onTapGesture {
            if !account.isCurrent { onChooseNext(account.id) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.name), \(account.usage)\(account.isCurrent ? ", current account" : account.isNext ? ", next account" : "")")
        .accessibilityHint("Drag to change the account order")
    }
}
