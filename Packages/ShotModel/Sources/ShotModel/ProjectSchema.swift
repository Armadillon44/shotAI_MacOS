import Foundation

/// shotAI project model — the on-disk schema for a single recording project.
/// This is a field-for-field mirror of the Windows app's contract
/// (`shotAI-original/src/shared/project.ts`, schema v1). Each project is a
/// self-contained folder:
///   <projects-dir>/<uuid>/
///     project.json   (this manifest)
///     shots/         (original captures, step-0001.png …)
///     export/        (generated HTML / PDF / MD; export/.render holds flattens)
///
/// Compatibility rules:
/// - Decoding is DEFENSIVE, mirroring the Windows `readManifest`/`normalizeSteps`
///   coercions: missing/corrupt fields degrade to defaults, they never fail the
///   whole open.
/// - Unknown manifest/step keys and unknown annotation types are preserved in
///   `extra` bags / an `.unknown` case so a Mac-side rewrite can't destroy data
///   written by a newer Windows build.
/// - Encoding reproduces the Windows writer's key order and null-vs-absent shape
///   (JSON.stringify(manifest, null, 2)).

public let projectSchemaVersion = 1

public let projectManifestFilename = "project.json"

// MARK: - Geometry

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Capture target (chosen before recording; persisted in the manifest)

public enum CaptureMode: String, Codable, Sendable {
    case auto, window, area, screen
}

public struct CaptureTarget: Codable, Equatable, Sendable {
    public struct WindowRef: Codable, Equatable, Sendable {
        public var id: Int
        public var pid: Int
        public var title: String
        public init(id: Int, pid: Int, title: String) {
            self.id = id
            self.pid = pid
            self.title = title
        }
    }

    public var mode: CaptureMode
    /// 'screen' — the capture backend's monitor id.
    public var monitorId: Int?
    /// 'window' — the picked window (re-resolved each step in case it moved).
    public var window: WindowRef?
    /// 'area' — fixed rectangle in global physical pixels.
    public var area: Rect?

    public init(mode: CaptureMode, monitorId: Int? = nil, window: WindowRef? = nil, area: Rect? = nil) {
        self.mode = mode
        self.monitorId = monitorId
        self.window = window
        self.area = area
    }

    // Tolerant: an unrecognized mode (future schema) degrades to .auto rather
    // than failing the manifest open; the raw value is not preserved because the
    // Windows reader performs the same coercion.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(CaptureMode.self, forKey: .mode)) ?? .auto
        monitorId = try? c.decodeIfPresent(Int.self, forKey: .monitorId)
        window = try? c.decodeIfPresent(WindowRef.self, forKey: .window)
        area = try? c.decodeIfPresent(Rect.self, forKey: .area)
    }
}

// MARK: - Per-step capture context

public struct CapturedWindow: Codable, Equatable, Sendable {
    /// App / executable name — "chrome.exe" on Windows, "Google Chrome" here.
    public var app: String
    public var title: String
    public var pid: Int
    public var bounds: Rect?

    enum CodingKeys: String, CodingKey { case app, title, pid, bounds }

    public init(app: String, title: String, pid: Int, bounds: Rect?) {
        self.app = app
        self.title = title
        self.pid = pid
        self.bounds = bounds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? c.decodeIfPresent(String.self, forKey: .app)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        pid = (try? c.decodeIfPresent(Int.self, forKey: .pid)) ?? 0
        bounds = try? c.decodeIfPresent(Rect.self, forKey: .bounds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encode(title, forKey: .title)
        try c.encode(pid, forKey: .pid)
        try c.encode(bounds, forKey: .bounds) // "bounds": null when absent — TS shape
    }
}

public struct CapturedMonitor: Codable, Equatable, Sendable {
    public var id: Int
    public var bounds: Rect
    public var scaleFactor: Double
    public init(id: Int, bounds: Rect, scaleFactor: Double) {
        self.id = id
        self.bounds = bounds
        self.scaleFactor = scaleFactor
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle, other
}

public struct StepClick: Codable, Equatable, Sendable {
    /// Click position in global (virtual-desktop) coordinates.
    public var global: Point
    /// Click position relative to the captured screenshot (in stored-PNG pixels).
    public var image: Point
    public var button: MouseButton
    /// Click-marker ring radius (image px). Omitted = derive from image size.
    public var radius: Double?
    /// Downscale factor applied to the stored screenshot at capture time (T2);
    /// `image` is in the DOWNSCALED pixel space. Absent = 1.
    public var imageScale: Double?

