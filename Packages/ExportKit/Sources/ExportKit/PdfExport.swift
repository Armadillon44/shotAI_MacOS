import AppKit
import Foundation
import WebKit

/// Render the styled HTML to a paginated PDF via an offscreen WKWebView +
/// NSPrintOperation. We use the print path (not WKWebView.createPDF) because
/// createPDF ignores @media print / page-break-inside rules — the .step
/// "break-inside:avoid" only takes effect through the print pipeline, which keeps
/// a screenshot + its caption from splitting across a page boundary.
///
/// Fail-closed: a 0-byte/missing PDF (a real failure mode on headless/software-
/// rendered setups) throws rather than silently writing garbage — HTML and
/// Markdown are the fallbacks.
@MainActor
func htmlToPdf(dir: String, html: String, outputPath: String) async throws {
    let fm = FileManager.default
    let renderDir = ((dir as NSString).appendingPathComponent("export") as NSString)
        .appendingPathComponent(".render")
    do {
        try fm.createDirectory(atPath: renderDir, withIntermediateDirectories: true)
    } catch {
        throw ExportError.writeFailed(error.localizedDescription)
    }
    // Sweep any temp HTML orphaned by a prior failed export.
    if let leftovers = try? fm.contentsOfDirectory(atPath: renderDir) {
        for f in leftovers where f.hasPrefix("_print-") && f.hasSuffix(".html") {
            try? fm.removeItem(atPath: (renderDir as NSString).appendingPathComponent(f))
        }
    }

    let tmpHtml = (renderDir as NSString).appendingPathComponent("_print-\(UUID().uuidString).html")
    do {
        try html.write(toFile: tmpHtml, atomically: true, encoding: .utf8)
    } catch {
        throw ExportError.writeFailed(error.localizedDescription)
    }
    defer { try? fm.removeItem(atPath: tmpHtml) }

    // US Letter, 0.5" margins → 540pt printable width (matches the report's 820px
    // .doc box scaled down by print).
    let paper = NSSize(width: 612, height: 792)
    let margin: CGFloat = 36
    let contentWidth = paper.width - margin * 2

    let config = WKWebViewConfiguration()
    // The print document is fully static — no scripting needed.
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(
        frame: NSRect(x: 0, y: 0, width: contentWidth, height: paper.height - margin * 2),
        configuration: config)

    // Host the web view in an offscreen window before loading: an off-window
    // WKWebView can print blank pages because it never lays out. The window is
    // never shown (positioned far off-screen) and closed in the defer.
    let host = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: contentWidth, height: paper.height - margin * 2),
        styleMask: [.borderless], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.contentView?.addSubview(webView)
    defer { host.orderOut(nil); webView.removeFromSuperview() }

    let loader = PdfLoadWaiter()
    webView.navigationDelegate = loader
    webView.loadFileURL(URL(fileURLWithPath: tmpHtml),
                        allowingReadAccessTo: URL(fileURLWithPath: renderDir))
    try await loader.wait()

    let printInfo = NSPrintInfo()
    printInfo.paperSize = paper
    printInfo.topMargin = margin
    printInfo.bottomMargin = margin
    printInfo.leftMargin = margin
    printInfo.rightMargin = margin
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .automatic
    printInfo.isHorizontallyCentered = false
    printInfo.isVerticallyCentered = false
    printInfo.jobDisposition = .save
    printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: outputPath)

    let op = webView.printOperation(with: printInfo)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    op.view?.frame = NSRect(x: 0, y: 0, width: contentWidth, height: paper.height - margin * 2)

    let ran = op.run()
    guard ran else {
        throw ExportError.writeFailed("PDF printing failed on this system. Try the HTML or Markdown export instead.")
    }

    // Fail closed: never leave a 0-byte/corrupt PDF as if it succeeded.
    let attrs = try? fm.attributesOfItem(atPath: outputPath)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else {
        try? fm.removeItem(atPath: outputPath)
        throw ExportError.writeFailed("PDF rendering produced an empty document. Try the HTML or Markdown export instead.")
    }
}

/// Bridges WKNavigationDelegate's load callbacks to async/await. Retained for the
/// duration of the load by the caller's local reference.
@MainActor
private final class PdfLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            if finished { c.resume(); return }
            continuation = c
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        let c = continuation
        continuation = nil
        switch result {
        case .success: c?.resume()
        case .failure(let e): c?.resume(throwing: e)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        complete(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(.failure(ExportError.writeFailed(error.localizedDescription)))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(.failure(ExportError.writeFailed(error.localizedDescription)))
    }
}
