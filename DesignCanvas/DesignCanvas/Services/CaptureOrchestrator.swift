// Per-Share-Mode-session capture orchestrator. Owns the cached-first +
// background fresh-capture state machine. Constructed by ShareModeCoordinator
// on `enter()`; cancelled on `exit()`. Never a singleton — `shareSessionID`
// in every async callback guards against cross-session mutation.
//
// 14.5a contract: calls go through ScreenshotService.capture(routeID:persist:)
// or .previewCapture(routeID:overrideDelayMs:) — NEVER takes its own snapshots.
// The orchestrator just sequences captures and updates frame states.

import AppKit
import Foundation

@MainActor
final class CaptureOrchestrator: ObservableObject {

    enum FrameCaptureState {
        case loading                                           // no cache, fresh in flight
        case refreshing(cachedImage: NSImage, startedAt: Date) // showing cached while fresh in flight
        case ready(image: NSImage, capturedAt: Date)           // fresh landed (or cached and no refresh)
        case failed(cachedImage: NSImage?, error: Error)       // retain cached for graceful fallback
    }

    @Published private(set) var frameStates: [FrameRef: FrameCaptureState] = [:]
    @Published private(set) var activeTaskCount: Int = 0
    @Published private(set) var failureCount: Int = 0

    let shareSessionID: UUID

    /// Last-successful image per frame — Stage 16b reads this to build the
    /// `ShareDraft.frames` map (cross-stage §6: "same pixels, no second capture").
    private(set) var committedImages: [FrameRef: NSImage] = [:]

    /// Per-frame context. Required so retry / re-capture work without the
    /// coordinator passing the frame back in.
    private var contexts: [FrameRef: FrameCaptureContext] = [:]
    private var tasks: [FrameRef: Task<Void, Never>] = [:]

    init(sessionID: UUID = UUID()) {
        self.shareSessionID = sessionID
    }

    // MARK: - Public API

    /// Seed contexts + cached state and kick off background fresh captures.
    func beginRefreshAll(routes: [RouteFrame], markdownIDs: [UUID], imageIDs: [UUID]) {
        for route in routes {
            let ref = FrameRef(kind: .route, id: route.id)
            contexts[ref] = .route(route: route)
            seedFromCache(ref: ref, routeID: route.id)
        }
        for id in markdownIDs {
            let ref = FrameRef(kind: .markdown, id: id)
            contexts[ref] = .markdown(id: id)
            // Markdown / image frames are static — they don't refresh through
            // the capture pipeline. Stage 16b composites them from view bitmaps.
            // Mark ready with a placeholder so the preview card can size them.
            frameStates[ref] = .ready(image: NSImage(), capturedAt: Date())
        }
        for id in imageIDs {
            let ref = FrameRef(kind: .image, id: id)
            contexts[ref] = .image(id: id)
            frameStates[ref] = .ready(image: NSImage(), capturedAt: Date())
        }
        // Fire refresh captures only for route frames — they're the only ones
        // that go through ScreenshotService.
        for route in routes {
            refresh(ref: FrameRef(kind: .route, id: route.id))
        }
    }

    /// Re-queue a single frame. Cancels any in-flight task for that frame.
    func refresh(ref: FrameRef) {
        guard let ctx = contexts[ref] else { return }
        guard case .route(let route) = ctx else { return }
        tasks[ref]?.cancel()
        tasks[ref] = Task { @MainActor [weak self] in
            await self?.runCapture(ref: ref, route: route)
        }
    }

    /// Retry only failed captures.
    func retryFailed() {
        for (ref, state) in frameStates {
            if case .failed = state {
                refresh(ref: ref)
            }
        }
    }

    /// Stop every in-flight task. Called by `ShareModeCoordinator.exit()`.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    /// Most-recent image for a frame, if any. Stage 16b's ShareDraft builder
    /// reads this map — see cross-stage §6.
    func image(for ref: FrameRef) -> NSImage? {
        switch frameStates[ref] {
        case .ready(let image, _): return image
        case .refreshing(let cached, _): return cached
        case .failed(let cached?, _): return cached
        default: return nil
        }
    }

    // MARK: - Internal

    private func seedFromCache(ref: FrameRef, routeID: UUID) {
        guard let service = AppServices.shared.screenshotService else {
            frameStates[ref] = .loading
            return
        }
        if let cached = service.cachedCapture(routeID: routeID) {
            frameStates[ref] = .refreshing(cachedImage: cached.image, startedAt: Date())
            committedImages[ref] = cached.image
        } else {
            frameStates[ref] = .loading
        }
    }

    private func runCapture(ref: FrameRef, route: RouteFrame) async {
        guard !Task.isCancelled else { return }
        guard let service = AppServices.shared.screenshotService else { return }
        let session = shareSessionID
        activeTaskCount += 1
        defer {
            activeTaskCount = max(0, activeTaskCount - 1)
            tasks.removeValue(forKey: ref)
        }
        do {
            // Use persist: false during Share Mode — only commit to disk on
            // upload. Avoids thrashing the cache for shares that user cancels.
            let result = try await service.capture(routeID: route.id, persist: false)
            guard session == shareSessionID else { return }   // session race guard
            committedImages[ref] = result.image
            frameStates[ref] = .ready(image: result.image, capturedAt: result.capturedAt)
        } catch {
            guard session == shareSessionID else { return }
            let cached: NSImage?
            switch frameStates[ref] {
            case .refreshing(let img, _): cached = img
            case .ready(let img, _):      cached = img
            default:                       cached = nil
            }
            frameStates[ref] = .failed(cachedImage: cached, error: error)
            failureCount += 1
        }
    }

    private enum FrameCaptureContext {
        case route(route: RouteFrame)
        case markdown(id: UUID)
        case image(id: UUID)
    }
}
