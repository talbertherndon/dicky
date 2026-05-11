// ThreeDGenerationService.swift
// Orchestrates 3D-asset generation requests from chat / agent tool calls.
// - Holds the active provider (Tripo by default).
// - Persists results to ~/Library/Application Support/OpenClicky/Generated3D/.
// - Publishes an ObservableObject the UI binds to for in-flight + finished jobs.

import Foundation
import SwiftUI

@MainActor
public final class ThreeDGenerationService: ObservableObject {

    // MARK: - Singleton

    public static let shared = ThreeDGenerationService()

    // MARK: - Public state

    /// In-flight jobs keyed by client-side job id.
    @Published public private(set) var jobs: [ThreeDJob] = []
    /// Completed assets, newest first.
    @Published public private(set) var assets: [ThreeDGenerationResult] = []

    // MARK: - Config

    private var provider: ThreeDGenerationProvider
    private let assetsDirectory: URL
    private let indexURL: URL

    public init(provider: ThreeDGenerationProvider? = nil) {
        let dir = ThreeDGenerationService.defaultAssetsDirectory()
        self.assetsDirectory = dir
        self.indexURL = dir.appendingPathComponent("index.json")
        self.provider = provider ?? TripoThreeDProvider(apiKeyProvider: {
            ThreeDGenerationService.readTripoAPIKey()
        })
        loadIndex()
    }

    public func setProvider(_ provider: ThreeDGenerationProvider) {
        self.provider = provider
    }

    // MARK: - Public API

    /// Kick off a generation job. Returns the job id; observe `jobs` and `assets`
    /// for progress and completion.
    @discardableResult
    public func generate(
        prompt: String,
        style: ThreeDStyle = .lowPolyStylized,
        quad: Bool = true,
        pbr: Bool = true
    ) -> UUID {
        let jobId = UUID()
        let job = ThreeDJob(
            id: jobId,
            prompt: prompt,
            style: style,
            status: .queued,
            progress: 0,
            message: "Submitting…",
            providerName: provider.displayName,
            startedAt: Date()
        )
        jobs.append(job)

        let request = ThreeDGenerationRequest(
            prompt: prompt,
            style: style,
            quad: quad,
            pbr: pbr
        )
        let dir = assetsDirectory
        let p = provider

        Task.detached { [weak self] in
            do {
                let result = try await p.generate(
                    request: request,
                    destinationDirectory: dir,
                    onProgress: { progress in
                        Task { @MainActor in
                            self?.update(jobId: jobId, with: progress)
                        }
                    }
                )
                await MainActor.run {
                    self?.finish(jobId: jobId, result: result)
                }
            } catch {
                await MainActor.run {
                    self?.fail(jobId: jobId, error: error)
                }
            }
        }

        return jobId
    }

    public func cancelJob(_ id: UUID) {
        // Best-effort: mark as cancelled. (URLSession task cancellation is wired
        // via Task.checkCancellation in providers; we'd need to track Tasks per
        // job to actually interrupt the network call — left as a follow-up.)
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs[idx].status = .cancelled
            jobs[idx].message = "Cancelled"
        }
    }

    public func clearJob(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    // MARK: - Mutation

    private func update(jobId: UUID, with progress: ThreeDGenerationProgress) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[idx].status = progress.status
        jobs[idx].progress = progress.progress ?? jobs[idx].progress
        if let m = progress.message { jobs[idx].message = m }
    }

    private func finish(jobId: UUID, result: ThreeDGenerationResult) {
        if let idx = jobs.firstIndex(where: { $0.id == jobId }) {
            jobs[idx].status = .success
            jobs[idx].progress = 1.0
            jobs[idx].message = "Ready"
            jobs[idx].resultGLBURL = result.glbURL
        }
        assets.insert(result, at: 0)
        persistIndex()
    }

    private func fail(jobId: UUID, error: Error) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[idx].status = .failed
        jobs[idx].message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Persistence

    private struct AssetRecord: Codable {
        let taskId: String
        let glbPath: String
        let thumbnailPath: String?
        let remoteGLBURL: URL?
        let provider: String
        let prompt: String
        let style: ThreeDStyle
        let createdAt: Date
    }

    private func loadIndex() {
        guard
            let data = try? Data(contentsOf: indexURL),
            let records = try? JSONDecoder.iso8601.decode([AssetRecord].self, from: data)
        else { return }
        let dir = assetsDirectory
        assets = records.compactMap { r in
            let glb = dir.appendingPathComponent(r.glbPath)
            guard FileManager.default.fileExists(atPath: glb.path) else { return nil }
            let thumb = r.thumbnailPath.map { dir.appendingPathComponent($0) }
            return ThreeDGenerationResult(
                taskId: r.taskId,
                glbURL: glb,
                thumbnailURL: thumb,
                remoteGLBURL: r.remoteGLBURL,
                provider: r.provider,
                prompt: r.prompt,
                style: r.style,
                createdAt: r.createdAt
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistIndex() {
        let records: [AssetRecord] = assets.map { a in
            AssetRecord(
                taskId: a.taskId,
                glbPath: a.glbURL.lastPathComponent,
                thumbnailPath: a.thumbnailURL?.lastPathComponent,
                remoteGLBURL: a.remoteGLBURL,
                provider: a.provider,
                prompt: a.prompt,
                style: a.style,
                createdAt: a.createdAt
            )
        }
        do {
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.iso8601.encode(records)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[ThreeDGenerationService] failed to write index: \(error)")
            #endif
        }
    }

    // MARK: - Paths & keys

    public static func defaultAssetsDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("Generated3D", isDirectory: true)
    }

    /// Reads the Tripo API key. Reads UserDefaults first (set from Settings UI),
    /// then env var. Swap for Keychain when wiring into the existing key flow.
    public static func readTripoAPIKey() -> String? {
        if let k = UserDefaults.standard.string(forKey: "OpenClicky.Tripo3D.APIKey"),
           !k.isEmpty { return k }
        if let env = ProcessInfo.processInfo.environment["TRIPO_API_KEY"],
           !env.isEmpty { return env }
        return nil
    }
}

// MARK: - Job

public struct ThreeDJob: Identifiable, Equatable {
    public let id: UUID
    public let prompt: String
    public let style: ThreeDStyle
    public var status: ThreeDTaskStatus
    public var progress: Double
    public var message: String
    public let providerName: String
    public let startedAt: Date
    public var resultGLBURL: URL?
}

// MARK: - JSON helpers

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