    enum CodingKeys: String, CodingKey { case global, image, button, radius, imageScale }

    public init(global: Point, image: Point, button: MouseButton, radius: Double? = nil, imageScale: Double? = nil) {
        self.global = global
        self.image = image
        self.button = button
        self.radius = radius
        self.imageScale = imageScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        global = try c.decode(Point.self, forKey: .global)
        image = try c.decode(Point.self, forKey: .image)
        button = (try? c.decode(MouseButton.self, forKey: .button)) ?? .other
        radius = try? c.decodeIfPresent(Double.self, forKey: .radius)
        imageScale = try? c.decodeIfPresent(Double.self, forKey: .imageScale)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(global, forKey: .global)
        try c.encode(image, forKey: .image)
        try c.encode(button, forKey: .button)
        try c.encodeIfPresent(radius, forKey: .radius)
        try c.encodeIfPresent(imageScale, forKey: .imageScale)
    }
}

/// UI element at the click point. `available: false` is the soft-fail shape used
/// when element resolution is off/denied — every step carries one.
public struct StepElement: Codable, Equatable, Sendable {
    public var available: Bool
    public var name: String?
    public var controlType: String?
    public var bounds: Rect?

    enum CodingKeys: String, CodingKey { case available, name, controlType, bounds }

    public static let unavailable = StepElement(available: false, name: nil, controlType: nil, bounds: nil)

    public init(available: Bool, name: String?, controlType: String?, bounds: Rect?) {
        self.available = available
        self.name = name
        self.controlType = controlType
        self.bounds = bounds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        controlType = try? c.decodeIfPresent(String.self, forKey: .controlType)
        bounds = try? c.decodeIfPresent(Rect.self, forKey: .bounds)
    }

    public func encode(to encoder: Encoder) throws {
        // TS always writes all four keys, null where unset.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(available, forKey: .available)
        try c.encode(name, forKey: .name)
        try c.encode(controlType, forKey: .controlType)
        try c.encode(bounds, forKey: .bounds)
    }
}

// MARK: - Step kind / callouts

/// 'shot' (default when absent) or an authored 'text' block between shots.
public enum StepKind: String, Codable, Sendable {
    case shot, text
}

/// Pre-formatted callout style for a text step. Absent = plain text step.
public enum CalloutKind: String, Codable, Sendable, CaseIterable {
    case note, caution, warning
}

// MARK: - SOP intro / backup

/// Leading overview rendered as a PREAMBLE above the steps (not a numbered step).
public struct SopIntro: Codable, Equatable, Sendable {
    public var heading: String
    public var body: String

    enum CodingKeys: String, CodingKey { case heading, body }

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }

    /// Mirrors `coerceIntro`: non-string fields become ''; both-empty is treated
    /// as nil by the manifest decoder below.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heading = (try? c.decodeIfPresent(String.self, forKey: .heading)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
    }

    public var isEmpty: Bool { heading.isEmpty && body.isEmpty }
}

public enum SopTone: String, Codable, Sendable {
    case professional, friendly, concise, detailed
}

/// Pre-generation snapshot for one-click revert of Claude's inline SOP edits.
public struct SopBackup: Codable, Equatable, Sendable {
    public var steps: [ProjectStep]
    public var title: String
    public var intro: SopIntro?
    public var model: String
    public var tone: SopTone
    public var at: String // ISO 8601

