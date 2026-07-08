import Foundation

/// The fail-CLOSED redaction gate, shared by the egress paths (Claude send +
/// file export in Phase D). A shot step with a blur annotation OR a crop that
/// has NOT been baked into a `flattened` render must NOT fall back to the raw
/// (un-redacted / uncropped) screenshot — it is refused. Only a step with
/// neither may read the original shot. Ported from render-gate.ts; implemented
/// once so the Claude and export paths can't drift apart.
public struct SendableRender: Equatable, Sendable {
    /// Absolute, project-confined path to the image to read.
    public var abs: String
    public var mediaType: MediaType
    public var ext: String

    public enum MediaType: String, Sendable { case png = "image/png", jpeg = "image/jpeg" }
}

public enum RenderGateError: Error, LocalizedError, Equatable {
    case unbakedRedaction(step: String, verb: String)
    case noReadableShot(step: String)

    public var errorDescription: String? {
        switch self {
        case .unbakedRedaction(let step, let verb):
            "\(step) has a redaction or crop that hasn't been baked into a render yet — refusing to \(verb) the raw screenshot. Open it in the editor and save, then retry."
        case .noReadableShot(let step):
            "\(step) has no readable screenshot."
        }
    }
}

/// Decide which on-disk image is safe to read for a step, or throw (fail-closed).
/// - dir: the resolved project folder.
/// - stepLabel: caller-supplied label for error messages (Claude and export
///   number steps differently, so the label is passed in).
/// - verb: "send" (to Claude) or "export" — only affects the message.
/// Reads use the lexical `confinePath` (a read can't redirect a write).
public func resolveSendableRender(
    dir: String, step: ProjectStep, stepLabel: String, verb: String
) throws -> SendableRender {
    let hasBlur = step.annotations.contains { if case .blur = $0 { return true } else { return false } }
    let rel = (step.flattened?.isEmpty == false) ? step.flattened : nil
    // Fail closed: an unbaked redaction or crop must never read the raw screenshot.
    if rel == nil, hasBlur || step.crop != nil {
        throw RenderGateError.unbakedRedaction(step: stepLabel, verb: verb)
    }
    let relToRead = rel ?? step.screenshot
    guard !relToRead.isEmpty, let abs = confinePath(dir: dir, rel: relToRead) else {
        throw RenderGateError.noReadableShot(step: stepLabel)
    }
    let ext = ((relToRead as NSString).pathExtension).lowercased()
    let mediaType: SendableRender.MediaType = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
    return SendableRender(abs: abs, mediaType: mediaType, ext: ext.isEmpty ? "png" : ext)
}
