//
//  OpenClickyAgentStore.swift
//  OpenClicky
//
//  Two-root specialist agent registry. Lists agents by union of slugs from
//  both roots; per-agent loading delegates to OpenClickyAgentDefinition.load
//  which resolves files per-file (user root wins).
//

import Foundation
import Combine

@MainActor
final class OpenClickyAgentStore: ObservableObject {
  static let shared = OpenClickyAgentStore()
  nonisolated static let skillDiscoveryAgentSlug = "skill-discovery"

  @Published private(set) var agents: [OpenClickyAgentDefinition] = []

  let builtinRoot: URL
  let userRoot: URL

  private init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    self.builtinRoot = appSupport
      .appendingPathComponent("OpenClicky", isDirectory: true)
      .appendingPathComponent("agents", isDirectory: true)
    self.userRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".openclicky", isDirectory: true)
      .appendingPathComponent("agents", isDirectory: true)
    ensureRootsExist()
    reload()
  }

  private func ensureRootsExist() {
    try? FileManager.default.createDirectory(at: builtinRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
    ensureSkillDiscoveryAgentInstalled()
  }

  func reload() {
    let userSlugs = (try? FileManager.default.contentsOfDirectory(atPath: userRoot.path)) ?? []
    let builtinSlugs = (try? FileManager.default.contentsOfDirectory(atPath: builtinRoot.path)) ?? []
    let allSlugs = Set(userSlugs + builtinSlugs)
      .filter { !$0.hasPrefix(".") }
      .sorted()
    agents = allSlugs.compactMap { slug in
      OpenClickyAgentDefinition.load(slug: slug, userRoot: userRoot, builtinRoot: builtinRoot)
    }
  }

  func agent(slug: String) -> OpenClickyAgentDefinition? {
    agents.first { $0.slug == slug }
  }

  func create(slug rawSlug: String, displayName: String, soul: String = "", instructions: String = "", memory: String = "", heartbeat: String = "", description: String = "") throws -> OpenClickyAgentDefinition {
    let slug = Self.normalizedSlug(rawSlug)
    guard !slug.isEmpty else {
      throw NSError(domain: "OpenClickyAgentStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Slug must contain at least one alphanumeric character."])
    }
    if agents.contains(where: { $0.slug == slug }) {
      throw NSError(domain: "OpenClickyAgentStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "An agent with slug \"\(slug)\" already exists."])
    }
    try OpenClickyAgentDefinition.write(
      slug: slug,
      in: userRoot,
      metadata: OpenClickyAgentMetadata(displayName: displayName.isEmpty ? slug.capitalized : displayName, description: description),
      soul: soul,
      instructions: instructions,
      memory: memory,
      heartbeat: heartbeat.isEmpty ? Self.defaultHeartbeatTemplate(displayName: displayName) : heartbeat,
      skills: OpenClickyAgentSkillSelection()
    )
    reload()
    return agent(slug: slug) ?? OpenClickyAgentDefinition.load(slug: slug, userRoot: userRoot, builtinRoot: builtinRoot)!
  }

  func update(_ agent: OpenClickyAgentDefinition, soul: String, instructions: String, memory: String, heartbeat: String, displayName: String? = nil, description: String? = nil, skills: OpenClickyAgentSkillSelection? = nil) throws {
    var meta = agent.metadata
    if let dn = displayName { meta.displayName = dn }
    if let d = description { meta.description = d }
    try OpenClickyAgentDefinition.write(
      slug: agent.slug,
      in: userRoot,
      metadata: meta,
      soul: soul,
      instructions: instructions,
      memory: memory,
      heartbeat: heartbeat,
      skills: skills ?? agent.skills
    )
    reload()
  }

  /// Removes the user copy of an agent. If a built-in with the same slug
  /// exists, the agent reverts to the built-in version on next reload.
  func deleteUserCopy(slug: String) throws {
    if slug == Self.skillDiscoveryAgentSlug {
      throw NSError(domain: "OpenClickyAgentStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "The Skill Discovery agent is required by OpenClicky and cannot be deleted."])
    }
    let dir = userRoot.appendingPathComponent(slug, isDirectory: true)
    if FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.removeItem(at: dir)
    }
    reload()
  }

  static func normalizedSlug(_ raw: String) -> String {
    let lowered = raw.lowercased()
    let allowed = lowered.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
        return Character(scalar)
      }
      return "-"
    }
    let collapsed = String(allowed)
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
  }

  @discardableResult
  func ensureSkillDiscoveryAgentInstalled() -> OpenClickyAgentDefinition? {
    let slug = Self.skillDiscoveryAgentSlug
    let dir = builtinRoot.appendingPathComponent(slug, isDirectory: true)
    let metadataURL = dir.appendingPathComponent("agent.json")
    let instructionsURL = dir.appendingPathComponent("instructions.md")

    if FileManager.default.fileExists(atPath: metadataURL.path),
       FileManager.default.fileExists(atPath: instructionsURL.path) {
      return OpenClickyAgentDefinition.load(slug: slug, userRoot: userRoot, builtinRoot: builtinRoot)
    }

    do {
      try OpenClickyAgentDefinition.write(
        slug: slug,
        in: builtinRoot,
        metadata: OpenClickyAgentMetadata(
          displayName: "Skill Discovery",
          description: "Finds local and online skills for the apps OpenClicky sees you using.",
          accentColorHex: "8B5CF6"
        ),
        soul: Self.skillDiscoveryAgentSoul,
        instructions: Self.skillDiscoveryAgentInstructions,
        memory: "Use concise JSON output for Connect tab suggestions. Prefer local, already-installed, and official integration paths.\n",
        heartbeat: Self.defaultHeartbeatTemplate(displayName: "Skill Discovery"),
        skills: OpenClickyAgentSkillSelection(enabledSkillIDs: ["skill-installer", "find-skills", "openai-docs"])
      )
      return OpenClickyAgentDefinition.load(slug: slug, userRoot: userRoot, builtinRoot: builtinRoot)
    } catch {
      print("OpenClicky skill discovery agent seed failed: \(error)")
      return nil
    }
  }

  private static let skillDiscoveryAgentSoul = """
  You are OpenClicky's built-in Skill Discovery specialist.

  Be quiet, efficient, and conservative. Your job is not to collect every possible tool; it is to find a small number of useful skill or connector options that match the apps and workflows OpenClicky sees the user using.
  """

  private static let skillDiscoveryAgentInstructions = """
  Find useful OpenClicky Agent Mode skills for currently relevant apps and workflows.

  Rules:
  - Search local skill folders first.
  - Prefer existing local skills, official integrations, and low-risk install paths.
  - Use targeted online research only after local lookup.
  - Do not scan huge home directories blindly.
  - Write at most 8 deduplicated suggestions to the JSON path requested by the automation prompt.
  - Each suggestion must include id, title, detail, source, and installPrompt.
  - Keep installPrompt actionable for OpenClicky Agent Mode.
  """

  /// Default HEARTBEAT.md scaffolding for a new agent. Mirrors the
  /// openclaw / grok-cli persona convention (last check-in + pending
  /// items + done log) so the agent can self-update across sessions.
  static func defaultHeartbeatTemplate(displayName: String) -> String {
    return """
    # HEARTBEAT

    Scheduled check-ins and pending maintenance for the \(displayName) agent.

    ## Conventions

    - Read at session start.
    - Tick off completed items.
    - Add new check-ins as they're identified.
    - Update `Last check-in` timestamp on every pass.

    ## State

    **Last check-in:** (none yet)
    **Status:** New agent, no pending work.

    ## Pending

    - [ ] (add items here)

    ## Done

    """
  }

  /// First-run: copy any bundled built-in agents from the app's resource
  /// bundle into the built-in App Support root. Idempotent — only copies
  /// agent dirs that don't already exist.
  func seedBuiltinsFromBundleIfNeeded() {
    guard let resourcesURL = Bundle.main.resourceURL else { return }
    let bundledRoot = resourcesURL
      .appendingPathComponent("AppResources", isDirectory: true)
      .appendingPathComponent("OpenClicky", isDirectory: true)
      .appendingPathComponent("agents", isDirectory: true)
    guard FileManager.default.fileExists(atPath: bundledRoot.path) else { return }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: bundledRoot.path)) ?? []
    for slug in entries where !slug.hasPrefix(".") {
      let src = bundledRoot.appendingPathComponent(slug, isDirectory: true)
      let dst = builtinRoot.appendingPathComponent(slug, isDirectory: true)
      if FileManager.default.fileExists(atPath: dst.path) { continue }
      do {
        try FileManager.default.copyItem(at: src, to: dst)
      } catch {
        print("OpenClicky agent seed failed for \(slug): \(error)")
      }
    }
    reload()
  }
}
