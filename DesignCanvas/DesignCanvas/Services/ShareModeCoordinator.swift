// Share Mode state machine. Owns mode lifecycle, isolated frame positions, the
// canonical include-set, the mode-scoped undo stack, and the CaptureOrchestrator
// lifecycle. Cross-stage-contracts §6 — the Create Link path produces a
// `ShareDraft` value that Stage 16b uploads verbatim.

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class ShareModeCoordinator: ObservableObject {

    enum State: Equatable {
        case inactive, entering, active, exiting
    }

    /// Create-Link button progress, mirroring the three states in stage-14a §6.
    enum CreateLinkState: Equatable {
        case idle
        case creating(current: Int, total: Int)
        case copied(url: URL)
        case failed(message: String)
    }

    enum EntryTrigger {
        case keyboardShortcut, buttonClick, urlScheme
    }

    enum ExitReason {
        case escape, copiedAuto, done, failure
    }

    @Published private(set) var state: State = .inactive
    @Published private(set) var shareSessionID: UUID = UUID()
    @Published private(set) var includedFrameIDs: Set<FrameRef> = []
    @Published private(set) var hiddenFrameIDs: Set<FrameRef> = []
    @Published private(set) var isolatedFramePositions: [FrameRef: CGPoint] = [:]
    @Published private(set) var captureOrchestrator: CaptureOrchestrator = CaptureOrchestrator()
    @Published private(set) var createLinkState: CreateLinkState = .idle
    @Published private(set) var lastCreatedShareURL: URL?

    /// Persisted across launches so `⌥⌘L` re-copies the most recent share.
    private static let lastURLKey = "shareMode.lastCreatedShareURL"

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.lastURLKey),
           let url = URL(string: saved) {
            self.lastCreatedShareURL = url
        }
    }

    // MARK: - Entry

    /// Enter Share Mode. Regenerates the session ID, snapshots the current
    /// frame set into `includedFrameIDs`, builds a fresh CaptureOrchestrator
    /// keyed to the new session, and kicks off cached-first refresh of all
    /// route frames.
    func enter(trigger: EntryTrigger = .buttonClick) {
        guard state == .inactive else { return }
        state = .entering
        shareSessionID = UUID()
        let doc = AppServices.shared.document
        includedFrameIDs = Set(
            doc.routes.map    { FrameRef(kind: .route,    id: $0.id) } +
            doc.documents.map { FrameRef(kind: .markdown, id: $0.id) } +
            doc.images.map    { FrameRef(kind: .image,    id: $0.id) },
        )
        hiddenFrameIDs = []
        isolatedFramePositions = [:]
        createLinkState = .idle

        let orchestrator = CaptureOrchestrator(sessionID: shareSessionID)
        captureOrchestrator = orchestrator
        orchestrator.beginRefreshAll(
            routes: doc.routes,
            markdownIDs: doc.documents.map(\.id),
            imageIDs: doc.images.map(\.id),
        )

        state = .active
    }

    // MARK: - Exit

    func exit(reason: ExitReason = .escape) {
        guard state == .active || state == .entering else { return }
        state = .exiting
        captureOrchestrator.cancelAll()
        isolatedFramePositions = [:]
        hiddenFrameIDs = []
        includedFrameIDs = []
        // Note: createLinkState retained briefly so the chip can read the URL.
        state = .inactive
    }

    // MARK: - Frame ops

    func removeFromShare(frame: FrameRef) {
        guard state == .active else { return }
        includedFrameIDs.remove(frame)
        hiddenFrameIDs.insert(frame)
    }

    /// "Share only this {route|doc|image}". Hides everything else; reversible
    /// via `restoreAllFrames()`.
    func shareOnlyThisFrame(frame: FrameRef) {
        guard state == .active else { return }
        let others = includedFrameIDs.filter { $0 != frame }
        hiddenFrameIDs.formUnion(others)
        includedFrameIDs = [frame]
    }

    /// Emergency unwind from "Share only this frame" — restores every hidden
    /// frame back into `includedFrameIDs`.
    func restoreAllFrames() {
        guard state == .active else { return }
        includedFrameIDs.formUnion(hiddenFrameIDs)
        hiddenFrameIDs = []
    }

    func reframe(frame: FrameRef, to position: CGPoint) {
        guard state == .active else { return }
        isolatedFramePositions[frame] = position
    }

    // MARK: - Create Link

    /// Build the ShareDraft for Stage 16b's upload pipeline. Cross-stage §6 —
    /// the bitmap for each frame is the LAST successful capture from the
    /// orchestrator; we never re-capture at upload time.
    func buildShareDraft(title: String? = nil) -> ShareDraft? {
        let doc = AppServices.shared.document
        let camera = AppServices.shared.camera

        // Build per-frame entries — only included frames.
        var entries: [ShareDraftFrame] = []
        for ref in includedFrameIDs {
            let image = captureOrchestrator.image(for: ref) ?? NSImage()
            let geom: FrameGeometry
            let viewport: CGSize
            let sourceID: String
            let displayName: String?
            switch ref.kind {
            case .route:
                guard let r = doc.routes.first(where: { $0.id == ref.id }) else { continue }
                geom = FrameGeometry(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.effectiveHeight))
                viewport = CGSize(width: r.width, height: r.effectiveHeight)
                sourceID = r.path
                displayName = r.displayName
            case .markdown:
                guard let m = doc.documents.first(where: { $0.id == ref.id }) else { continue }
                geom = FrameGeometry(x: Double(m.x), y: Double(m.y), width: Double(m.width), height: Double(m.height))
                viewport = CGSize(width: m.width, height: m.height)
                sourceID = ref.id.uuidString
                displayName = m.displayName
            case .image:
                guard let i = doc.images.first(where: { $0.id == ref.id }) else { continue }
                geom = FrameGeometry(x: Double(i.x), y: Double(i.y), width: Double(i.width), height: Double(i.height))
                viewport = CGSize(width: i.width, height: i.height)
                sourceID = ref.id.uuidString
                displayName = i.displayName
            }
            entries.append(ShareDraftFrame(
                ref: ref,
                image: image,
                geometry: geom,
                viewport: viewport,
                sourceIdentifier: sourceID,
                displayName: displayName,
                contentHash: nil,
            ))
        }
        guard !entries.isEmpty else { return nil }

        // initialView at exit time: centre of the bounding box of included
        // frames at the current camera zoom. CanvasCamera doesn't track the
        // viewport size directly; the bounding-box centre is a stable enough
        // proxy that maps Stage 15's d3-zoom hydration to a sensible default.
        let xs = entries.flatMap { [$0.geometry.x, $0.geometry.x + $0.geometry.width] }
        let ys = entries.flatMap { [$0.geometry.y, $0.geometry.y + $0.geometry.height] }
        let centreX = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        let centreY = ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
        let scale = max(0.01, min(Double(camera.zoom), 100))
        let initialView = InitialView(x: centreX, y: centreY, scale: scale)

        let activeName = doc.activeCanvas.name
        let defaultTitle: String? = activeName == "Working Canvas" ? nil : activeName

        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0

        return ShareDraft(
            frames: entries,
            viewport: CGSize(width: 1440, height: 900),
            backingScale: backingScale,
            initialView: initialView,
            styling: doc.styling,
            title: title,
            defaultTitle: defaultTitle,
            idempotencyKey: UUID(),
        )
    }

    /// Mutator used by `ShareUploadOrchestrator` to drive Create Link progress.
    func update(createLinkState: CreateLinkState) {
        self.createLinkState = createLinkState
    }

    /// Stage 16b — drive the upload pipeline. Build the draft, hand off to
    /// `ShareUploadOrchestrator`. Success transitions to `.copied(url:)` and
    /// surfaces the post-exit chip; failure stays in the action cluster as
    /// "✕ Failed — Retry" so the user can fix the cause and try again.
    func createLink() async {
        guard state == .active else { return }
        guard let draft = buildShareDraft() else {
            createLinkState = .failed(message: "No frames selected")
            return
        }
        await ShareUploadOrchestrator.shared.upload(draft: draft, coordinator: self)
    }

    func recordCreatedShare(url: URL) {
        lastCreatedShareURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: Self.lastURLKey)
        createLinkState = .copied(url: url)
    }
}
