//
//  ConversationSidebarView.swift
//  OpenClicky
//
//  ChatGPT-style left sidebar. Fully hides when collapsed (width 0) — the
//  only collapse toggle lives in the chat header bar so there's never two.
//  Sidebar is for history / drill-through; live agent tasks use the
//  agentTeamStrip at the top of the chat pane.
//

import SwiftUI

struct ConversationSidebarView: View {
  @ObservedObject var companion: CompanionManager
  @State private var search: String = ""
  @State private var showArchived: Bool = false
  @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
  @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
  @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
  @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0

  // ChatGPT sidebar palette
  static let bg = Color(red: 0.106, green: 0.106, blue: 0.106)              // #1b1b1b
  static let activeRow = Color(red: 0.176, green: 0.176, blue: 0.180)       // ~#2d2d2e
  static let textPrimary = Color(red: 0.92, green: 0.92, blue: 0.93)
  static let textSecondary = Color(red: 0.62, green: 0.62, blue: 0.64)
  static let expandedWidth: CGFloat = 260

  private var appFont: OpenClickyResponseCaptionFont {
    OpenClickyResponseCaptionFont.resolved(appFontRawValue)
  }

  private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
  private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

  private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
    appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
  }

  private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
    guard appBoldTextEnabled else { return weight }
    switch weight {
    case .regular, .medium:
      return .semibold
    case .semibold:
      return .bold
    default:
      return weight
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      searchField
      list
      footer
    }
    .frame(width: Self.expandedWidth)
    .background(Self.bg)
  }

  private var header: some View {
    HStack(spacing: 8) {
      // logo / app mark
      Circle()
        .fill(Color.white.opacity(0.85))
        .frame(width: 22, height: 22)
        .overlay(
          Text("O")
            .font(appUIFont(size: max(12, subtextFontSize + 1), weight: .bold))
            .foregroundColor(.black)
        )
      Spacer()
      Button(action: newChat) {
        Image(systemName: "square.and.pencil")
          .font(appUIFont(size: max(14, subtextFontSize + 2), weight: .medium))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("New chat")
    }
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 6)
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(appUIFont(size: max(11, subtextFontSize), weight: .medium))
        .foregroundColor(Self.textSecondary)
      TextField("Search", text: $search)
        .textFieldStyle(.plain)
        .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .medium))
        .foregroundColor(Self.textPrimary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.white.opacity(0.05))
    )
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
  }

  private var activeSessions: [CodexAgentSession] {
    companion.codexAgentSessions
      .filter { !companion.archivedSessionIDs.contains($0.id) }
      .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
  }

  private var archivedSessions: [CodexAgentSession] {
    companion.codexAgentSessions
      .filter { companion.archivedSessionIDs.contains($0.id) }
      .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 1) {
        sectionLabel("Agents")
        ForEach(activeSessions) { session in
          row(session: session, isArchived: false)
        }

        if !archivedSessions.isEmpty {
          Button(action: { showArchived.toggle() }) {
            HStack(spacing: 4) {
              Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                .font(appUIFont(size: max(9, subtextFontSize - 2), weight: .semibold))
              Text("Archived")
                .font(appUIFont(size: max(11, subtextFontSize), weight: .semibold))
              Text("\(archivedSessions.count)")
                .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .medium))
                .foregroundColor(Self.textSecondary.opacity(0.7))
              Spacer()
            }
            .foregroundColor(Self.textSecondary)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)
          }
          .buttonStyle(.plain)

          if showArchived {
            ForEach(archivedSessions) { session in
              row(session: session, isArchived: true)
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text)
      .font(appUIFont(size: max(11, subtextFontSize), weight: .semibold))
      .foregroundColor(Self.textSecondary)
      .padding(.horizontal, 14)
      .padding(.top, 6)
      .padding(.bottom, 4)
  }

  private func row(session: CodexAgentSession, isArchived: Bool) -> some View {
    let isActive = session.id == companion.activeCodexAgentSessionID
    return Button(action: { companion.selectCodexAgentSession(session.id) }) {
      HStack(spacing: 8) {
        Text(session.title)
          .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .regular))
          .foregroundColor(isActive ? Self.textPrimary : Self.textPrimary.opacity(0.85))
          .lineLimit(1)
        Spacer()
        if isArchived {
          Button(action: { companion.unarchiveSession(session.id) }) {
            Image(systemName: "tray.and.arrow.up")
              .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .medium))
              .foregroundColor(Self.textSecondary)
          }
          .buttonStyle(.plain)
          .help("Unarchive")
        } else {
          Button(action: { companion.archiveSession(session.id) }) {
            Image(systemName: "archivebox")
              .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .medium))
              .foregroundColor(Self.textSecondary)
          }
          .buttonStyle(.plain)
          .help("Archive")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(isActive ? Self.activeRow : Color.clear)
      )
      .padding(.horizontal, 6)
    }
    .buttonStyle(.plain)
    .help(session.title)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(Color(red: 0.30, green: 0.55, blue: 0.95))
        .frame(width: 26, height: 26)
        .overlay(
          Text("J")
            .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .semibold))
            .foregroundColor(.white)
        )
      VStack(alignment: .leading, spacing: 0) {
        Text("Jason Kneen")
          .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .semibold))
          .foregroundColor(Self.textPrimary)
      }
      Spacer()
      Image(systemName: "ellipsis")
        .font(appUIFont(size: max(11, subtextFontSize), weight: .medium))
        .foregroundColor(Self.textSecondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func newChat() {
    _ = companion.createAndSelectNewCodexAgentSession()
  }
}