    enum CodingKeys: String, CodingKey { case steps, title, intro, model, tone, at }

    public init(steps: [ProjectStep], title: String, intro: SopIntro?, model: String, tone: SopTone, at: String) {
        self.steps = steps
        self.title = title
        self.intro = intro
        self.model = model
        self.tone = tone
        self.at = at
    }

    /// Mirrors `coerceSopBackup`: steps must be an array and title a string or
    /// the whole backup is dropped (the manifest decoder catches the throw).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decode([ProjectStep].self, forKey: .steps)
        title = try c.decode(String.self, forKey: .title)
        let rawIntro = try? c.decodeIfPresent(SopIntro.self, forKey: .intro)
        intro = (rawIntro?.isEmpty ?? true) ? nil : rawIntro
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        tone = (try? c.decodeIfPresent(SopTone.self, forKey: .tone)) ?? .professional
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(steps, forKey: .steps)
        try c.encode(title, forKey: .title)
        try c.encode(intro, forKey: .intro)
        try c.encode(model, forKey: .model)
        try c.encode(tone, forKey: .tone)
        try c.encode(at, forKey: .at)
    }
}

// MARK: - Step

public struct ProjectStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var order: Int
    /// 'shot' (default) or 'text'.
    public var kind: StepKind?
    /// Path to the original capture, relative to the project folder ('' for text steps).
    public var screenshot: String
    public var trigger: Trigger
    public var click: StepClick?
    public var monitor: CapturedMonitor?
    public var window: CapturedWindow?
    public var element: StepElement
    /// Auto-generated at capture time; user-editable.
    public var caption: String
    /// User free-text note.
    public var note: String
    /// Optional heading (text steps and screenshot steps both use it).
    public var heading: String?
    /// Optional body/subtext (markdown).
    public var body: String?
    /// When set, a text step renders as a colored callout box.
    public var callout: CalloutKind?
    /// True for a text step inserted by Claude's SOP generation.
    public var aiInserted: Bool?
    /// Optional crop rect, in image px.
    public var crop: Rect?
    /// Click-register marker color; defaults to the accent when unset.
    public var markerColor: String?
    /// Non-destructive vector annotations.
    public var annotations: [Annotation]
    /// Path (relative to the project folder) to the flattened render — original
    /// cropped + annotations drawn + redaction BAKED in. The report/export prefer
    /// it over the raw screenshot. nil until first edited.
    public var flattened: String?
    /// Bumped each time `flattened` is rewritten.
    public var renderRev: Int?
    /// True when any click marker is BAKED into `flattened`'s pixels (so the
    /// report must NOT draw its overlay ring on top).
    public var markerBaked: Bool?
    /// Per-step zoom in the report (default 1).
    public var reportZoom: Double?
    /// Report pan as a fraction 0..1 of the pannable range (0.5 = centered).
    public var reportPanX: Double?
    public var reportPanY: Double?
    /// Keys this schema version doesn't know — preserved for round-trip.
    public var extra: [String: JSONValue]

    public enum Trigger: String, Codable, Sendable {
        case click, hotkey
    }

    // Encode order matches the Windows capture writer (JS object insertion order)
    // with the editor-set optionals in declaration order after their neighbors.
    private static let knownKeys: [String] = [
        "id", "order", "kind", "screenshot", "trigger", "click", "monitor",
        "window", "element", "caption", "note", "heading", "body", "callout",
        "aiInserted", "crop", "markerColor", "annotations", "flattened",
        "renderRev", "markerBaked", "reportZoom", "reportPanX", "reportPanY",
    ]

    public init(
        id: String,
        order: Int,
        kind: StepKind? = nil,
        screenshot: String,
        trigger: Trigger,
        click: StepClick? = nil,
        monitor: CapturedMonitor? = nil,
        window: CapturedWindow? = nil,
        element: StepElement = .unavailable,
        caption: String = "",
        note: String = "",
        heading: String? = nil,
        body: String? = nil,
        callout: CalloutKind? = nil,
        aiInserted: Bool? = nil,
        crop: Rect? = nil,
        markerColor: String? = nil,
        annotations: [Annotation] = [],
        flattened: String? = nil,
        renderRev: Int? = nil,
        markerBaked: Bool? = nil,
        reportZoom: Double? = nil,
        reportPanX: Double? = nil,
        reportPanY: Double? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.order = order
        self.kind = kind
        self.screenshot = screenshot
        self.trigger = trigger
        self.click = click
        self.monitor = monitor
        self.window = window
        self.element = element
        self.caption = caption
        self.note = note
        self.heading = heading
        self.body = body
        self.callout = callout
        self.aiInserted = aiInserted
        self.crop = crop
        self.markerColor = markerColor
        self.annotations = annotations
        self.flattened = flattened
        self.renderRev = renderRev
        self.markerBaked = markerBaked
        self.reportZoom = reportZoom
        self.reportPanX = reportPanX
        self.reportPanY = reportPanY
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func key(_ s: String) -> DynamicKey { DynamicKey(s) }
        // Defensive throughout (mirrors normalizeSteps + the TS blind-cast read):
        // a malformed field degrades to its default instead of failing the open.
        id = (try? c.decodeIfPresent(String.self, forKey: key("id"))) ?? ""
        order = Int(((try? c.decodeIfPresent(Double.self, forKey: key("order"))) ?? 0).rounded())
        kind = try? c.decodeIfPresent(StepKind.self, forKey: key("kind"))
        screenshot = (try? c.decodeIfPresent(String.self, forKey: key("screenshot"))) ?? ""
        trigger = (try? c.decodeIfPresent(Trigger.self, forKey: key("trigger"))) ?? .hotkey
        click = try? c.decodeIfPresent(StepClick.self, forKey: key("click"))
        monitor = try? c.decodeIfPresent(CapturedMonitor.self, forKey: key("monitor"))
        window = try? c.decodeIfPresent(CapturedWindow.self, forKey: key("window"))
        element = (try? c.decodeIfPresent(StepElement.self, forKey: key("element"))) ?? .unavailable
        caption = (try? c.decodeIfPresent(String.self, forKey: key("caption"))) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: key("note"))) ?? ""
        heading = try? c.decodeIfPresent(String.self, forKey: key("heading"))
        body = try? c.decodeIfPresent(String.self, forKey: key("body"))
        callout = try? c.decodeIfPresent(CalloutKind.self, forKey: key("callout"))
        aiInserted = try? c.decodeIfPresent(Bool.self, forKey: key("aiInserted"))
        crop = try? c.decodeIfPresent(Rect.self, forKey: key("crop"))
        markerColor = try? c.decodeIfPresent(String.self, forKey: key("markerColor"))
        annotations = (try? c.decodeIfPresent([Annotation].self, forKey: key("annotations"))) ?? []
        flattened = try? c.decodeIfPresent(String.self, forKey: key("flattened"))
        renderRev = try? c.decodeIfPresent(Int.self, forKey: key("renderRev"))
        markerBaked = try? c.decodeIfPresent(Bool.self, forKey: key("markerBaked"))
        reportZoom = try? c.decodeIfPresent(Double.self, forKey: key("reportZoom"))
        reportPanX = try? c.decodeIfPresent(Double.self, forKey: key("reportPanX"))
        reportPanY = try? c.decodeIfPresent(Double.self, forKey: key("reportPanY"))
        var extras: [String: JSONValue] = [:]
        let known = Set(Self.knownKeys)
        for k in c.allKeys where !known.contains(k.stringValue) {
            extras[k.stringValue] = try? c.decode(JSONValue.self, forKey: k)
        }
        extra = extras.compactMapValues { $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        func key(_ s: String) -> DynamicKey { DynamicKey(s) }
        try c.encode(id, forKey: key("id"))
        try c.encode(order, forKey: key("order"))
        try c.encodeIfPresent(kind, forKey: key("kind"))
        try c.encode(screenshot, forKey: key("screenshot"))
        try c.encode(trigger, forKey: key("trigger"))
        // Always-present-possibly-null keys, matching the capture writer's shape.
        try c.encode(click, forKey: key("click"))
        try c.encode(monitor, forKey: key("monitor"))
        try c.encode(window, forKey: key("window"))
        try c.encode(element, forKey: key("element"))
        try c.encode(caption, forKey: key("caption"))
        try c.encode(note, forKey: key("note"))
        try c.encodeIfPresent(heading, forKey: key("heading"))
        try c.encodeIfPresent(body, forKey: key("body"))
        try c.encodeIfPresent(callout, forKey: key("callout"))
        try c.encodeIfPresent(aiInserted, forKey: key("aiInserted"))
        try c.encode(crop, forKey: key("crop"))
        try c.encodeIfPresent(markerColor, forKey: key("markerColor"))
        try c.encode(annotations, forKey: key("annotations"))
        try c.encodeIfPresent(flattened, forKey: key("flattened"))
        try c.encodeIfPresent(renderRev, forKey: key("renderRev"))
        try c.encodeIfPresent(markerBaked, forKey: key("markerBaked"))
        try c.encodeIfPresent(reportZoom, forKey: key("reportZoom"))
        try c.encodeIfPresent(reportPanX, forKey: key("reportPanX"))
        try c.encodeIfPresent(reportPanY, forKey: key("reportPanY"))
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) {
            try c.encode(v, forKey: key(k))
        }
    }
}

