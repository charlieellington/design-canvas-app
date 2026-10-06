// Bottom-right "What recipients see" card. 280×180pt default. Composites
// the orchestrator's captured bitmaps + included frame geometry into a
// scaled mini-canvas. Stage 14e refines the visual treatment; for now we
// ship a structurally correct preview.
//
// IMPORTANT: this card composites the orchestrator's captured NSImages —
// NOT the live WKWebView via CALayer.render(in:), which would blank
// out-of-process WebKit content.

import AppKit
import SwiftUI

struct RecipientPreviewCard: View {
    @ObservedObject var coordinator: ShareModeCoordinator
    @State private var collapsed: Bool = false

    private let cardSize = CGSize(width: 280, height: 180)
    private let surface = Color(red: 0x19 / 255, green: 0x1A / 255, blue: 0x1D / 255)
    private let textPrimary = Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)
    private let textMuted = Color(red: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                miniCanvas
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5),
                ),
        )
        .frame(width: cardSize.width, height: collapsed ? 32 : cardSize.height)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("What recipients see")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(textPrimary)
                if !collapsed {
                    Text("You are sharing this")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                }
            }
            Spacer()
            Button {
                collapsed.toggle()
            } label: {
                Text(collapsed ? "▴" : "✕")
                    .font(.system(size: 10))
                    .foregroundColor(textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityLabel("Recipient preview — shows what recipients will see")
    }

    @ViewBuilder
    private var miniCanvas: some View {
        if coordinator.includedFrameIDs.isEmpty {
            VStack {
                Spacer()
                Text("No frames selected — Restore all (⌥⌘R)")
                    .font(.system(size: 10))
                    .foregroundColor(textMuted)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            GeometryReader { geo in
                MiniCanvas(
                    frames: coordinator.includedFrameIDs.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
                    orchestrator: coordinator.captureOrchestrator,
                    canvasSize: geo.size,
                )
            }
            .clipped()
        }
    }
}

private struct MiniCanvas: View {
    let frames: [FrameRef]
    @ObservedObject var orchestrator: CaptureOrchestrator
    let canvasSize: CGSize

    var body: some View {
        let doc = AppServices.shared.document
        let geometries: [(FrameRef, CGRect, NSImage?)] = frames.compactMap { ref in
            guard let rect = frameRect(ref: ref, doc: doc) else { return nil }
            let image = orchestrator.image(for: ref)
            return (ref, rect, image)
        }
        guard let bbox = boundingBox(of: geometries.map(\.1)) else {
            return AnyView(EmptyView())
        }
        let scale = min(
            canvasSize.width / max(bbox.width, 1),
            canvasSize.height / max(bbox.height, 1),
        ) * 0.9
        let offsetX = (canvasSize.width - bbox.width * scale) / 2 - bbox.minX * scale
        let offsetY = (canvasSize.height - bbox.height * scale) / 2 - bbox.minY * scale
        return AnyView(
            ZStack(alignment: .topLeading) {
                ForEach(Array(geometries.enumerated()), id: \.offset) { _, item in
                    let (_, rect, image) = item
                    Group {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: rect.width * scale, height: rect.height * scale)
                    .offset(x: rect.minX * scale + offsetX, y: rect.minY * scale + offsetY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
        )
    }

    private func frameRect(ref: FrameRef, doc: DocumentModel) -> CGRect? {
        switch ref.kind {
        case .route:
            guard let r = doc.routes.first(where: { $0.id == ref.id }) else { return nil }
            return CGRect(x: r.x, y: r.y, width: r.width, height: r.effectiveHeight)
        case .markdown:
            guard let m = doc.documents.first(where: { $0.id == ref.id }) else { return nil }
            return CGRect(x: m.x, y: m.y, width: m.width, height: m.height)
        case .image:
            guard let i = doc.images.first(where: { $0.id == ref.id }) else { return nil }
            return CGRect(x: i.x, y: i.y, width: i.width, height: i.height)
        }
    }

    private func boundingBox(of rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}
