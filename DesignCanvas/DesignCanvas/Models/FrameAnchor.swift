// Canonical Mac mirror of FrameAnchor (cross-stage-contracts §1). ONE concept,
// ONE name, ONE shape across TS and Swift. `pageId` is OMITTED on the public
// wire — the server strips it. `contentHash` is optional content-identity used
// by Stage 17/18 ghost-pin re-link. Old names FrameRef / FrameIdentity /
// LocalCommentAnchor / FrameShareSignature / canonicalPath are deleted.

import Foundation

struct FrameAnchor: Codable, Hashable {

    enum Kind: String, Codable {
        case route, markdown, image
    }

    let kind: Kind

    /// Mac-generated UUID. Stable across share + Update Share. Becomes the
    /// `client_frame_id` persistence key on the server.
    let clientFrameId: UUID

    /// Stage 14d page scope. OMITTED on the public wire.
    let pageId: UUID?

    /// `sha256:<64 hex chars>`. Optional content identity for markdown / image
    /// frames so Stage 17/18 can re-link a ghost pin to its new home after the
    /// underlying file is renamed.
    let contentHash: String?

    init(kind: Kind, clientFrameId: UUID, pageId: UUID? = nil, contentHash: String? = nil) {
        self.kind = kind
        self.clientFrameId = clientFrameId
        self.pageId = pageId
        self.contentHash = contentHash
    }
}