// MARK: - Manifest

public struct ProjectManifest: Codable, Equatable, Sendable {
    public var version: Int
    /// Stable random identity (uuid); '' for an older project not yet migrated.
    public var id: String
    public var title: String
    public var createdWith: String
    public var createdAt: String // ISO 8601
    public var updatedAt: String // ISO 8601
    public var captureSettings: CaptureTarget?
    public var steps: [ProjectStep]
    /// SOP overview rendered as a preamble above the steps (not a step).
    public var intro: SopIntro?
    /// Pre-edit snapshot enabling revert of Claude's inline SOP edits.
    public var sopBackup: SopBackup?
    /// Archived state (F2): when true, the project's bulk files (shots/, export/)
    /// are compressed into archive.zip and the loose copies removed — the project
    /// stays listed (under the Archive tab) and is auto-restored on open.
    /// `archivedAt` is the ISO time it was archived (nil when live).
    public var archived: Bool
    public var archivedAt: String?
    /// Keys this schema version doesn't know — preserved for round-trip.
    public var extra: [String: JSONValue]

    private static let knownKeys: Set<String> = [
        "version", "id", "title", "createdWith", "createdAt", "updatedAt",
        "captureSettings", "steps", "intro", "sopBackup", "archived", "archivedAt",
    ]

