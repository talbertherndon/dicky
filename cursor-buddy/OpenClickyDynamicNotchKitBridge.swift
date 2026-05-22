import AppKit
import SwiftUI

#if canImport(DynamicNotchKit)
import DynamicNotchKit
import Combine

@MainActor
private final class OpenClickyDynamicNotchKitModel: ObservableObject {
    enum Mode {
        case collapsed
        case voice(OpenClickyNotchVoicePhase)
    }

    @Published var mode: Mode = .collapsed
    @Published var foregroundAppIcon: NSImage?
    @Published var foregroundAppName = "Current app"
    @Published var hasRunningAgentWork = false
    @Published var accentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
    @Published var audioPowerLevel: CGFloat = 0
    var openMainPanel: () -> Void = {}
    var openNotch: () -> Void = {}
    var closeNotch: () -> Void = {}
}

@MainActor
final class OpenClickyDynamicNotchKitBridge {
    private let model = OpenClickyDynamicNotchKitModel()
    private lazy var notch: DynamicNotch<OpenClickyDynamicNotchKitExpandedView, OpenClickyDynamicNotchKitCompactLeadingView, OpenClickyDynamicNotchKitCompactTrailingView> = {
        let notch = DynamicNotch(
            hoverBehavior: [.hapticFeedback, .increaseShadow, .keepVisible],
            style: .notch(topCornerRadius: 15, bottomCornerRadius: 24)
        ) {
            OpenClickyDynamicNotchKitExpandedView(model: self.model)
        } compactLeading: {
            OpenClickyDynamicNotchKitCompactLeadingView(model: self.model)
        } compactTrailing: {
            OpenClickyDynamicNotchKitCompactTrailingView(model: self.model)
        }
        notch.transitionConfiguration.skipIntermediateHides = true
        model.openNotch = { [weak self] in
            guard let self else { return }
            Task { await self.notch.expand() }
        }
        model.closeNotch = { [weak self] in
            guard let self else { return }
            Task { await self.notch.compact() }
        }
        return notch
    }()

    func showCollapsed(
        on screen: NSScreen,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        hasRunningAgentWork: Bool,
        openMainPanel: @escaping () -> Void,
        opensExpanded: Bool = false
    ) {
        model.mode = .collapsed
        model.accentColor = accentColor
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.hasRunningAgentWork = hasRunningAgentWork
        model.openMainPanel = openMainPanel
        Task {
            if opensExpanded {
                await notch.expand(on: screen)
            } else {
                await notch.compact(on: screen)
            }
        }
    }

    func showVoice(
        _ phase: OpenClickyNotchVoicePhase,
        audioPowerLevel: CGFloat,
        on screen: NSScreen,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        openMainPanel: @escaping () -> Void,
        opensExpanded: Bool = false
    ) {
        model.mode = .voice(phase)
        model.accentColor = accentColor
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.hasRunningAgentWork = false
        model.audioPowerLevel = audioPowerLevel
        model.openMainPanel = openMainPanel
        Task {
            if opensExpanded {
                await notch.expand(on: screen)
            } else {
                await notch.compact(on: screen)
            }
        }
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        model.audioPowerLevel = audioPowerLevel
    }

    func updateForegroundApp(icon: NSImage?, name: String) {
        model.foregroundAppIcon = icon
        model.foregroundAppName = name
    }

    func open(on screen: NSScreen) {
        Task { await notch.expand(on: screen) }
    }

    func close(on screen: NSScreen) {
        Task { await notch.compact(on: screen) }
    }

    func hide() {
        Task { await notch.hide() }
    }
}

private struct OpenClickyDynamicNotchKitCompactLeadingView: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel

    var body: some View {
        HStack {
            compactAppIcon
        }
        // DynamicNotchKit lays compactLeading/compactTrailing on either side of
        // the real MacBook notch. Keep each side deliberately wide so compact
        // mode reads as app icon | physical notch | voice/thinking indicator,
        // never as an "Ask OpenClicky" label squeezed into the notch area.
        .frame(width: 76, height: 28, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.openNotch() }
        .accessibilityLabel(accessibilityAppName)
    }

    @ViewBuilder
    private var compactAppIcon: some View {
        if let icon = model.foregroundAppIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(nsColor: model.accentColor))
                .frame(width: 22, height: 22)
        }
    }

    private var accessibilityAppName: String {
        let name = model.foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "Current app" ? "Current app" : name
    }
}

