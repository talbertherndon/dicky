import SwiftUI

/// Compact menu-bar surface inspired by the recovered Clicky notch architecture.
///
/// This is intentionally an OpenClicky-original implementation. It only reads
/// the existing fast voice state and routes actions through CompanionManager;
/// it does not replace or wrap the voice capture, transcription, or playback
/// pipeline.
@MainActor
struct OpenClickyNotchPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var agentStore = OpenClickyAgentStore.shared
    @ObservedObject private var automationStore = OpenClickyAutomationStore.shared
    @ObservedObject private var petLibrary = ClickyBuddyPetLibrary.shared
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey) private var avatarStyleRawValue = ClickyCursorAvatarStyle.default.storageValue
    @AppStorage(ClickyCursorAvatarSizePreference.userDefaultsKey) private var cursorAvatarSizeScale = ClickyCursorAvatarSizePreference.defaultScale
    @State private var isShowingHatchSheet = false
    @State private var hatchPetName = ""
    @State private var hatchPetDescription = ""

    let isPanelPinned: Bool
    let setPanelPinned: (Bool) -> Void

    @State private var selectedTab: OpenClickyNotchTab = .home
    @State private var quickPrompt: String = ""
    @State private var gogStatus: OpenClickyGogCLIStatus = .unknown
    @State private var hasLoadedGogStatus = false

    private var activeVoiceLabel: String {
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }

    private var activeVoiceIcon: String {
        switch companionManager.voiceState {
        case .idle: return "bolt.fill"
        case .listening: return "waveform"
        case .processing: return "sparkles"
        case .responding: return "speaker.wave.2.fill"
        }
    }

    private var activeVoiceAccent: Color {
        switch companionManager.voiceState {
        case .idle: return DS.Colors.accentText
        case .listening: return .green
        case .processing: return .orange
        case .responding: return .purple
        }
    }

    private var voiceModelLabel: String {
        OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).label
    }

    private var speechModelLabel: String {
        OpenClickyModelCatalog.speechModel(withID: companionManager.selectedSpeechModel).label
    }

    private var visibleAgentSessions: [CodexAgentSession] {
        Array(companionManager.codexAgentSessions.prefix(4))
    }

    private var runningAgentCount: Int {
        companionManager.codexAgentSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }.count
    }

    private var enabledAutomationCount: Int {
        automationStore.automations.filter(\.enabled).count
    }

    private var connectionRows: [OpenClickyNotchConnectionRow] {
        let nativeComputerUseStatus = companionManager.nativeComputerUseController.status
        let backgroundComputerUseStatus = companionManager.backgroundComputerUseController.status

        return [
            OpenClickyNotchConnectionRow(
                title: "Voice",
                detail: "\(companionManager.buddyDictationManager.transcriptionProviderDisplayName) → \(companionManager.selectedTTSProvider.displayName) · \(speechModelLabel)",
                state: companionManager.hasMicrophonePermission ? .ready : .needsAttention,
                systemImageName: "waveform.circle.fill"
            ),
            OpenClickyNotchConnectionRow(
                title: "Agent Mode",
                detail: "\(companionManager.codexAgentSessions.count) sessions · \(agentStore.agents.count) specialist agents · model \(companionManager.codexAgentSession.model)",
                state: companionManager.codexAgentSessions.isEmpty ? .needsAttention : .ready,
                systemImageName: "terminal.fill"
            ),
            OpenClickyNotchConnectionRow(
                title: "Computer Use",
                detail: nativeComputerUseStatus.summary,
                state: nativeComputerUseStatus.isReadyForComputerUse ? .ready : .available,
                systemImageName: "cursorarrow.motionlines"
            ),
            OpenClickyNotchConnectionRow(
                title: "Background CUA",
                detail: backgroundComputerUseStatus.summary,
                state: backgroundComputerUseStatus.isRuntimeReady ? .ready : .available,
                systemImageName: "macwindow.badge.plus"
            ),
            OpenClickyNotchConnectionRow(
                title: "Google Workspace",
                detail: hasLoadedGogStatus ? gogStatus.readinessDetail : "Checking local gogcli files…",
                state: gogStatus.isReadyForUserAccount ? .ready : (gogStatus.isInstalled ? .available : .needsAttention),
                systemImageName: "g.circle.fill"
            ),
            OpenClickyNotchConnectionRow(
                title: "Automations",
                detail: "\(enabledAutomationCount) enabled · \(automationStore.automations.count) total local schedules",
                state: enabledAutomationCount > 0 ? .ready : .available,
                systemImageName: "clock.arrow.circlepath"
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            mainSurface
        }
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.clear)
        .sheet(isPresented: $isShowingHatchSheet) {
            hatchPetSheet
        }
        .task {
            await refreshGogStatus()
        }
        .onChange(of: selectedTab) { _ in
            notifyPanelSizeChanged()
        }
        .onChange(of: gogStatus) { _ in
            notifyPanelSizeChanged()
        }
    }

    private var mainSurface: some View {
        VStack(spacing: 12) {
            tabStrip

            Group {
                switch selectedTab {
                case .home:
                    homeTab
                case .agents:
                    agentsTab
                case .connections:
                    connectionsTab
                case .settings:
                    settingsTab
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DS.Colors.surface1.opacity(0.98), Color.black.opacity(0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 30, x: 0, y: 22)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.top, 1)
        }
    }

    private var topStatusRail: some View {
        HStack(spacing: 8) {
            statusPill(
                title: activeVoiceLabel,
                systemImageName: activeVoiceIcon,
                color: activeVoiceAccent
            )
            statusPill(
                title: runningAgentCount == 0 ? "Agents ready" : "\(runningAgentCount) running",
                systemImageName: "terminal.fill",
                color: runningAgentCount == 0 ? DS.Colors.textSecondary : DS.Colors.accentText
            )
            statusPill(
                title: companionManager.allPermissionsGranted ? "Perms OK" : "Needs perms",
                systemImageName: companionManager.allPermissionsGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                color: companionManager.allPermissionsGranted ? .green : .orange
            )
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(OpenClickyNotchTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImageName)
                            .font(.system(size: 10, weight: .heavy))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedTab == tab ? Color.white.opacity(0.12) : Color.white.opacity(0.045))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(selectedTab == tab ? DS.Colors.accentText.opacity(0.32) : Color.white.opacity(0.05), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var homeTab: some View {
        VStack(spacing: 12) {
            OpenClickyNotchHeroCard(
                title: "Ask from anywhere",
                subtitle: "Menu-bar notch surface, existing fast voice stack, local agent handoff.",
                systemImageName: "sparkles",
                accent: DS.Colors.accentText
            ) {
                VStack(spacing: 9) {
                    quickPromptField
                    HStack(spacing: 8) {
                        primaryActionButton(title: "Ask", systemImageName: "paperplane.fill") {
                            submitQuickPrompt()
                        }
                        secondaryActionButton(title: "Text", systemImageName: "text.cursor") {
                            companionManager.showQuickTextInputFromMenuBar()
                        }
                        secondaryActionButton(title: "Agent", systemImageName: "terminal.fill") {
                            companionManager.showCodexHUD()
                        }
                    }
                }
            }

            cursorBuddySection
            if shouldShowCursorColorSection {
                cursorColorSection
            }

            activationShortcutRow
        }
    }

    private var agentsTab: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                OpenClickyNotchMetricCard(
                    title: "Sessions",
                    value: "\(companionManager.codexAgentSessions.count)",
                    detail: "\(runningAgentCount) running now",
                    color: DS.Colors.accentText,
                    systemImageName: "rectangle.stack.fill"
                )
                OpenClickyNotchMetricCard(
                    title: "Specialists",
                    value: "\(agentStore.agents.count)",
                    detail: "local + bundled agents",
                    color: .purple,
                    systemImageName: "person.2.badge.gearshape.fill"
                )
            }

            VStack(spacing: 7) {
                if visibleAgentSessions.isEmpty {
                    OpenClickyNotchEmptyState(
                        systemImageName: "terminal",
                        title: "No agent sessions yet",
                        subtitle: "Start one from the notch or open the full HUD."
                    )
                } else {
                    ForEach(visibleAgentSessions) { session in
                        agentRow(session)
                    }
                }
            }

            HStack(spacing: 8) {
                primaryActionButton(title: "Open HUD", systemImageName: "macwindow.on.rectangle") {
                    companionManager.showCodexHUD()
                }
                secondaryActionButton(title: "New prompt", systemImageName: "plus.message.fill") {
                    selectedTab = .home
                }
            }
        }
    }

    private var connectionsTab: some View {
        VStack(spacing: 10) {
            activationShortcutRow
            OpenClickyNotchEmptyState(
                systemImageName: "point.3.connected.trianglepath.dotted",
                title: "Connections stay local",
                subtitle: "Use Agent Mode skills for Notion, GitHub, mail, browser, files, and app workflows. No hosted sync required."
            )
            primaryActionButton(title: "Open settings", systemImageName: "gearshape.fill") {
                companionManager.showSettingsWindow()
            }
        }
    }

    private var settingsTab: some View {
        VStack(spacing: 10) {
            cursorBuddySection
            cursorColorSection
            activationShortcutRow

            HStack(spacing: 8) {
                primaryActionButton(title: "Full settings", systemImageName: "gearshape.fill") {
                    companionManager.showSettingsWindow()
                }
                secondaryActionButton(title: isPanelPinned ? "Unpin" : "Pin", systemImageName: isPanelPinned ? "pin.slash.fill" : "pin.fill") {
                    setPanelPinned(!isPanelPinned)
                }
            }
        }
    }

    private var quickPromptField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.accentText)
            TextField("Ask OpenClicky…", text: $quickPrompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit(submitQuickPrompt)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var currentCursorAvatarStyle: ClickyCursorAvatarStyle {
        ClickyCursorAvatarStyle(storageValue: avatarStyleRawValue)
    }

    private var shouldShowCursorColorSection: Bool {
        switch currentCursorAvatarStyle {
        case .triangleFilled, .triangleOutline:
            return true
        case .pet:
            return false
        }
    }

    private var cursorBuddySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Cursor buddy")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: { presentHatchSheet() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Hatch new")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    avatarTile(.triangleFilled, label: "Triangle")
                    avatarTile(.triangleOutline, label: "Outline")
                    ForEach(petLibrary.pets) { pet in
                        avatarTileForPet(pet)
                    }
                    if petLibrary.pets.isEmpty {
                        emptyBuddiesHintTile
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Buddy size")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(Int((cursorAvatarSizeScale * 100).rounded()))%")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Slider(
                    value: $cursorAvatarSizeScale,
                    in: ClickyCursorAvatarSizePreference.minScale...ClickyCursorAvatarSizePreference.maxScale
                )
                .controlSize(.small)
                .tint((ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor)
            }
        }
    }

    private var cursorColorSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Cursor color")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)

            HStack(spacing: 6) {
                ForEach(cursorColorThemeOrder) { accentTheme in
                    cursorColorButton(accentTheme)
                }
            }
        }
    }

    private var activationShortcutRow: some View {
        HStack(spacing: 9) {
            Image(systemName: companionManager.isActivationShortcutEnabled ? "keyboard.badge.eye" : "keyboard.badge.ellipsis")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Colors.accent))
            Text(companionManager.isActivationShortcutEnabled ? "Activation key on" : "Activation key off")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var emptyBuddiesHintTile: some View {
        Button(action: { presentHatchSheet() }) {
            VStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Hatch")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(width: 62, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.borderSubtle, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])))
        }
        .buttonStyle(.plain)
    }

    private func avatarTile(_ style: ClickyCursorAvatarStyle, label: String) -> some View {
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button(action: { avatarStyleRawValue = style.storageValue }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.16) : Color.white.opacity(0.055))

                Group {
                    switch style {
                    case .triangleFilled:
                        Triangle()
                            .fill(accent)
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-25))
                            .shadow(color: accent.opacity(0.72), radius: 8)
                    case .triangleOutline:
                        Triangle()
                            .stroke(accent, lineWidth: 2.5)
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-25))
                    case .pet:
                        EmptyView()
                    }
                }
            }
            .frame(width: 62, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.7 : 0.7))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func avatarTileForPet(_ pet: ClickyBuddyPet) -> some View {
        let style = ClickyCursorAvatarStyle.pet(id: pet.id)
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button(action: { avatarStyleRawValue = style.storageValue }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.16) : Color.white.opacity(0.055))
                ClickyPetThumbnailView(pet: pet)
                    .frame(width: 34, height: 36)
            }
            .frame(width: 62, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.7 : 0.7))
        }
        .buttonStyle(.plain)
        .help(pet.displayName)
    }

    private var cursorColorThemeOrder: [ClickyAccentTheme] {
        [.rose, .blue, .amber, .mint, .white]
    }

    private func cursorColorButton(_ accentTheme: ClickyAccentTheme) -> some View {
        let isSelected = selectedAccentThemeID == accentTheme.rawValue
        return Button(action: { selectedAccentThemeID = accentTheme.rawValue }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accentTheme.cursorColor.opacity(0.16) : Color.white.opacity(0.055))
                Triangle()
                    .fill(accentTheme.cursorColor)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-25))
                    .shadow(color: accentTheme.cursorColor.opacity(0.72), radius: 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? accentTheme.cursorColor : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.7 : 0.7))
        }
        .buttonStyle(.plain)
        .help(accentTheme.title)
    }

    private func presentHatchSheet() {
        hatchPetName = ""
        hatchPetDescription = ""
        isShowingHatchSheet = true
    }

    private var hatchPetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hatch a new buddy")
                .font(.system(size: 14, weight: .semibold))
            Text("Launches an Agent Mode hatch-pet session.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Name", text: $hatchPetName)
                .textFieldStyle(.roundedBorder)
            TextField("Description optional", text: $hatchPetDescription)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isShowingHatchSheet = false }
                Button("Hatch") {
                    let theme = ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue
                    _ = ClickyPetHatchCoordinator.shared.beginHatch(
                        name: hatchPetName,
                        description: hatchPetDescription,
                        accentTheme: theme,
                        companionManager: companionManager
                    )
                    isShowingHatchSheet = false
                }
                .disabled(hatchPetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var permissionProgressStrip: some View {
        let permissions: [(String, Bool)] = [
            ("AX", companionManager.hasAccessibilityPermission),
            ("Screen", companionManager.hasScreenRecordingPermission),
            ("Mic", companionManager.hasMicrophonePermission),
            ("Content", companionManager.hasScreenContentPermission)
        ]

        return HStack(spacing: 7) {
            ForEach(permissions, id: \.0) { permission in
                HStack(spacing: 5) {
                    Circle()
                        .fill(permission.1 ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(permission.0)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(permission.1 ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(permission.1 ? 0.075 : 0.045))
                )
            }
        }
    }

    private func agentRow(_ session: CodexAgentSession) -> some View {
        Button {
            companionManager.selectCodexAgentSession(session.id)
            companionManager.showCodexHUD()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(agentStatusColor(session.status))
                    .frame(width: 8, height: 8)
                    .shadow(color: agentStatusColor(session.status).opacity(0.7), radius: 5, x: 0, y: 0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(session.status.label)
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(agentStatusColor(session.status))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(agentStatusColor(session.status).opacity(0.14)))
                    }

                    Text(session.latestActivityDisplaySummary ?? session.statusSummaryLine)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.055)))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(session.id == companionManager.activeCodexAgentSessionID ? DS.Colors.accentText.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func connectionRow(_ row: OpenClickyNotchConnectionRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.systemImageName)
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(row.state.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(row.state.color.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(row.state.title)
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(row.state.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(row.state.color.opacity(0.14)))
                }
                Text(row.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.052)))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }

    private func settingSummaryRow(title: String, detail: String, systemImageName: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImageName)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Colors.accentText.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(detail)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.052)))
    }

    private func statusPill(title: String, systemImageName: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImageName)
                .font(.system(size: 9, weight: .heavy))
            Text(title)
                .font(.system(size: 9, weight: .heavy))
        }
        .foregroundColor(color)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(color.opacity(0.105)))
        .overlay(Capsule(style: .continuous).stroke(color.opacity(0.18), lineWidth: 1))
    }

    private func primaryActionButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(.system(size: 10, weight: .black))
                Text(title)
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [DS.Colors.accent, DS.Colors.accentHover], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(.system(size: 10, weight: .black))
                Text(title)
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func submitQuickPrompt() {
        let trimmedPrompt = quickPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            companionManager.showQuickTextInputFromMenuBar()
            return
        }

        quickPrompt = ""
        companionManager.submitAgentPromptFromUI(trimmedPrompt)
        selectedTab = .agents
        notifyPanelSizeChanged()
    }

    private func refreshGogStatus() async {
        gogStatus = await OpenClickyGogCLIStatusResolver.refresh()
        hasLoadedGogStatus = true
    }

    private func notifyPanelSizeChanged() {
        NotificationCenter.default.post(name: .clickyPanelContentSizeDidChange, object: nil)
    }

    private func agentStatusColor(_ status: CodexAgentSessionStatus) -> Color {
        switch status {
        case .stopped:
            return DS.Colors.textTertiary
        case .starting:
            return .orange
        case .ready:
            return .green
        case .running:
            return DS.Colors.accentText
        case .failed:
            return DS.Colors.destructive
        }
    }
}

private enum OpenClickyNotchTab: String, CaseIterable, Identifiable {
    case home
    case agents
    case connections
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .agents: return "Agents"
        case .connections: return "Connect"
        case .settings: return "Settings"
        }
    }

    var systemImageName: String {
        switch self {
        case .home: return "house.fill"
        case .agents: return "terminal.fill"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .settings: return "slider.horizontal.3"
        }
    }
}

private struct OpenClickyNotchConnectionRow: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let state: OpenClickyNotchConnectionState
    let systemImageName: String
}

private enum OpenClickyNotchConnectionState: Equatable {
    case ready
    case available
    case needsAttention

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .available: return "Local"
        case .needsAttention: return "Needs setup"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .available: return DS.Colors.accentText
        case .needsAttention: return .orange
        }
    }
}

private struct OpenClickyNotchHeroCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImageName: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImageName)
                    .font(.system(size: 15, weight: .black))
                    .foregroundColor(accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(accent.opacity(0.15)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.12), Color.white.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct OpenClickyNotchMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let systemImageName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: systemImageName)
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(color)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 15, weight: .black))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.052)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct OpenClickyNotchEmptyState: View {
    let systemImageName: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImageName)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(DS.Colors.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
