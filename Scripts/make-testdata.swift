#!/usr/bin/env swift
// Synthesize varied test projects in ~/shotAI Projects for exercising Home
// search + sort + date-grouping + SOP badges. Folders are named
// `testdata-<uuid>` so they're trivial to bulk-remove:
//     rm -rf ~/shotAI\ Projects/testdata-*
// Each project.json is schema-compatible (tolerant decoder); shot steps get a
// simple valid PNG so the project also opens cleanly.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - PNG mock (abstract, distinct accent per project; no text → no CoreText flip issues)

func cgColor(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
func mockPNG(_ url: URL, accent: UInt32) {
    let W = 1000, H = 640
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    func fill(_ r: CGRect, _ c: UInt32) { ctx.setFillColor(cgColor(c)); ctx.fill(r) }
    fill(CGRect(x: 0, y: 0, width: W, height: H), 0xF3F4F6)              // page
    fill(CGRect(x: 0, y: H - 64, width: W, height: 64), accent)          // header band
    fill(CGRect(x: 0, y: 0, width: 200, height: H - 64), 0xE5E7EB)       // sidebar
    for i in 0..<7 { fill(CGRect(x: 20, y: H - 120 - i * 56, width: 160, height: 30), 0xD1D5DB) }
    fill(CGRect(x: 236, y: H - 210, width: 720, height: 120), 0xFFFFFF)  // top card
    fill(CGRect(x: 236, y: 40, width: 350, height: 340), 0xFFFFFF)       // left card
    fill(CGRect(x: 606, y: 40, width: 350, height: 340), 0xFFFFFF)       // right card
    ctx.setStrokeColor(cgColor(accent)); ctx.setLineWidth(6)            // decorative accent ring
    ctx.strokeEllipse(in: CGRect(x: 470, y: 250, width: 60, height: 60))
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - ISO timestamps (spread across date groups)

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func stamp(_ daysAgo: Double) -> String { iso.string(from: Date().addingTimeInterval(-daysAgo * 86400)) }

// MARK: - Specs

struct S { // step
    var text = false
    var app = ""
    var win = ""
    var caption = ""
    var note = ""
    var heading: String? = nil
    var body: String? = nil
    static func shot(_ app: String, _ win: String, _ caption: String, note: String = "", body: String? = nil) -> S {
        S(text: false, app: app, win: win, caption: caption, note: note, body: body)
    }
    static func txt(_ heading: String, _ body: String) -> S {
        S(text: true, heading: heading, body: body)
    }
}
struct P { // project
    var title: String
    var daysAgo: Double
    var accent: UInt32
    var intro: (String, String)?   // SOP overview → "SOP ready" badge
    var steps: [S]
}

// Keyword placement note (for the search demo):
//  - Terms in TITLES: "Onboarding", "VPN", "Salesforce", "password", "database".
//  - Terms ONLY in step CONTENT (prove in-project search): "spooler" (P5),
//    "VLAN"/"firewall" (P11 + P2), "mileage" (P6), "pg_dump" (P12), "kanban" (P8).
let projects: [P] = [
    P(title: "Onboarding a new employee in Workday", daysAgo: 0, accent: 0x2563EB,
      intro: ("Overview", "How to provision a new hire: accounts, benefits enrollment, and building access."),
      steps: [
        .shot("chrome.exe", "Workday — People", "Open the People module", note: "Admins only."),
        .shot("chrome.exe", "Workday — Hire", "Start the Hire workflow", body: "Fill in the legal name, start date, and department."),
        .shot("chrome.exe", "Workday — Benefits", "Enroll the hire in benefits", body: "Select the medical, dental, and vision plans."),
        .txt("Building access", "File a badge request with Facilities so the new hire can enter the office on day one."),
      ]),
    P(title: "Configuring VPN access in the admin console", daysAgo: 0, accent: 0x059669,
      intro: ("Overview", "Grant a user secure remote access by issuing a certificate and opening the tunnel."),
      steps: [
        .shot("Safari", "Admin Console — Network", "Open the Network settings", body: "Navigate to Security ▸ Network ▸ Remote Access."),
        .shot("Safari", "Admin Console — Firewall", "Add a firewall rule for the tunnel", note: "Restrict to the corporate IP range.", body: "Allow UDP 1194 through the firewall for the VPN concentrator."),
        .shot("Safari", "Admin Console — Certs", "Issue the client certificate", body: "Generate a per-user certificate and email it securely."),
      ]),
    P(title: "Exporting the monthly sales report from Salesforce", daysAgo: 0, accent: 0x7C3AED,
      intro: nil,
      steps: [
        .shot("chrome.exe", "Salesforce — Reports", "Open the Reports tab", note: "Use the Sales app, not Service."),
        .shot("chrome.exe", "Salesforce — Filter", "Filter to the current month", body: "Set the close-date range to this month."),
        .shot("chrome.exe", "Salesforce — Export", "Export the report as CSV", body: "Choose Export ▸ Details Only ▸ CSV."),
      ]),
    P(title: "Resetting a user password in Active Directory", daysAgo: 1, accent: 0xDC2626,
      intro: ("Overview", "Reset and unlock a locked-out account, then force a change at next logon."),
      steps: [
        .shot("mmc.exe", "Active Directory Users and Computers", "Locate the user account", note: "Search by employee ID."),
        .shot("mmc.exe", "Active Directory — Reset", "Reset the password", body: "Set a temporary password and check 'User must change password at next logon'."),
        .shot("mmc.exe", "Active Directory — Unlock", "Unlock the account", body: "Clear the 'Account is locked out' checkbox."),
      ]),
    P(title: "Recording 2026-07-12 09-41-33", daysAgo: 1, accent: 0x0891B2,   // placeholder title (SOP title test)
      intro: nil,
      steps: [
        .shot("explorer.exe", "Control Panel — Devices", "Open Devices and Printers", note: "The print job is stuck."),
        .shot("services.msc", "Services", "Restart the Print Spooler service", body: "Right-click the spooler service and choose Restart to clear the frozen print queue."),
      ]),
    P(title: "Submitting an expense report in Concur", daysAgo: 3, accent: 0xEA580C,
      intro: nil,
      steps: [
        .shot("chrome.exe", "Concur — Expenses", "Create a new expense report", note: "One report per trip."),
        .shot("chrome.exe", "Concur — Receipts", "Upload the receipts", body: "Drag each receipt image onto the matching line item."),
        .shot("chrome.exe", "Concur — Mileage", "Add a mileage claim", body: "Enter the start and end addresses; Concur computes the mileage automatically."),
        .txt("Submit for approval", "Route the report to your manager and finance for approval."),
      ]),
    P(title: "Deploying the web app to staging", daysAgo: 4, accent: 0x4F46E5,
      intro: ("Overview", "Ship the current build to the staging environment with a safe rollback path."),
      steps: [
        .shot("iTerm", "Terminal — CI", "Trigger the build pipeline", body: "Run the deploy job on the release branch."),
        .shot("iTerm", "Terminal — Docker", "Push the Docker image", body: "Tag and push the container image to the registry."),
        .shot("Safari", "Staging — Health", "Verify the health check", note: "Roll back immediately if the health endpoint is red."),
      ]),
    P(title: "Creating a purchase order in NetSuite", daysAgo: 6, accent: 0x9333EA,
      intro: nil,
      steps: [
        .shot("chrome.exe", "NetSuite — Vendors", "Select the vendor", note: "Confirm the vendor is approved."),
        .shot("chrome.exe", "NetSuite — Lines", "Add the line items", body: "Enter each SKU, quantity, and unit price on the kanban-style entry grid."),
        .shot("chrome.exe", "NetSuite — Submit", "Submit for approval", body: "Route the PO to the budget owner."),
      ]),
    P(title: "Setting up two-factor authentication", daysAgo: 9, accent: 0x0D9488,
      intro: ("Overview", "Protect an account with an authenticator app and one-time backup codes."),
      steps: [
        .shot("Safari", "Security Settings", "Open the Security settings", note: "Do this from a trusted device."),
        .shot("Safari", "Security — 2FA", "Scan the QR code", body: "Add the account to your authenticator app by scanning the QR code."),
        .shot("Safari", "Security — Backup", "Save the backup codes", body: "Store the one-time backup codes in your password manager."),
      ]),
    P(title: "Quarterly access review", daysAgo: 12, accent: 0x65A30D,
      intro: ("Overview", "Recertify who has access to sensitive systems each quarter."),
      steps: [
        .shot("chrome.exe", "IAM — Roles", "Open the roles report", note: "Export before you start."),
        .shot("chrome.exe", "IAM — Firewall", "Review firewall and VLAN membership", body: "Confirm each engineer's firewall rules and VLAN assignments are still justified."),
        .txt("Sign-off", "Record the reviewer and date, and revoke any access that is no longer needed."),
      ]),
    P(title: "Untitled project", daysAgo: 20, accent: 0x6B7280,   // minimal placeholder
      intro: nil,
      steps: [ .shot("Finder", "Finder", "Open the shared folder") ]),
    P(title: "Backing up the database", daysAgo: 45, accent: 0xB45309,
      intro: nil,
      steps: [
        .shot("iTerm", "Terminal — Backup", "Dump the database", body: "Run pg_dump against the primary and write the archive locally."),
        .shot("iTerm", "Terminal — Upload", "Upload the dump to S3", body: "Copy the pg_dump archive to the encrypted S3 backup bucket."),
        .txt("Schedule it", "Add a nightly cron entry so the backup runs automatically."),
      ]),
]

// MARK: - Emit

let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("shotAI Projects", isDirectory: true)
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

var made = 0
for p in projects {
    let id = UUID().uuidString.lowercased()
    let dir = root.appendingPathComponent("testdata-\(id)", isDirectory: true)
    let shots = dir.appendingPathComponent("shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("export"), withIntermediateDirectories: true)

    let updated = stamp(p.daysAgo)
    let created = stamp(p.daysAgo + 0.05)

    var steps: [[String: Any]] = []
    var shotIdx = 0
    for (i, s) in p.steps.enumerated() {
        var step: [String: Any] = ["id": UUID().uuidString.lowercased(), "order": i + 1]
        if s.text {
            step["kind"] = "text"; step["screenshot"] = ""; step["trigger"] = "hotkey"
            if let h = s.heading { step["heading"] = h }
            if let b = s.body { step["body"] = b }
        } else {
            shotIdx += 1
            let rel = "shots/step-\(String(format: "%04d", shotIdx)).png"
            mockPNG(dir.appendingPathComponent(rel), accent: p.accent)
            step["screenshot"] = rel; step["trigger"] = "hotkey"
            step["caption"] = s.caption; step["note"] = s.note
            step["window"] = ["app": s.app, "title": s.win, "pid": 1000 + i,
                              "bounds": ["x": 0, "y": 0, "width": 1000, "height": 640]]
            if let b = s.body { step["body"] = b }
        }
        steps.append(step)
    }

    var manifest: [String: Any] = [
        "version": 1, "id": id, "title": p.title, "createdWith": "shotAI",
        "createdAt": created, "updatedAt": updated,
        "captureSettings": ["mode": "auto"], "steps": steps,
    ]
    if let intro = p.intro { manifest["intro"] = ["heading": intro.0, "body": intro.1] }

    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("project.json"))
    made += 1
    let badge = p.intro != nil ? "SOP ready" : "Draft"
    print("  \(badge.padding(toLength: 9, withPad: " ", startingAt: 0))  \(p.steps.count) steps  ·  \(p.title)")
}
print("\nCreated \(made) test projects in \(root.path)")
print("Remove them later with:  rm -rf ~/shotAI\\ Projects/testdata-*")