    public init(
        version: Int = projectSchemaVersion,
        id: String,
        title: String,
        createdAt: String,
        updatedAt: String,
        captureSettings: CaptureTarget? = nil,
        steps: [ProjectStep] = [],
        intro: SopIntro? = nil,
        sopBackup: SopBackup? = nil,
        archived: Bool = false,
        archivedAt: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.id = id
        self.title = title
        self.createdWith = "shotAI"
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.captureSettings = captureSettings
        self.steps = steps
        self.intro = intro
        self.sopBackup = sopBackup
        self.archived = archived
        self.archivedAt = archivedAt
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func key(_ s: String) -> DynamicKey { DynamicKey(s) }
        // Mirrors the Windows readManifest coercions field by field.
        version = (try? c.decodeIfPresent(Int.self, forKey: key("version"))) ?? projectSchemaVersion
        id = (try? c.decodeIfPresent(String.self, forKey: key("id"))) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: key("title"))) ?? ""
        createdWith = "shotAI" // forced, exactly as readManifest does
        createdAt = (try? c.decodeIfPresent(String.self, forKey: key("createdAt"))) ?? ""
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: key("updatedAt"))) ?? ""
        captureSettings = try? c.decodeIfPresent(CaptureTarget.self, forKey: key("captureSettings"))
        steps = (try? c.decodeIfPresent([ProjectStep].self, forKey: key("steps"))) ?? []
        let rawIntro = try? c.decodeIfPresent(SopIntro.self, forKey: key("intro"))
        intro = (rawIntro?.isEmpty ?? true) ? nil : rawIntro
        sopBackup = try? c.decodeIfPresent(SopBackup.self, forKey: key("sopBackup"))
        // Tolerant like Windows readManifest: any non-`true` (missing/null/other) → false.
        archived = ((try? c.decodeIfPresent(Bool.self, forKey: key("archived"))) ?? false) == true
        archivedAt = (try? c.decodeIfPresent(String.self, forKey: key("archivedAt"))) ?? nil
        var extras: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.knownKeys.contains(k.stringValue) {
            extras[k.stringValue] = try? c.decode(JSONValue.self, forKey: k)
        }
        extra = extras.compactMapValues { $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        func key(_ s: String) -> DynamicKey { DynamicKey(s) }
        try c.encode(version, forKey: key("version"))
        try c.encode(id, forKey: key("id"))
        try c.encode(title, forKey: key("title"))
        try c.encode(createdWith, forKey: key("createdWith"))
        try c.encode(createdAt, forKey: key("createdAt"))
        try c.encode(updatedAt, forKey: key("updatedAt"))
        try c.encode(captureSettings, forKey: key("captureSettings"))
        try c.encode(steps, forKey: key("steps"))
        try c.encode(intro, forKey: key("intro"))
        try c.encode(sopBackup, forKey: key("sopBackup"))
        try c.encode(archived, forKey: key("archived"))
        try c.encode(archivedAt, forKey: key("archivedAt"))  // explicit null when live
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) {
            try c.encode(v, forKey: key(k))
        }
    }

    /// All human-readable text in the project, concatenated for Home search:
    /// the title, the SOP intro (heading + body), and every step's caption,
    /// note, heading, and body. Excludes machine metadata (ids, paths, window /
    /// element text, coordinates) — search matches what the user wrote/reads,
    /// matching the Windows app's in-project search scope.
    public var searchableText: String {
        var parts: [String] = [title]
        if let intro {
            parts.append(intro.heading)
            parts.append(intro.body)
        }
        for step in steps {
            parts.append(step.caption)
            parts.append(step.note)
            if let h = step.heading { parts.append(h) }
            if let b = step.body { parts.append(b) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - Summary (list view; not persisted)

/// Lightweight summary for the project list. NOT Identifiable by `id` — older
/// projects may have an empty id until first opened; identify rows by `path`.
public struct ProjectSummary: Equatable, Sendable {
    public var id: String
    public var title: String
    /// Absolute path to the project folder.
    public var path: String
    public var createdAt: String
    public var updatedAt: String
    public var stepCount: Int
    /// Whether Claude has written a guide for this project — an SOP intro or any
    /// AI-inserted step. Drives the "SOP ready" / "Draft" status badge on Home.
    public var hasSop: Bool
    /// Precomputed concatenation of the project's human-readable text (title +
    /// SOP intro + every step's caption/note/heading/body) so Home search can
    /// match content *inside* projects without re-reading each manifest. Built
    /// from `ProjectManifest.searchableText` at list time (the manifest is
    /// already parsed there, so this is free).
    public var searchText: String
    /// Whether the project is archived (bulk files compressed in place). Drives
    /// the Active/Archive tab split on Home.
    public var archived: Bool

    public init(
        id: String, title: String, path: String,
        createdAt: String, updatedAt: String, stepCount: Int, hasSop: Bool = false,
        searchText: String = "", archived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stepCount = stepCount
        self.hasSop = hasSop
        self.archived = archived
        self.searchText = searchText
    }
}
