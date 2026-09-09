import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Measured rather than assumed: the panel's real size is whatever
        // AppKit settled on, and the notch has to sit flush against *that*
        // edge, not against the size we asked for.
        GeometryReader { proxy in
            let place = NotchPlacement(edge: model.edge, panelSize: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                notch(place)

                // Outside the notch and outside its clip: the orb hangs past
                // the end of the shape, tucked into the corner the far flare
                // makes.
                if !model.snapshots.isEmpty {
                    SettingsOrb(isHovered: model.isHoveringSettings, edge: model.edge,
                                    convex: model.orbHugsCorner,
                                    arcRadius: model.orbArcRadius,
                                    arcOffset: model.orbArcOffset)
                        .position(orbCentre(place))
                        // Outward, into the black — not inward to nothing.
                        .scaleEffect(model.isExpanded ? 1 : model.orbMergeScale)
                        // Full strength the whole way in. The arc is buried in
                        // the notch before this reaches zero, so the fade is
                        // only there to guarantee nothing is left on screen
                        // once the notch has folded — it is never what the eye
                        // sees the arc leave by.
                        .opacity(model.isExpanded ? 1 : 0)
                        .animation(motion(orbMotion), value: model.isExpanded)
                }

                if let snapshot = model.selectedSnapshot, let index = model.selectedIndex,
                   model.isExpanded {
                    TooltipCard(
                        snapshot: snapshot,
                        activity: model.activity(for: snapshot.id),
                        automaticSwitch: model.automaticSwitch?.toID.uuidString == snapshot.id
                            ? model.automaticSwitch : nil,
                        now: model.now,
                        displayMode: model.usageDisplayMode,
                        direction: model.edge.tooltipDirection,
                        sessionCap: model.sessionCap
                    )
                        // Deliberately *no* `.id` here: the card is one object
                        // that travels and resizes between cells, which reads
                        // far better than one card leaving and another arriving.
                        // What must not interpolate is its contents — see
                        // `TooltipCard`.
                        .position(tooltipCentre(place, index: index, snapshot: snapshot))
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(24),
                            y: model.edge.outward.y * Design.px(24)
                        )))
                }

                // Stands down as soon as a provider's own details are opened,
                // so the two cards never contest the same space.
                if model.showsAttentionCard, let alert = model.attention,
                   let index = model.attentionIndex {
                    AttentionCard(alert: alert, direction: model.edge.tooltipDirection)
                        .position(attentionCentre(place, index: index, alert: alert))
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(24),
                            y: model.edge.outward.y * Design.px(24)
                        )))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Swapping cards is a movement like any other here.
            .animation(motion(NotchMotion.glide), value: model.selectedIndex)
            .animation(motion(NotchMotion.glide), value: model.attention?.id)
        }
        .animation(motion(NotchMotion.unfold), value: model.isExpanded)
        .environment(\.colorScheme, .dark)
        // The flash is played to whoever is looking, not to a folded shape:
        // a problem raised while the notch is shut waits for the first time it
        // opens. Armed on appearance too, for the Always-show placement, where
        // opening never happens because it is never closed.
        .onAppear { model.armAttentionFlash() }
        .onChange(of: model.isExpanded) { _, _ in model.armAttentionFlash() }
    }

    /// What VoiceOver reads for one cell.
    ///
    /// The problem leads when there is one. Everything else this feature does
    /// — the red gradient, the flash, the card that appears under the pointer —
    /// has to be seen or pointed at, and this line is the only place somebody
    /// who does neither is told anything at all.
    private func cellValue(_ snapshot: ProviderSnapshot, index: Int) -> String {
        var parts: [String] = []
        if let attention = model.attention, attention.concerns(snapshotID: snapshot.id) {
            parts.append(attention.title)
            parts.append(attention.detail)
        }
        parts.append(snapshot.hasReading
            ? snapshot.headlineText(for: model.usageDisplayMode) + " " + model.usageDisplayMode.unit
            : "Usage unavailable")
        parts.append("Details \(model.selectedIndex == index ? "open" : "closed")")
        return parts.joined(separator: ". ") + "."
    }

    /// Where the alert card sits: on the ring it concerns, the same way a
    /// usage card sits on the ring it belongs to.
    private func attentionCentre(
        _ place: NotchPlacement, index: Int, alert: NotchAlert
    ) -> CGPoint {
        let card = model.edge.isVertical
            ? NotchLayout.cardWidth
            : NotchLayout.attentionCardHeight(detail: alert.detail)
        return place.point(
            along: model.slack + model.ringCenter(index: index),
            across: model.tooltipInset + (NotchLayout.tailLength + card) / 2
        )
    }

    /// Opening and closing are not mirror images. Appearing, the arc waits its
    /// turn behind the cells before it; hiding, any delay at all lets the notch
    /// start folding first, and the arc reads as going with the frame rather
    /// than into it.
    private var orbMotion: Animation {
        model.isExpanded
            ? NotchMotion.stagger(index: model.snapshots.count)
            : NotchMotion.merge
    }

    private func notch(_ place: NotchPlacement) -> some View {
        let shape = SideNotchShape(edge: model.edge, joining: model.joinedNotch)
        return shape
            .fill(Palette.notch)
            .frame(width: model.notchSize.width, height: model.notchSize.height)
            // The alert skin is a second fill over the black rather than a
            // swapped one. Two shape styles cannot be interpolated between, so
            // exchanging them would make the notch change colour in a single
            // frame; laid over the top, it is one opacity and the red grows in.
            // Geometry is untouched — same shape, same frame, same clip.
            .overlay {
                shape
                    .fill(NotchAlertSkin.gradient(for: model.edge))
                    .opacity(model.attention == nil ? 0 : 1)
                    .animation(motion(NotchMotion.alertRaise), value: model.attention == nil)
                    .accessibilityHidden(true)
            }
            // Aligned to the corner where the stack starts *and* the bezel is,
            // then pushed clear of any hardware notch. Centring the contents in
            // a shape that had been made deeper is what put the top of every
            // ring inside the hole in the display.
            .overlay(alignment: contentAlignment) {
                cells.padding(bezelSide, model.contentInset)
            }
            // Masked by the notch itself, not by its bounding box. Without this
            // the cells simply sit on top of a shrinking shape and appear to
            // slide out of the end of it; clipped, they are swallowed by the
            // outline as it closes, which is what a notch should do.
            .clipShape(SideNotchShape(edge: model.edge, joining: model.joinedNotch))
            .position(place.point(
                along: model.notchLeadingInset + model.notchLength / 2,
                across: model.notchDepth / 2
            ))
    }

    /// The cells fade and lift into place a beat after the shape starts opening,
    /// each trailing the one before it. Folded shut they are not just hidden but
    /// pulled toward the edge, so the whole thing reads as one movement.
    @ViewBuilder
    private var cells: some View {
        let stack = Group {
            if let picker = model.accountPicker,
               let snapshot = model.snapshots.first(where: { $0.id == picker.snapshotID }) {
                InlineAccountRotation(
                    picker: picker,
                    snapshot: snapshot,
                    edge: model.edge,
                    displayMode: model.usageDisplayMode,
                    onChooseNext: {
                        model.onChooseNextAccount?($0)
                        model.onDismissAccountPicker?()
                    }
                )
            } else {
                ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                    ProviderCell(
                        snapshot: snapshot,
                        activity: model.activity(for: snapshot.id),
                        isRefreshing: model.refreshing.contains(snapshot.id),
                        displayMode: model.usageDisplayMode,
                        attentionFlash: model.attentionFlash(forSnapshot: snapshot.id)
                    )
                // Pinned to what the cell claims along the stack, or the drawn
                // rings stop lining up with the centres `ringCenter` hands to
                // the hover bands and the tooltip tails. Across a horizontal
                // edge that is the ring alone — the label sits below it, in the
                // notch's depth, and claims nothing here.
                .frame(width: model.edge.isVertical ? nil : NotchLayout.cellAlong(for: model.edge))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(snapshot.displayName) usage details")
                .accessibilityValue(cellValue(snapshot, index: index))
                // What the click actually does, which changes while something
                // needs doing. A hint that still promised usage details after
                // the notch had turned into a button to the problem would be
                // the one part of this feature that lies to the people who
                // cannot see the red.
                .accessibilityHint(model.attention == nil
                    ? NSLocalizedString(
                        "Click for details. Press and hold to reorder accounts.",
                        comment: "Provider ring interaction hint")
                    : NSLocalizedString(
                        "Click the notch to open Builder Nutch.",
                        comment: "What clicking the alerted notch does"))
                .help(Text(NSLocalizedString(
                    "Press and hold to reorder accounts",
                    comment: "Provider ring hover help"
                )))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onToggleDetails?(index) }
                .accessibilityHidden(!model.isExpanded)
                .opacity(model.isExpanded ? 1 : 0)
                // A short slide toward the edge, no scaling: the clip is
                // already doing the concealing, and scaling on top of it
                // reads as two effects fighting.
                .offset(
                    x: model.isExpanded ? 0 : model.edge.outward.x * Design.px(28),
                    y: model.isExpanded ? 0 : model.edge.outward.y * Design.px(28)
                )
                .animation(motion(NotchMotion.stagger(index: index)), value: model.isExpanded)
                }
            }
        }

        Group {
            if model.edge.isVertical {
                VStack(spacing: NotchLayout.cellSpacing) { stack }
                    .padding(.top, leadIn)
                    // The contents keep the expanded layout while folding, so
                    // the stack does not reflow on its way out; the shape clips it.
                    .frame(width: NotchLayout.bodyDepth(for: model.edge))
            } else {
                HStack(spacing: NotchLayout.cellSpacing) { stack }
                    .padding(.leading, leadIn)
                    .frame(height: NotchLayout.bodyDepth(for: model.edge))
            }
        }
        .allowsHitTesting(model.isExpanded)
    }

    /// The corner of the shape's own frame where the stack starts and the
    /// bezel is — the origin everything inside it is measured from.
    private var contentAlignment: Alignment {
        switch model.edge {
        case .right:  return .topTrailing
        case .left:   return .topLeading
        case .top:    return .topLeading
        case .bottom: return .bottomLeading
        }
    }

    /// Which side of that frame faces the bezel.
    private var bezelSide: Edge.Set {
        switch model.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    /// Distance from the start of the shape to the first cell, widening
    /// included so the readings stay in the middle of a bar that was stretched
    /// to cover the hardware notch.
    private var leadIn: CGFloat {
        model.flare + NotchLayout.padStart(for: model.edge) + model.endSpread
    }

    private func motion(_ animation: Animation) -> Animation? {
        NotchMotion.respectingReduceMotion(animation, reduceMotion)
    }

    /// The orb sits on the flare's own centre of curvature, one radius in from
    /// the bezel and level with the far end of the shape.
    private func orbCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.orbAlong,
            across: model.orbInset
        )
    }

    /// The tooltip is the card plus its tail; `position` centres that pair, so
    /// the tail lands on the hovered cell and the card sits beyond it.
    private func tooltipCentre(
        _ place: NotchPlacement, index: Int, snapshot: ProviderSnapshot
    ) -> CGPoint {
        let card = model.edge.isVertical
            ? NotchLayout.cardWidth
            : (model.automaticSwitch?.toID.uuidString == snapshot.id
                ? NotchLayout.automaticSwitchCardHeight(
                    identitySubtitle: snapshot.accountEmail?.isEmpty == false)
                : NotchLayout.cardHeight(
                    windowCount: snapshot.windows.count,
                    sessionCount: model.activity(for: snapshot.id)?.sessions.count ?? 0,
                    sessionCap: model.sessionCap,
                    statusMessage: snapshot.statusMessage,
                    blockMessage: snapshot.block?.summary(now: model.now),
                    identitySubtitle: snapshot.accountEmail?.isEmpty == false))
        return place.point(
            along: model.slack + model.ringCenter(index: index),
            across: model.tooltipInset + (NotchLayout.tailLength + card) / 2
        )
    }
}
