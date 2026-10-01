import AppKit
import SwiftUI

// MARK: - Theme

enum Theme {
    /// Warm amber, used sparingly: the on state, the selected sound, slider fills.
    static let accent = Color(red: 245 / 255, green: 165 / 255, blue: 36 / 255)
    /// Text and symbols drawn on top of the accent.
    static let onAccent = Color.black.opacity(0.82)
    static let cardRadius: CGFloat = 12
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)

    /// Subtle fills and 1 px borders that work in light and dark mode.
    static let fill = Color.primary.opacity(0.05)
    static let fillHover = Color.primary.opacity(0.085)
    static let border = Color.primary.opacity(0.09)
}

/// Runs `body` with Kliq's spring, or without animation when Reduce Motion is on.
func withKliqAnimation(_ reduceMotion: Bool, _ body: () -> Void) {
    if reduceMotion {
        body()
    } else {
        withAnimation(Theme.spring, body)
    }
}

private struct KliqAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Theme.spring, value: value)
    }
}

extension View {
    /// Animates changes of `value` with Kliq's spring, respecting Reduce Motion.
    func kliqAnimation<V: Equatable>(value: V) -> some View {
        modifier(KliqAnimation(value: value))
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Switch

/// Kliq's on/off switch: amber when on, grey when off. The large style shows
/// a power symbol in the knob and is used for the main on/off control.
struct KliqSwitch: View {
    enum Style { case power, compact }

    @Binding var isOn: Bool
    var style: Style = .compact
    var label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var size: CGSize { style == .power ? CGSize(width: 50, height: 28) : CGSize(width: 32, height: 19) }

    var body: some View {
        Button {
            withKliqAnimation(reduceMotion) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent : Color.primary.opacity(0.13))
                Capsule()
                    .strokeBorder(Color.primary.opacity(isOn ? 0.0 : 0.07), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                    .overlay {
                        if style == .power {
                            Image(systemName: "power")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isOn ? Theme.accent : Color.gray)
                        }
                    }
                    .padding(style == .power ? 3 : 2)
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .kliqAnimation(value: hovering)
        .kliqAnimation(value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .help(label)
    }
}

// MARK: - Segmented pills

/// Soft / Medium / Hard with a sliding amber pill behind the selection.
struct IntensityControl: View {
    @Binding var selection: Intensity

    var body: some View {
        PillPicker(selection: $selection, options: Intensity.allCases, label: "Intensity") { $0.displayName }
    }
}

/// MacBook / System: where Kliq's sounds play.
struct OutputRouteControl: View {
    @Binding var selection: OutputRoute

    var body: some View {
        PillPicker(selection: $selection, options: OutputRoute.allCases, label: "Play sounds through") { $0.shortName }
            .help("MacBook plays sounds from the built-in speakers even with headphones connected")
    }
}

/// A row of options with a sliding amber pill behind the selected one.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: String
    let title: (Value) -> String

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withKliqAnimation(reduceMotion) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(selected ? Theme.onAccent : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.accent)
                                    .shadow(color: Theme.accent.opacity(0.35), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.fill))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Volume

/// A slim slider with an amber fill and speaker icons at both ends.
struct VolumeSlider: View {
    @Binding var value: Double

    @State private var dragging = false
    private let knob: CGFloat = 16

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            GeometryReader { geo in
                let travel = max(geo.size.width - knob, 1)
                let x = CGFloat(value) * travel
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 5)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: x + knob / 2, height: 5)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: .black.opacity(dragging ? 0.3 : 0.22), radius: dragging ? 3 : 1.5, y: 1)
                        .frame(width: knob, height: knob)
                        .scaleEffect(dragging ? 1.1 : 1)
                        .offset(x: x)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            value = min(max(Double((drag.location.x - knob / 2) / travel), 0), 1)
                        }
                        .onEnded { _ in dragging = false }
                )
            }
            .frame(height: 20)
            .kliqAnimation(value: dragging)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.1, 1)
            case .decrement: value = max(value - 0.1, 0)
            @unknown default: break
            }
        }
    }
}

// MARK: - Buttons

/// A small, quiet icon button that brightens on hover.
struct QuietIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Theme.fillHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .kliqAnimation(value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A compact amber capsule button for the one primary action on screen.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Profile cards

struct TypeTag: View {
    let type: ProfileType?

    var body: some View {
        Text((type?.displayName ?? "Untagged").uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(type == nil ? Color.secondary.opacity(0.6) : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct ProfileCard: View {
    let profile: SoundProfile
    let isSelected: Bool
    var large = false
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onSetType: (ProfileType?) -> Void

    @State private var hovering = false
    @State private var previewHovering = false

    static func height(large: Bool) -> CGFloat { large ? 60 : 52 }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: large ? 7 : 5) {
                Text(profile.displayName)
                    .font(.system(size: large ? 13 : 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                TypeTag(type: profile.type)
            }
            Spacer(minLength: 0)
            Button(action: onPreview) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(previewHovering ? Theme.onAccent : Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(previewHovering ? Theme.accent : Theme.accent.opacity(0.16)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { previewHovering = $0 }
            .opacity(hovering ? 1 : 0)
            .scaleEffect(hovering ? 1 : 0.8)
            .help("Preview \(profile.displayName)")
            .accessibilityLabel("Preview \(profile.displayName)")
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(height: Self.height(large: large))
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.13) : (hovering ? Theme.fillHover : Theme.fill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .kliqAnimation(value: hovering)
        .kliqAnimation(value: isSelected)
        .help(profile.summary)
        .contextMenu {
            Button("Preview", action: onPreview)
            Menu("Type") {
                ForEach(ProfileType.allCases) { type in
                    Button {
                        onSetType(type)
                    } label: {
                        if profile.type == type {
                            Label(type.displayName, systemImage: "checkmark")
                        } else {
                            Text(type.displayName)
                        }
                    }
                }
                Divider()
                Button("None") { onSetType(nil) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.displayName), \(profile.type?.displayName ?? "untagged")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
    }
}

/// All profiles as cards. With `maxVisibleRows`, the grid scrolls past that many rows.
struct ProfileGrid: View {
    @ObservedObject var controller: KliqController
    var columns = 2
    var large = false
    var maxVisibleRows: CGFloat?

    private let spacing: CGFloat = 8

    var body: some View {
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                             spacing: spacing) {
            ForEach(controller.availableProfiles) { profile in
                ProfileCard(profile: profile,
                            isSelected: profile == controller.soundProfile,
                            large: large,
                            onSelect: { controller.soundProfile = profile },
                            onPreview: { controller.preview(profile) },
                            onSetType: { controller.setType($0, for: profile) })
            }
        }
        .padding(1) // room for the selection ring

        if let maxVisibleRows {
            let rows = CGFloat((controller.availableProfiles.count + columns - 1) / columns)
            let cardHeight = ProfileCard.height(large: large)
            let visible = min(rows, maxVisibleRows)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: rows > maxVisibleRows) {
                    grid
                }
                .frame(height: visible * cardHeight + max(ceil(visible) - 1, 0) * spacing + 2)
                // Keep the selected sound in view when the popover opens.
                .onAppear { proxy.scrollTo(controller.soundProfile.id, anchor: .center) }
            }
        } else {
            grid
        }
    }
}

// MARK: - Banner

/// Shown instead of the normal controls' status when Input Monitoring is missing.
struct AccessBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Kliq can't hear your keys yet")
                    .font(.system(size: 12, weight: .semibold))
                Text("Allow Input Monitoring so Kliq can play a sound when you type. Only the fact that a key was pressed is used.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Grant Access", action: action)
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 5)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.accent.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
    }
}
