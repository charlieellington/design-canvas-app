// Sequences the upload pipeline: POST /create → PUT /image per frame →
// POST /finalise. Updates `ShareModeCoordinator.createLinkState` as it
// progresses. Cross-stage §6: the JPEG bytes uploaded are the exact bytes
// the CaptureOrchestrator produced — no re-capture.

import AppKit
import Foundation

@MainActor
final class ShareUploadOrchestrator {

    static let shared = ShareUploadOrchestrator()

    private let service = ShareService.shared

    private init() {}

    /// Drive the create → upload → finalise sequence. On success, calls
    /// `coordinator.recordCreatedShare(url:)` which transitions
    /// `createLinkState` to `.copied(url:)` and surfaces the post-exit chip.
    /// On any failure, sets `createLinkState = .failed(message:)`.
    func upload(draft: ShareDraft, coordinator: ShareModeCoordinator) async {
        let total = draft.frames.count

        // POST /create
        coordinator.update(createLinkState: .creating(current: 0, total: total))
        let createPayload: SharePayloadWire
        do {
            createPayload = try buildCreatePayload(draft: draft)
        } catch {
            coordinator.update(createLinkState: .failed(message: "Could not build payload: \(error.localizedDescription)"))
            return
        }
        let created: CreatedShare
        do {
            created = try await service.createShare(payload: createPayload, idempotencyKey: draft.idempotencyKey)
        } catch {
            coordinator.update(createLinkState: .failed(message: humanise(error)))
            return
        }

        // PUT /image per frame
        for (index, frame) in draft.frames.enumerated() {
            coordinator.update(createLinkState: .creating(current: index, total: total))
            guard let jpeg = jpegEncode(image: frame.image) else {
                coordinator.update(createLinkState: .failed(message: "Frame \(index + 1) JPEG encode failed"))
                return
            }
            do {
                try await service.uploadFrame(
                    shareID: created.id,
                    uploadToken: created.uploadToken,
                    clientFrameId: frame.ref.id,
                    frameType: frame.ref.kind.rawValue,
                    sourceIdentifier: frame.sourceIdentifier,
                    displayName: frame.displayName,
                    contentHash: frame.contentHash,
                    width: frame.geometry.width,
                    height: frame.geometry.height,
                    viewportWidth: Int(frame.viewport.width),
                    viewportHeight: Int(frame.viewport.height),
                    x: frame.geometry.x,
                    y: frame.geometry.y,
                    displayOrder: index,
                    jpegData: jpeg,
                )
            } catch {
                coordinator.update(createLinkState: .failed(message: "Frame upload failed: \(humanise(error))"))
                return
            }
        }

        // POST /finalise
        coordinator.update(createLinkState: .creating(current: total, total: total))
        do {
            let result = try await service.finaliseShare(shareID: created.id, uploadToken: created.uploadToken)
            guard let url = URL(string: result.url) else {
                coordinator.update(createLinkState: .failed(message: "Invalid share URL returned"))
                return
            }
            // Copy to clipboard immediately so the chip's [⌥⌘L] re-copy works.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            coordinator.recordCreatedShare(url: url)
        } catch {
            coordinator.update(createLinkState: .failed(message: humanise(error)))
        }
    }

    // MARK: - Build /create payload

    private func buildCreatePayload(draft: ShareDraft) throws -> SharePayloadWire {
        let frames: [FrameWire] = draft.frames.map { f in
            switch f.ref.kind {
            case .route:
                return .route(RouteFrameWire(
                    clientFrameId: f.ref.id.uuidString,
                    x: f.geometry.x,
                    y: f.geometry.y,
                    width: f.geometry.width,
                    height: f.geometry.height,
                    displayName: f.displayName,
                    routePath: f.sourceIdentifier,
                ))
            case .markdown:
                return .markdown(StaticFrameWire(
                    clientFrameId: f.ref.id.uuidString,
                    x: f.geometry.x,
                    y: f.geometry.y,
                    width: f.geometry.width,
                    height: f.geometry.height,
                    displayName: f.displayName,
                    contentHash: f.contentHash,
                ))
            case .image:
                return .image(StaticFrameWire(
                    clientFrameId: f.ref.id.uuidString,
                    x: f.geometry.x,
                    y: f.geometry.y,
                    width: f.geometry.width,
                    height: f.geometry.height,
                    displayName: f.displayName,
                    contentHash: f.contentHash,
                ))
            }
        }
        return SharePayloadWire(
            schemaVersion: 1,
            title: draft.title ?? draft.defaultTitle,
            styling: draft.styling,
            frames: frames,
            initialView: draft.initialView,
            pageId: nil,
        )
    }

    // MARK: - JPEG encoding

    private func jpegEncode(image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: - Error helpers

    private func humanise(_ error: Error) -> String {
        if let share = error as? ShareError {
            return share.errorDescription ?? "\(share)"
        }
        return error.localizedDescription
    }
}
