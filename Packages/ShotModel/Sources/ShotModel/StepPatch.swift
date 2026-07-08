import Foundation

/// A three-state patch field: leave the current value, or set it (including to
/// nil for clearable fields). Mirrors the TS `Object.assign` semantics where a
/// key's ABSENCE means "leave" and its presence — even as null — means "write."
/// Needed for `crop`/`callout`, which are cleared by writing null.
public enum PatchField<T: Sendable>: Sendable {
    case unset
    case set(T)

    public var isSet: Bool {
        if case .set = self { return true }
        return false
    }

    public var value: T? {
        if case .set(let v) = self { return v }
        return nil
    }
}

/// Editor/report-mutable fields of a step (the Swift analog of the TS StepPatch).
/// A nil plain-Optional field means "leave unchanged"; `crop`/`callout` use
/// PatchField so they can be explicitly cleared.
public struct StepPatch: Sendable {
    public var caption: String?
    public var note: String?
    public var heading: String?
    public var body: String?
    public var kind: StepKind?
    public var markerColor: String?
    public var markerBaked: Bool?
    public var reportZoom: Double?
    public var reportPanX: Double?
    public var reportPanY: Double?
    public var click: StepClick?
    /// nil = leave; non-nil = replace the whole annotation list.
    public var annotations: [Annotation]?
    /// .unset = leave; .set(nil) = clear the crop; .set(rect) = set it.
    public var crop: PatchField<Rect?> = .unset
    /// .unset = leave; .set(nil) = convert back to plain text; .set(kind) = set.
    public var callout: PatchField<CalloutKind?> = .unset

    public init() {}
}

/// Apply a patch to a step and, when NO fresh render is co-written, invalidate
/// any cached flattened render whose redaction/crop the patch just changed.
/// Ported from step-render.ts: redaction is enforced by render FRESHNESS, not
/// mere existence — a new or changed blur/crop with no re-bake MUST drop the
/// stale render so the next egress is forced to re-flatten. Shared by updateStep
/// and mergeSteps so the two can't drift.
public func applyPatchAndInvalidate(_ step: inout ProjectStep, _ patch: StepPatch, hasFreshPng: Bool) {
    if let v = patch.caption { step.caption = v }
    if let v = patch.note { step.note = v }
    if let v = patch.heading { step.heading = v }
    if let v = patch.body { step.body = v }
    if let v = patch.kind { step.kind = v }
    if let v = patch.markerColor { step.markerColor = v }
    if let v = patch.markerBaked { step.markerBaked = v }
    if let v = patch.reportZoom { step.reportZoom = v }
    if let v = patch.reportPanX { step.reportPanX = v }
    if let v = patch.reportPanY { step.reportPanY = v }
    if let v = patch.click { step.click = v }
    if let v = patch.annotations { step.annotations = v }
    if case .set(let v) = patch.crop { step.crop = v }
    if case .set(let v) = patch.callout { step.callout = v }

    if hasFreshPng { return } // caller wrote the fresh render + set flattened/renderRev
    if patch.annotations != nil || patch.crop.isSet {
        step.flattened = nil
        // The dropped render also carried the baked marker; the next bake redoes it.
        step.markerBaked = false
    }
}
