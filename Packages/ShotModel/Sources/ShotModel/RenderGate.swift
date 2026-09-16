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
/// Egress reads go through `confinePathNoSymlinks`: a lexical-only check would
/// pass a symlinked `shots/`/leaf that points outside the project, and
/// `Data(contentsOf:)` follows symlinks — so a shared project could redirect the
/// read to an arbitrary file (e.g. ~/.ssh/id_rsa) and exfiltrate it to Claude or
/// into an export. The lstat-reject layer refuses any symlinked component.
public func resolveSendableRender(
    dir: String, step: ProjectStep, stepLabel: String, verb: String
) throws -> SendableRender {
    // `.unknown` counts. An annotation whose geometry fails to decode — a blur
    // written by a newer build, or a hand-edited one — becomes `.unknown`, not
    // `.blur`, so matching only `.blur` meant `hasBlur` was FALSE for something
    // the file still says is a redaction, and the raw screenshot was cleared for
    // egress to Claude and into exports (#109).
    //
    // The manifest keeps the value verbatim, so nothing looks wrong on inspection:
    // only its meaning to this gate was lost.
    //
    // Erring toward "might be a redaction" is the whole point of a fail-closed
    // gate. The cost is that a future NON-redacting annotation type forces an
    // unnecessary re-save on an older build; the cost the other way is leaking an
    // un-redacted screenshot, which is what this exists to prevent.
    let mayRedact = step.annotations.contains {
        switch $0 {
        case .blur, .unknown: true
        default: false
        }
    }
    let rel = (step.flattened?.isEmpty == false) ? step.flattened : nil
    // Fail closed: an unbaked redaction or crop must never read the raw screenshot.
    if rel == nil, mayRedact || step.crop != nil {
        throw RenderGateError.unbakedRedaction(step: stepLabel, verb: verb)
    }
    let relToRead = rel ?? step.screenshot
    guard !relToRead.isEmpty, let abs = confinePathNoSymlinks(dir: dir, rel: relToRead) else {
        throw RenderGateError.noReadableShot(step: stepLabel)
    }
    let ext = ((relToRead as NSString).pathExtension).lowercased()
    let mediaType: SendableRender.MediaType = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
    return SendableRender(abs: abs, mediaType: mediaType, ext: ext.isEmpty ? "png" : ext)
}
