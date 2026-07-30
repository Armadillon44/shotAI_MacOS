#!/usr/bin/env swift
// Synthesize 25 varied test projects for exercising Home (list volume, search,
// sort, date grouping, SOP badges, the Archive tab) and the report/export path
// (every step kind, callouts, sections, click markers, annotations, crops,
// unbaked redaction).
//
//     swift Scripts/make-testdata.swift                 # → ~/shotAI Projects
//     swift Scripts/make-testdata.swift "/path/to/dir"  # → an explicit folder
//
// Folders are named `testdata-<uuid>` so they never collide with real projects
// (which are named by bare uuid) and are trivial to bulk-remove:
//     rm -rf "<projects dir>"/testdata-*
// Each project.json is schema-compatible (tolerant decoder); shot steps get a
// simple valid PNG so the project also opens cleanly.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - PNG mock (abstract, distinct accent per project; no text → no CoreText flip issues)

let mockW = 1000, mockH = 640

func cgColor(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// A flat "app window" mock. Drawn in CG space (y-up); the crop helper below
/// works in image space (y-down), which is what the manifest's `crop` uses.
func mockImage(accent: UInt32) -> CGImage? {
    let W = mockW, H = mockH
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    func fill(_ r: CGRect, _ c: UInt32) { ctx.setFillColor(cgColor(c)); ctx.fill(r) }
    fill(CGRect(x: 0, y: 0, width: W, height: H), 0xF3F4F6)              // page
    fill(CGRect(x: 0, y: H - 64, width: W, height: 64), accent)          // header band
    fill(CGRect(x: 0, y: 0, width: 200, height: H - 64), 0xE5E7EB)       // sidebar
    for i in 0..<7 { fill(CGRect(x: 20, y: H - 120 - i * 56, width: 160, height: 30), 0xD1D5DB) }
    fill(CGRect(x: 236, y: H - 210, width: 720, height: 120), 0xFFFFFF)  // top card
    fill(CGRect(x: 236, y: 40, width: 350, height: 340), 0xFFFFFF)       // left card
    fill(CGRect(x: 606, y: 40, width: 350, height: 340), 0xFFFFFF)       // right card
    ctx.setStrokeColor(cgColor(accent)); ctx.setLineWidth(6)             // decorative accent ring
    ctx.strokeEllipse(in: CGRect(x: 470, y: 250, width: 60, height: 60))
    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - ISO timestamps (spread across date groups)

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func stamp(_ daysAgo: Double) -> String { iso.string(from: Date().addingTimeInterval(-daysAgo * 86400)) }

// MARK: - Specs

struct S { // step
    enum Kind { case shot, text }
    var kind: Kind = .shot
    var app = ""
    var win = ""
    var caption = ""
    var note = ""
    var heading: String?
    var body: String?
    /// note | caution | warning | section — makes a text step a non-counted callout.
    var callout: String?
    /// Click point in image px; emits a `click` so the report draws its marker ring.
    var click: CGPoint?
    /// Crop rect in image px.
    var crop: CGRect?
    /// When a crop is set: also write the baked `export/.render/<id>.png`. False
    /// leaves it UNBAKED so the fail-closed gate / export auto-bake gets exercised.
    var bakeCrop = true
    /// Redaction region in image px (deliberately left unbaked).
    var blur: CGRect?
    var element: (name: String, type: String)?
    /// Rect + arrow overlay, in image px.
    var marks = false

    static func shot(_ app: String, _ win: String, _ caption: String,
                     note: String = "", heading: String? = nil, body: String? = nil,
                     click: CGPoint? = nil, crop: CGRect? = nil, bakeCrop: Bool = true,
                     blur: CGRect? = nil, element: (name: String, type: String)? = nil,
                     marks: Bool = false) -> S {
        S(kind: .shot, app: app, win: win, caption: caption, note: note, heading: heading,
          body: body, click: click, crop: crop, bakeCrop: bakeCrop, blur: blur,
          element: element, marks: marks)
    }
    /// A plain (numbered) text step.
    static func txt(_ heading: String, _ body: String) -> S {
        S(kind: .text, heading: heading, body: body)
    }
    /// A non-counted callout / section divider.
    static func box(_ kind: String, _ heading: String, _ body: String) -> S {
        S(kind: .text, heading: heading, body: body, callout: kind)
    }
}

struct P { // project
    var title: String
    var daysAgo: Double
    var accent: UInt32
    var intro: (String, String)?   // SOP overview → "SOP ready" badge
    var steps: [S]
    var archived = false
}

/// The 32-step project, built programmatically with a section divider per phase.
func bigProject() -> [S] {
    let phases = [
        ("Phase 1 — Close the subledgers", "Lock AP, AR, and inventory so no new postings land mid-close."),
        ("Phase 2 — Reconcile", "Tie each control account back to its subledger detail."),
        ("Phase 3 — Accruals and adjustments", "Post the recurring accruals, then the manual adjustments."),
        ("Phase 4 — Report and sign off", "Publish the financial statements and collect the controller's approval."),
    ]
    var out: [S] = []
    var n = 0
    for (heading, body) in phases {
        out.append(.box("section", heading, body))
        for i in 1...8 {
            n += 1
            out.append(.shot(
                "Dynamics365", "Dynamics 365 Finance — General ledger",
                "Run close task \(n)",
                body: "Open the task and mark it complete once the balance agrees.",
                click: CGPoint(x: 300 + Double((i % 4) * 160), y: 200 + Double((i % 3) * 90)),
                element: ("Post", "Button")))
        }
    }
    return out
}

// Keyword placement (for the search demo):
//  - In TITLES only: "Workday", "VPN", "Salesforce", "password", "database", "Okta".
//  - In step CONTENT only (proves in-project search): "spooler", "VLAN",
//    "firewall", "mileage", "pg_dump", "kanban", "SCIM", "thermal".
let projects: [P] = [

    // ── Today ────────────────────────────────────────────────────────────────
    P(title: "Onboarding a new employee in Workday", daysAgo: 0, accent: 0x2563EB,
      intro: ("Overview", "How to provision a new hire: accounts, benefits enrollment, and building access."),
      steps: [
        .shot("Google Chrome", "Workday — People", "Open the People module", note: "Admins only.",
              click: CGPoint(x: 120, y: 180), element: ("People", "MenuItem")),
        .shot("Google Chrome", "Workday — Hire", "Start the Hire workflow",
              body: "Fill in the legal name, start date, and department.",
              click: CGPoint(x: 640, y: 300), element: ("Hire Employee", "Button")),
        .shot("Google Chrome", "Workday — Benefits", "Enroll the hire in benefits",
              body: "Select the medical, dental, and vision plans."),
        .txt("Building access", "File a badge request with Facilities so the new hire can enter the office on day one."),
      ]),

    P(title: "Configuring VPN access in the admin console", daysAgo: 0, accent: 0x059669,
      intro: ("Overview", "Grant a user secure remote access by issuing a certificate and opening the tunnel."),
      steps: [
        .shot("Safari", "Admin Console — Network", "Open the Network settings",
              body: "Navigate to Security ▸ Network ▸ Remote Access.", click: CGPoint(x: 100, y: 240)),
        .shot("Safari", "Admin Console — Firewall", "Add a firewall rule for the tunnel",
              note: "Restrict to the corporate IP range.",
              body: "Allow UDP 1194 through the firewall for the VPN concentrator."),
        .shot("Safari", "Admin Console — Certs", "Issue the client certificate",
              body: "Generate a per-user certificate and email it securely."),
      ]),

    P(title: "Exporting the monthly sales report from Salesforce", daysAgo: 0, accent: 0x7C3AED,
      intro: nil,
      steps: [
        .shot("Google Chrome", "Salesforce — Reports", "Open the Reports tab", note: "Use the Sales app, not Service."),
        .shot("Google Chrome", "Salesforce — Filter", "Filter to the current month",
              body: "Set the close-date range to this month."),
        .shot("Google Chrome", "Salesforce — Export", "Export the report as CSV",
              body: "Choose Export ▸ Details Only ▸ CSV."),
      ]),

    // Every block kind in one project — the render-parity reference.
    P(title: "Callout and section showcase", daysAgo: 0, accent: 0xDB2777,
      intro: ("Overview", "One of every block the report can render, for eyeballing app-vs-export parity."),
      steps: [
        .box("section", "Section divider", "A non-counted phase heading — it should not take a step number."),
        .shot("Finder", "Finder — Documents", "A plain screenshot step",
              body: "Ordinary numbered step with a caption and a body.",
              click: CGPoint(x: 500, y: 320)),
        .box("note", "Note callout", "Informational. Blue box, no step number."),
        .box("caution", "Caution callout", "Amber box. Warn about something recoverable."),
        .box("warning", "Warning callout", "Red box. Destructive or irreversible."),
        .txt("Plain text step", "A numbered text-only step — this one *does* take a number."),
        .box("section", "Second section", "Proves two dividers render consistently."),
        .shot("Finder", "Finder — Downloads", "Final screenshot step",
              body: "The numbering should read 1, 2, 3 across the shots and the plain text step only."),
      ]),

    P(title: "Empty project", daysAgo: 0, accent: 0x6B7280, intro: nil, steps: []),

    // ── Yesterday ────────────────────────────────────────────────────────────
    P(title: "Resetting a user password in Active Directory", daysAgo: 1, accent: 0xDC2626,
      intro: ("Overview", "Reset and unlock a locked-out account, then force a change at next logon."),
      steps: [
        .shot("Microsoft Remote Desktop", "Active Directory Users and Computers", "Locate the user account",
              note: "Search by employee ID.", click: CGPoint(x: 260, y: 210)),
        .shot("Microsoft Remote Desktop", "Active Directory — Reset", "Reset the password",
              body: "Set a temporary password and check 'User must change password at next logon'."),
        .shot("Microsoft Remote Desktop", "Active Directory — Unlock", "Unlock the account",
              body: "Clear the 'Account is locked out' checkbox."),
      ]),

    P(title: "Recording 2026-07-29 09-41-33", daysAgo: 1, accent: 0x0891B2,   // placeholder title
      intro: nil,
      steps: [
        .shot("System Settings", "Printers & Scanners", "Open Printers & Scanners", note: "The print job is stuck."),
        .shot("Terminal", "Terminal — cupsd", "Restart the print spooler",
              body: "Restart the spooler service to clear the frozen print queue."),
      ]),

    // Volume: 32 steps + 4 section dividers. Report scroll, export size, PDF paging.
    P(title: "Month-end close in Dynamics 365 Finance", daysAgo: 1, accent: 0x1D4ED8,
      intro: ("Overview", "The full month-end close checklist, from subledger lockout through controller sign-off."),
      steps: bigProject()),

    // ── This week ────────────────────────────────────────────────────────────
    P(title: "Submitting an expense report in Concur", daysAgo: 3, accent: 0xEA580C,
      intro: nil,
      steps: [
        .shot("Google Chrome", "Concur — Expenses", "Create a new expense report", note: "One report per trip."),
        .shot("Google Chrome", "Concur — Receipts", "Upload the receipts",
              body: "Drag each receipt image onto the matching line item."),
        .shot("Google Chrome", "Concur — Mileage", "Add a mileage claim",
              body: "Enter the start and end addresses; Concur computes the mileage automatically."),
        .txt("Submit for approval", "Route the report to your manager and finance for approval."),
      ]),

    P(title: "Deploying the web app to staging", daysAgo: 4, accent: 0x4F46E5,
      intro: ("Overview", "Ship the current build to the staging environment with a safe rollback path."),
      steps: [
        .shot("iTerm2", "Terminal — CI", "Trigger the build pipeline", body: "Run the deploy job on the release branch."),
        .shot("iTerm2", "Terminal — Docker", "Push the Docker image", body: "Tag and push the container image to the registry."),
        .shot("Safari", "Staging — Health", "Verify the health check",
              note: "Roll back immediately if the health endpoint is red."),
      ]),

    // Non-ASCII title + body: font fallback, list truncation, export escaping.
    P(title: "Réinitialiser l'imprimante d'étiquettes — étape par étape 🖨️", daysAgo: 5, accent: 0x0D9488,
      intro: nil,
      steps: [
        .shot("System Settings", "Imprimantes et scanners", "Ouvrir les réglages d'impression",
              body: "Sélectionnez l'imprimante thermal dans la liste."),
        .shot("System Settings", "Imprimantes — File d'attente", "Vider la file d'attente",
              body: "Supprimez les travaux bloqués, puis relancez le service."),
        .box("caution", "Attention", "N'éteignez pas l'imprimante pendant le calibrage — cela corrompt le firmware."),
      ]),

    P(title: "Creating a purchase order in NetSuite", daysAgo: 6, accent: 0x9333EA,
      intro: nil,
      steps: [
        .shot("Google Chrome", "NetSuite — Vendors", "Select the vendor", note: "Confirm the vendor is approved."),
        .shot("Google Chrome", "NetSuite — Lines", "Add the line items",
              body: "Enter each SKU, quantity, and unit price on the kanban-style entry grid."),
        .shot("Google Chrome", "NetSuite — Submit", "Submit for approval", body: "Route the PO to the budget owner."),
      ]),

    // ── This month ───────────────────────────────────────────────────────────
    // HTML-hostile characters everywhere: title, caption, body. Check every export.
    P(title: "Fix the <script> & \"quoted\" field in the ticket form", daysAgo: 7, accent: 0xB91C1C,
      intro: nil,
      steps: [
        .shot("Safari", "Ticket form — <input> & \"escaping\"", "Reproduce the <script> injection",
              body: "Paste `<b>bold</b> & \"quotes\"` into the subject field and save — it must render as literal text."),
        .txt("Expected result", "The angle brackets & ampersands appear verbatim; nothing is interpreted as markup."),
      ]),

    P(title: "Configuring SSO with Okta", daysAgo: 8, accent: 0x0369A1,
      intro: ("Overview", "Federate the app with Okta using SAML, then turn on SCIM provisioning."),
      steps: [
        .shot("Google Chrome", "Okta — Applications", "Create the SAML app integration",
              heading: "Create the integration",
              body: "In the Okta admin console choose **Applications ▸ Create App Integration ▸ SAML 2.0**."),
        .shot("Google Chrome", "Okta — SAML settings", "Fill in the SAML settings",
              body: """
                    Set the following:
                    - **Single sign-on URL** — the app's ACS endpoint
                    - **Audience URI** — the entity ID from the app's admin page
                    - **Name ID format** — `EmailAddress`
                    """),
        .box("caution", "Certificate rotation", "Okta's signing certificate expires. Diary the renewal date now — an expired cert locks every user out at once."),
        .shot("Google Chrome", "Okta — Provisioning", "Enable SCIM provisioning",
              body: "Turn on SCIM so deactivating a user in Okta also deactivates them downstream."),
        .txt("Test before rollout", "Assign the app to a single pilot user and confirm both login and deprovisioning before assigning it to everyone."),
      ]),

    // Baked crops + click markers + rect/arrow overlays.
    P(title: "Adjusting the label printer alignment", daysAgo: 11, accent: 0xC2410C,
      intro: nil,
      steps: [
        .shot("Zebra Setup Utilities", "Zebra — Calibration", "Open the calibration panel",
              click: CGPoint(x: 430, y: 260), crop: CGRect(x: 180, y: 60, width: 700, height: 440),
              element: ("Calibrate", "Button"), marks: true),
        .shot("Zebra Setup Utilities", "Zebra — Offsets", "Nudge the top-of-form offset",
              body: "Two dots per nudge. Re-print the test label after each change.",
              click: CGPoint(x: 700, y: 380), crop: CGRect(x: 220, y: 100, width: 620, height: 400)),
        .shot("Zebra Setup Utilities", "Zebra — Test print", "Print the alignment test label", marks: true),
      ]),

    P(title: "Quarterly access review", daysAgo: 12, accent: 0x65A30D,
      intro: ("Overview", "Recertify who has access to sensitive systems each quarter."),
      steps: [
        .shot("Google Chrome", "IAM — Roles", "Open the roles report", note: "Export before you start."),
        .shot("Google Chrome", "IAM — Firewall", "Review firewall and VLAN membership",
              body: "Confirm each engineer's firewall rules and VLAN assignments are still justified."),
        .txt("Sign-off", "Record the reviewer and date, and revoke any access that is no longer needed."),
      ]),

    // Unbaked blur + unbaked crop: the report shows them un-applied, and export
    // must bake them (ensureFlattened) before writing anything.
    P(title: "Redaction bake-on-export check (blur + crop, unbaked)", daysAgo: 14, accent: 0x7E22CE,
      intro: nil,
      steps: [
        .shot("Safari", "Billing — Account", "Redact the account number",
              body: "The white top card carries a pixelate region that has NOT been baked yet.",
              blur: CGRect(x: 236, y: 110, width: 720, height: 120)),
        .shot("Safari", "Billing — Detail", "Crop away the sidebar",
              body: "This crop is unbaked too — the report still shows the full frame.",
              crop: CGRect(x: 200, y: 0, width: 800, height: 576), bakeCrop: false),
        .txt("What to check", "Export to HTML: the blurred region must be obscured and the crop applied in the output file."),
      ]),

    P(title: "Provisioning a shared departmental mailbox, delegating full-access and send-as permissions, and verifying the change replicated to every region", daysAgo: 17, accent: 0x475569,
      intro: nil,
      steps: [
        .shot("Google Chrome", "Exchange admin center", "Create the shared mailbox"),
        .shot("Google Chrome", "Exchange — Delegation", "Grant Full Access and Send As",
              body: "Replication can take up to an hour; re-check before telling the requester it's done."),
      ]),

    P(title: "Untitled project", daysAgo: 20, accent: 0x6B7280,
      intro: nil,
      steps: [.shot("Finder", "Finder", "Open the shared folder")]),

    // ── Older ────────────────────────────────────────────────────────────────
    // Deliberate duplicate title (see the 0-day Workday project): list dedupe,
    // export filename collision, search hit-count.
    P(title: "Onboarding a new employee in Workday", daysAgo: 30, accent: 0x2563EB,
      intro: nil,
      steps: [
        .shot("Google Chrome", "Workday — People", "Old version of the onboarding walkthrough"),
        .txt("Superseded", "Kept for reference — the current process lives in the newer project of the same name."),
      ]),

    P(title: "Backing up the database", daysAgo: 45, accent: 0xB45309,
      intro: nil,
      steps: [
        .shot("iTerm2", "Terminal — Backup", "Dump the database",
              body: "Run pg_dump against the primary and write the archive locally."),
        .shot("iTerm2", "Terminal — Upload", "Upload the dump to S3",
              body: "Copy the pg_dump archive to the encrypted S3 backup bucket."),
        .txt("Schedule it", "Add a nightly cron entry so the backup runs automatically."),
      ]),

    P(title: "PO", daysAgo: 60, accent: 0x334155,   // 2-character title: row/grid layout
      intro: nil,
      steps: [.shot("Google Chrome", "NetSuite", "Raise a one-off purchase order")]),

    // 85 days: just inside the 90-day auto-archive default, so it stays Active.
    P(title: "Annual fire drill procedure", daysAgo: 85, accent: 0xE11D48,
      intro: ("Overview", "The evacuation drill run each year: roles, routes, and the all-clear."),
      steps: [
        .shot("Preview", "Floor plan — Level 2", "Post the evacuation routes"),
        .shot("Google Chrome", "Drill log", "Record the muster times"),
        .box("warning", "Do not re-enter", "Nobody re-enters the building until the fire marshal gives the all-clear."),
      ]),

    // 120 days, NOT pre-archived: the launch auto-archive sweep (90-day default)
    // should pull this one into the Archive tab by itself.
    P(title: "Legacy printer setup (2024 process)", daysAgo: 120, accent: 0x78716C,
      intro: nil,
      steps: [
        .shot("System Settings", "Printers — Legacy", "Add the printer by IP"),
        .shot("System Settings", "Printers — Driver", "Install the vendor driver"),
      ]),

    // Pre-archived: populates the Archive tab immediately, without waiting for
    // the sweep. Flag-only (no archive.zip), so Restore just clears the flag.
    P(title: "Decommissioned VPN appliance runbook", daysAgo: 200, accent: 0x57534E,
      intro: nil,
      steps: [
        .shot("Safari", "Appliance — Console", "Drain the active tunnels"),
        .shot("Safari", "Appliance — Power", "Power down and unrack"),
      ],
      archived: true),
]

// MARK: - Emit

let fm = FileManager.default
let arg = CommandLine.arguments.dropFirst().first
let root = URL(fileURLWithPath: arg.map { ($0 as NSString).expandingTildeInPath }
    ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("shotAI Projects").path,
    isDirectory: true)

var isDir: ObjCBool = false
if !fm.fileExists(atPath: root.path, isDirectory: &isDir) {
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
} else if !isDir.boolValue {
    FileHandle.standardError.write("not a directory: \(root.path)\n".data(using: .utf8)!)
    exit(1)
}

func rectJSON(_ r: CGRect) -> [String: Any] {
    ["x": Double(r.origin.x), "y": Double(r.origin.y),
     "width": Double(r.size.width), "height": Double(r.size.height)]
}

var made = 0, shotTotal = 0
print("Writing to \(root.path)\n")

for p in projects {
    let id = UUID().uuidString.lowercased()
    let dir = root.appendingPathComponent("testdata-\(id)", isDirectory: true)
    try fm.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent("export"), withIntermediateDirectories: true)

    let updated = stamp(p.daysAgo)
    let created = stamp(p.daysAgo + 0.05)
    let base = mockImage(accent: p.accent)

    var steps: [[String: Any]] = []
    var shotIdx = 0
    for (i, s) in p.steps.enumerated() {
        let stepId = UUID().uuidString.lowercased()
        var step: [String: Any] = ["id": stepId, "order": i + 1]

        if s.kind == .text {
            step["kind"] = "text"
            step["screenshot"] = ""
            step["trigger"] = "hotkey"
            if let h = s.heading { step["heading"] = h }
            if let b = s.body { step["body"] = b }
            if let c = s.callout { step["callout"] = c }
            steps.append(step)
            continue
        }

        shotIdx += 1
        shotTotal += 1
        let rel = "shots/step-\(String(format: "%04d", shotIdx)).png"
        if let base { writePNG(base, to: dir.appendingPathComponent(rel)) }

        step["screenshot"] = rel
        step["trigger"] = s.click != nil ? "click" : "hotkey"
        step["caption"] = s.caption
        step["note"] = s.note
        step["window"] = ["app": s.app, "title": s.win, "pid": 1000 + i,
                          "bounds": ["x": 0, "y": 0, "width": mockW, "height": mockH]]
        step["monitor"] = ["id": 1, "scaleFactor": 1,
                           "bounds": ["x": 0, "y": 0, "width": mockW, "height": mockH]]
        step["element"] = s.element.map {
            ["available": true, "name": $0.name, "controlType": $0.type, "bounds": NSNull()]
        } ?? ["available": false, "name": NSNull(), "controlType": NSNull(), "bounds": NSNull()]
        if let h = s.heading { step["heading"] = h }
        if let b = s.body { step["body"] = b }

        if let c = s.click {
            step["click"] = ["global": ["x": Double(c.x), "y": Double(c.y)],
                             "image": ["x": Double(c.x), "y": Double(c.y)],
                             "button": "left", "radius": 26]
        }

        var annotations: [[String: Any]] = []
        if s.marks {
            annotations.append(["type": "rect", "id": UUID().uuidString.lowercased(),
                                "x": 250, "y": 120, "width": 300, "height": 110,
                                "cornerRadius": 6, "stroke": "#EF4444", "strokeWidth": 4,
                                "fill": NSNull()])
            annotations.append(["type": "arrow", "id": UUID().uuidString.lowercased(),
                                "points": [640, 420, 470, 260], "stroke": "#EF4444", "strokeWidth": 5])
        }
        if let b = s.blur {
            var blur = rectJSON(b)
            blur["type"] = "blur"
            blur["id"] = UUID().uuidString.lowercased()
            blur["mode"] = "pixelate"
            blur["blockSize"] = 12
            annotations.append(blur)
        }
        if !annotations.isEmpty { step["annotations"] = annotations }

        if let c = s.crop {
            step["crop"] = rectJSON(c)
            // A crop is only honored once it's baked; bake it here unless the spec
            // deliberately leaves it unbaked to exercise the gate / export re-bake.
            if s.bakeCrop, let base, let cut = base.cropping(to: c.integral) {
                let renderRel = "export/.render/\(stepId).png"
                writePNG(cut, to: dir.appendingPathComponent(renderRel))
                step["flattened"] = renderRel
                step["renderRev"] = 1
            }
        }
        steps.append(step)
    }

    var manifest: [String: Any] = [
        "version": 1, "id": id, "title": p.title, "createdWith": "shotAI",
        "createdAt": created, "updatedAt": updated,
        "captureSettings": ["mode": "auto"], "steps": steps,
        "archived": p.archived,
        "archivedAt": p.archived ? stamp(p.daysAgo - 1) : NSNull(),
    ]
    if let intro = p.intro { manifest["intro"] = ["heading": intro.0, "body": intro.1] }

    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("project.json"))
    made += 1

    let badge = p.archived ? "Archived" : (p.intro != nil ? "SOP ready" : "Draft")
    let age = p.daysAgo == 0 ? "today" : "\(Int(p.daysAgo))d ago"
    print("  \(badge.padding(toLength: 9, withPad: " ", startingAt: 0))"
        + "\(String(p.steps.count).padding(toLength: 3, withPad: " ", startingAt: 0)) steps"
        + "  \(age.padding(toLength: 8, withPad: " ", startingAt: 0))  \(p.title)")
}

print("\nCreated \(made) test projects (\(shotTotal) screenshots) in \(root.path)")
print("Remove them later with:  rm -rf \"\(root.path)\"/testdata-*")