private struct OpenClickyDynamicNotchKitCompactTrailingView: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel

    var body: some View {
        HStack {
            compactIndicator
        }
        .frame(width: 76, height: 28, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { model.openNotch() }
        .accessibilityLabel(indicatorLabel)
    }

    @ViewBuilder
    private var compactIndicator: some View {
        switch model.mode {
        case .voice:
            OpenClickyDynamicNotchKitMiniMeter(level: model.audioPowerLevel, color: Color(nsColor: model.accentColor))
                .frame(width: 32, height: 16)
        case .collapsed:
            OpenClickyDynamicNotchKitDots(color: Color(nsColor: model.accentColor))
                .frame(width: 28, height: 12)
        }
    }

    private var indicatorLabel: String {
        switch model.mode {
        case .collapsed:
            return model.hasRunningAgentWork ? "Agent work running" : "OpenClicky ready"
        case .voice(let phase):
            switch phase {
            case .idle: return "Ready"
            case .listening: return "Listening"
            case .processing: return "Thinking"
            case .responding: return "Speaking"
            }
        }
    }
}

private struct OpenClickyDynamicNotchKitExpandedView: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel

    var body: some View {
        HStack(spacing: 12) {
            expandedAppIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(expandedTitle)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.98))
                Text(expandedSubtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .frame(width: 170, alignment: .leading)

            HStack(spacing: 6) {
                OpenClickyDynamicNotchKitChip(title: "Agent", systemImage: "shippingbox", accentColor: Color(nsColor: model.accentColor)) {
                    model.openMainPanel()
                }
                OpenClickyDynamicNotchKitChip(title: "Screen", systemImage: "rectangle.dashed", accentColor: Color(nsColor: model.accentColor)) {
                    model.openMainPanel()
                }
                OpenClickyDynamicNotchKitChip(title: "Open", systemImage: "arrow.up.right", accentColor: Color(nsColor: model.accentColor)) {
                    model.openMainPanel()
                }
                OpenClickyDynamicNotchKitChip(title: "Close", systemImage: "chevron.up", accentColor: .white.opacity(0.36)) {
                    model.closeNotch()
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var expandedAppIcon: some View {
        if let icon = model.foregroundAppIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(nsColor: model.accentColor))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var expandedTitle: String {
        switch model.mode {
        case .collapsed:
            if model.hasRunningAgentWork { return "Agent work running" }
            let name = model.foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || name == "Current app" ? "Current app" : name
        case .voice(let phase):
            switch phase {
            case .idle: return "OpenClicky ready"
            case .listening: return "Listening"
            case .processing: return "Thinking"
            case .responding: return "Speaking"
            }
        }
    }

    private var expandedSubtitle: String {
        let name = model.foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "Current app" {
            return "Choose a control or open the panel"
        }
        return "Focused in \(name)"
    }
}

private struct OpenClickyDynamicNotchKitChip: View {
    let title: String
    let systemImage: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .bold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(accentColor.opacity(0.22), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct OpenClickyDynamicNotchKitDots: View {
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color.opacity(index == 1 ? 1 : 0.58))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

private struct OpenClickyDynamicNotchKitMiniMeter: View {
    let level: CGFloat
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.55 + Double(index) * 0.10))
                    .frame(width: 3, height: max(4, min(14, 4 + (level * CGFloat(index + 1) * 10))))
            }
        }
    }
}
#else
@MainActor
final class OpenClickyDynamicNotchKitBridge {
    func showCollapsed(on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, hasRunningAgentWork: Bool, openMainPanel: @escaping () -> Void, opensExpanded: Bool = false) {}
    func showVoice(_ phase: OpenClickyNotchVoicePhase, audioPowerLevel: CGFloat, on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, openMainPanel: @escaping () -> Void, opensExpanded: Bool = false) {}
    func open(on screen: NSScreen) {}
    func close(on screen: NSScreen) {}
    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {}
    func updateForegroundApp(icon: NSImage?, name: String) {}
    func hide() {}
}
#endif
