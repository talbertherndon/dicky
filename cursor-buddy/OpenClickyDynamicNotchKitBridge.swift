import AppKit
import SwiftUI

struct OpenClickyAgentLiveActivity: Equatable {
    var isActive = false
    var runningCount = 0
    var primaryTitle: String?
    var detail: String?
    var phaseLabel: String?

    var headline: String {
        if runningCount > 1 { return "\(runningCount) agents working" }
        let title = primaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return isActive ? "Agent working" : ""
    }

    var subtitle: String {
        let phase = phaseLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !phase.isEmpty {
            return phase
        }
        return runningCount > 1 ? "\(runningCount) agents active" : "Agent active"
    }
}

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
    @Published var agentLiveActivity = OpenClickyAgentLiveActivity()
    var hasRunningAgentWork: Bool { agentLiveActivity.isActive }
    @Published var accentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
    @Published var audioPowerLevel: CGFloat = 0
    var openMainPanel: () -> Void = {}
    var openNotch: () -> Void = {}
    var closeNotch: () -> Void = {}

    // Notch text-input surface (shift+shift "Ask Clicky" prompt). The input row
    // lives inside the expanded notch view; these drive its draft state.
    @Published var draftText: String = ""
    @Published var draftAttachments: [URL] = []
    @Published var isInputFocused = false
    @Published var isNotchHovered = false
    /// Bumped to ask the expanded input row to take keyboard focus.
    @Published var inputFocusRequest = 0
    var submitText: (String) -> Void = { _ in }

    /// Collapse the notch only when the pointer has left it and the input is
    /// not being typed into — keeps the notch open while the user types.
    func closeNotchIfIdle() {
        guard !isNotchHovered, !isInputFocused else { return }
        closeNotch()
    }
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
        agentLiveActivity: OpenClickyAgentLiveActivity? = nil,
        openMainPanel: @escaping () -> Void,
        opensExpanded: Bool = false
    ) {
        let liveActivity = agentLiveActivity ?? OpenClickyAgentLiveActivity()
        model.mode = .collapsed
        model.accentColor = accentColor
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.agentLiveActivity = liveActivity.isActive ? liveActivity : OpenClickyAgentLiveActivity(isActive: hasRunningAgentWork, runningCount: hasRunningAgentWork ? 1 : 0)
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

    /// Expands the notch and routes keyboard focus into the in-notch "Ask
    /// Clicky" input. Used by the shift+shift shortcut.
    func showTextInput(
        on screen: NSScreen,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        submitText: @escaping (String) -> Void
    ) {
        model.accentColor = accentColor
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.submitText = submitText
        Task {
            await notch.expand(on: screen)
            notch.windowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Let SwiftUI lay out the expanded view before requesting focus.
            try? await Task.sleep(nanoseconds: 120_000_000)
            model.inputFocusRequest &+= 1
        }
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        model.audioPowerLevel = audioPowerLevel
    }

    func updateForegroundApp(icon: NSImage?, name: String) {
        model.foregroundAppIcon = icon
        model.foregroundAppName = name
    }

    func updateAgentLiveActivity(_ activity: OpenClickyAgentLiveActivity) {
        model.agentLiveActivity = activity
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
        .frame(width: 20, height: 28, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.openNotch() }
        .onHover { isHovering in
            if isHovering { model.openNotch() }
        }
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
        .frame(width: 20, height: 28, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { model.openNotch() }
        .onHover { isHovering in
            if isHovering { model.openNotch() }
        }
        .accessibilityLabel(indicatorLabel)
    }

    @ViewBuilder
    private var compactIndicator: some View {
        switch model.mode {
        case .voice:
            OpenClickyDynamicNotchKitMiniMeter(level: model.audioPowerLevel, color: Color(nsColor: model.accentColor))
                .frame(width: 32, height: 16)
        case .collapsed:
            if model.hasRunningAgentWork {
                HStack(spacing: 4) {
                    OpenClickyDynamicNotchKitDots(color: Color(nsColor: model.accentColor))
                        .frame(width: 28, height: 12)
                    if model.agentLiveActivity.runningCount > 1 {
                        Text("\(model.agentLiveActivity.runningCount)")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
            } else {
                OpenClickyDynamicNotchKitDots(color: Color(nsColor: model.accentColor))
                    .frame(width: 28, height: 12)
            }
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
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                expandedAppIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(expandedTitle)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.98))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(expandedSubtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                }
            }
            .frame(height: 46, alignment: .center)

            OpenClickyDynamicNotchKitInputRow(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onHover { isHovering in
            model.isNotchHovered = isHovering
            if isHovering {
                model.openNotch()
            } else {
                model.closeNotchIfIdle()
            }
        }
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
            if model.hasRunningAgentWork { return model.agentLiveActivity.headline }
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
        if model.hasRunningAgentWork, case .collapsed = model.mode {
            return model.agentLiveActivity.subtitle
        }
        let name = model.foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "Current app" {
            return "Choose a control or open the panel"
        }
        return "Focused in \(name)"
    }
}

/// The "Ask Clicky" prompt input embedded in the expanded notch. Carries a
/// text field, drafted file attachments, and a send action. Submitting routes
/// the composed prompt through `model.submitText`.
private struct OpenClickyDynamicNotchKitInputRow: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel
    @FocusState private var fieldFocused: Bool

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.draftAttachments.isEmpty {
                attachmentChips
            }

            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color(nsColor: model.accentColor))

                TextField("Ask Clicky…", text: $model.draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .focused($fieldFocused)
                    .onSubmit(submit)

                Button(action: pickAttachments) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.66))
                }
                .buttonStyle(.plain)
                .help("Attach files")

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(nsColor: model.accentColor))
                }
                .buttonStyle(.plain)
                .help("Send to OpenClicky")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
        }
        .onChange(of: model.inputFocusRequest) { _, _ in
            fieldFocused = true
        }
        .onChange(of: fieldFocused) { _, focused in
            model.isInputFocused = focused
            if !focused {
                model.closeNotchIfIdle()
            }
        }
        .onExitCommand {
            fieldFocused = false
            model.closeNotch()
        }
    }

    private var attachmentChips: some View {
        HStack(spacing: 6) {
            ForEach(model.draftAttachments, id: \.self) { url in
                Button {
                    model.draftAttachments.removeAll { $0 == url }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Self.isImage(url) ? "photo" : "doc")
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "xmark")
                    }
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Remove \(url.lastPathComponent)")
            }
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.draftAttachments.contains(url) {
                model.draftAttachments.append(url)
            }
        }
        fieldFocused = true
    }

    private func submit() {
        let trimmed = model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !model.draftAttachments.isEmpty else { return }
        let prompt = Self.composePrompt(trimmed, attachments: model.draftAttachments)
        let send = model.submitText
        model.draftText = ""
        model.draftAttachments = []
        fieldFocused = false
        model.isInputFocused = false
        send(prompt)
        model.closeNotch()
    }

    private static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Folds attachment paths into the prompt text so the existing
    /// `(String) -> Void` submit closure carries them without an API change.
    private static func composePrompt(_ text: String, attachments: [URL]) -> String {
        guard !attachments.isEmpty else { return text }
        let request = text.isEmpty ? "Please review the attached file(s)." : text
        let lines = attachments.enumerated().map { index, url in
            "\(index + 1). \(isImage(url) ? "Image" : "Document"): \(url.path)"
        }.joined(separator: "\n")
        return "\(request)\n\nOpenClicky notch input attachments:\n\(lines)"
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
    func showCollapsed(on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, hasRunningAgentWork: Bool, agentLiveActivity: OpenClickyAgentLiveActivity = OpenClickyAgentLiveActivity(), openMainPanel: @escaping () -> Void, opensExpanded: Bool = false) {}
    func showVoice(_ phase: OpenClickyNotchVoicePhase, audioPowerLevel: CGFloat, on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, openMainPanel: @escaping () -> Void, opensExpanded: Bool = false) {}
    func showTextInput(on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, submitText: @escaping (String) -> Void) {}
    func open(on screen: NSScreen) {}
    func close(on screen: NSScreen) {}
    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {}
    func updateForegroundApp(icon: NSImage?, name: String) {}
    func updateAgentLiveActivity(_ activity: OpenClickyAgentLiveActivity) {}
    func hide() {}
}
#endif
