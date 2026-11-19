import Foundation
import Testing
@testable import ShotModel

/// The per-project screenshot frame, against the shared table in
/// `contract/frame-geometry.json`. Its expected values come from an independent
/// implementation of the spec (Armadillon44/shotAI#160), and the Windows port
/// tests against the same file, so neither app can drift from the other.
@Suite struct FrameGeometryContract {

    struct Table: Decodable {
        struct Parse: Decodable { let raw: String; let frame: String? }
        struct Box: Decodable { let budget: [Double]; let frame: String; let box: [Double] }
        struct ProjectBox: Decodable { let docScale: Double?; let frame: String; let box: [Double] }
        struct Zoom: Decodable { let fillZoom: Double; let start: Double; let zoomIn: Double; let zoomOut: Double }
        struct View: Decodable {
            struct Input: Decodable {
                let image: [Int]; let frame: String; let box: [Double]; let zoom: Double
                let pan: [Double]?; let click: [Double]?
            }
            struct Export: Decodable { let canvas: [Int]; let crop: [Int]; let origin: [Int] }
            struct Expect: Decodable {
                let fillZoom: Double; let zoom: Double; let scale: Double; let pan: [Double]
                let visible: [Double]; let display: [Double]; let offset: [Double]; let export: Export
            }
            let name: String; let why: String; let input: Input; let expect: Expect
        }
        let parse: [Parse]; let box: [Box]; let projectBox: [ProjectBox]; let zoomSteps: [Zoom]; let views: [View]
    }

    /// Found from this file, not the working directory, like the conformance
    /// suite: a table that silently fails to load must fail the run.
    static let table: Table = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contract/frame-geometry.json")
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Table.self, from: data)
    }()

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 * max(1, abs(b)) }
    private func near(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy(near) }

    @Test func theTableIsNotEmpty() {
        #expect(Self.table.parse.count >= 10)
        #expect(Self.table.views.count >= 10)
    }

    @Test(arguments: table.parse.map(\.raw))
    func parsing(_ raw: String) throws {
        let c = try #require(Self.table.parse.first { $0.raw == raw })
        #expect(ShotFrame(rawValue: raw)?.rawValue == c.frame, "\"\(raw)\"")
    }

    @Test func boxes() throws {
        for c in Self.table.box {
            let frame = try #require(ShotFrame(rawValue: c.frame))
            let b = try #require(FrameGeometry.box(budgetWidth: c.budget[0], budgetHeight: c.budget[1], frame: frame))
            #expect(near([b.width, b.height], c.box), "\(c.frame) in \(c.budget)")
        }
    }

    /// The box every step is framed in, from the frame and the document scale
    /// only: never the window.
    @Test func projectBoxes() throws {
        #expect(Self.table.projectBox.count >= 12)
        for c in Self.table.projectBox {
            let frame = try #require(ShotFrame(rawValue: c.frame))
            let b = try #require(FrameGeometry.projectBox(frame: frame, docScale: c.docScale))
            #expect(near([b.width, b.height], c.box), "\(c.frame) at \(String(describing: c.docScale))")
        }
    }

    @Test func zoomSteps() {
        for c in Self.table.zoomSteps {
            #expect(near(FrameGeometry.zoomIn(from: c.start, fillZoom: c.fillZoom), c.zoomIn),
                    "in from \(c.start) with fill \(c.fillZoom)")
            #expect(near(FrameGeometry.zoomOut(from: c.start, fillZoom: c.fillZoom), c.zoomOut),
                    "out from \(c.start) with fill \(c.fillZoom)")
        }
    }

    @Test(arguments: table.views.map(\.name))
    func views(_ name: String) throws {
        let c = try #require(Self.table.views.first { $0.name == name })
        let i = c.input, e = c.expect
        let w = Double(i.image[0]), h = Double(i.image[1])
        let box = FrameGeometry.Size(width: i.box[0], height: i.box[1])

        let pan = i.pan.map { (x: $0[0], y: $0[1]) }
            ?? FrameGeometry.defaultPan(click: i.click.map { (x: $0[0], y: $0[1]) },
                                        imageWidth: w, imageHeight: h, box: box, zoom: i.zoom)
        #expect(near([pan.x, pan.y], e.pan), "pan")

        let v = try #require(FrameGeometry.view(imageWidth: w, imageHeight: h, box: box,
                                                zoom: i.zoom, panX: pan.x, panY: pan.y))
        #expect(near(v.fillZoom, e.fillZoom), "fillZoom")
        #expect(near(v.zoom, e.zoom), "zoom")
        #expect(near(v.scale, e.scale), "scale")
        #expect(near([v.visibleX, v.visibleY, v.visibleWidth, v.visibleHeight], e.visible), "visible")
        #expect(near([v.imageWidth, v.imageHeight], e.display), "display")
        #expect(near([v.offsetX, v.offsetY], e.offset), "offset")

        let x = try #require(FrameGeometry.exportLayout(imageWidth: i.image[0], imageHeight: i.image[1], box: box,
                                                        zoom: i.zoom, panX: pan.x, panY: pan.y))
        #expect([x.canvasWidth, x.canvasHeight] == e.export.canvas, "canvas")
        #expect([x.cropX, x.cropY, x.cropWidth, x.cropHeight] == e.export.crop, "crop")
        #expect([x.originX, x.originY] == e.export.origin, "origin")
    }
}

/// Rules the table states only implicitly.
@Suite struct FrameGeometryRules {
    private let box = FrameGeometry.Size(width: 600, height: 600)

    /// The report and an export frame the same part of the image: the export
    /// crop is the report's visible region, to the pixel.
    @Test func theExportShowsWhatTheReportShows() throws {
        for (zoom, pan) in [(1.0, 0.5), (1.6, 0.0), (2.0, 0.3), (2.5, 1.0), (4.0, 0.77)] {
            let v = try #require(FrameGeometry.view(imageWidth: 1600, imageHeight: 1000, box: box, zoom: zoom, panX: pan, panY: pan))
            let x = try #require(FrameGeometry.exportLayout(imageWidth: 1600, imageHeight: 1000, box: box, zoom: zoom, panX: pan, panY: pan))
            #expect(abs(Double(x.cropWidth) - v.visibleWidth) <= 0.5)
            #expect(abs(Double(x.cropHeight) - v.visibleHeight) <= 0.5)
            #expect(abs(Double(x.cropX) - v.visibleX) <= 1)
            #expect(abs(Double(x.cropY) - v.visibleY) <= 1)
            // The canvas has the frame's shape (to a pixel of rounding).
            #expect(abs(Double(x.canvasWidth) / Double(x.canvasHeight) - 1) < 0.002)
        }
    }

    /// The verification finding: a crop that starts at the top-left corner (a
    /// click-centred view clamped there) was reported as the unchanged render, so
    /// an export skipping identity layouts would have shipped the whole image.
    @Test func aCropAtTheTopLeftIsNotTheWholeImage() throws {
        for (zoom, panX, panY) in [(1.6, 0.0, 0.5), (2.5, 0.0, 0.0), (4.0, 0.0, 0.0)] {
            let x = try #require(FrameGeometry.exportLayout(imageWidth: 1600, imageHeight: 1000, box: box,
                                                            zoom: zoom, panX: panX, panY: panY))
            #expect(x.cropX == 0 && x.cropY == 0)
            #expect(!x.isIdentity, "zoom \(zoom): \(x.cropWidth)x\(x.cropHeight) of 1600x1000")
        }
    }

    /// An image of the frame's shape at fit needs no new image at all.
    @Test func aSameShapeImageAtFitIsTheRenderItself() throws {
        let x = try #require(FrameGeometry.exportLayout(imageWidth: 1200, imageHeight: 1200, box: box, zoom: 1, panX: 0.5, panY: 0.5))
        #expect(x.isIdentity)
        let wide = try #require(FrameGeometry.exportLayout(imageWidth: 1600, imageHeight: 1000, box: box, zoom: 1, panX: 0.5, panY: 0.5))
        #expect(!wide.isIdentity, "padding is a new image")
    }

    /// Zoom 1 never enlarges; only an explicit zoom-in can.
    @Test func fitNeverEnlarges() throws {
        for (w, h) in [(100.0, 80.0), (600.0, 600.0), (3000.0, 200.0), (50.0, 900.0)] {
            let v = try #require(FrameGeometry.view(imageWidth: w, imageHeight: h, box: box, zoom: 1, panX: 0.5, panY: 0.5))
            #expect(v.scale <= 1)
            #expect(v.imageWidth <= box.width + 1e-9 && v.imageHeight <= box.height + 1e-9, "the whole image fits")
        }
    }

    /// The first step in from fit fills the box: no padding on either axis.
    @Test func theFirstZoomInFills() throws {
        for (w, h) in [(1600.0, 1000.0), (800.0, 1200.0), (100.0, 80.0), (3000.0, 300.0)] {
            let fill = FrameGeometry.fillZoom(imageWidth: w, imageHeight: h, box: box)
            #expect(FrameGeometry.zoomIn(from: 1, fillZoom: fill) == (fill > 1 ? fill : 1.25))
            let v = try #require(FrameGeometry.view(imageWidth: w, imageHeight: h, box: box, zoom: fill, panX: 0.5, panY: 0.5))
            #expect(v.imageWidth >= box.width - 1e-6 && v.imageHeight >= box.height - 1e-6)
            #expect(min(v.imageWidth - box.width, v.imageHeight - box.height) < 1e-6, "and only just")
        }
    }

    @Test func panIsOnlyOfferedWhereTheImageOverflows() throws {
        let fit = try #require(FrameGeometry.view(imageWidth: 1600, imageHeight: 1000, box: box, zoom: 1, panX: 0.5, panY: 0.5))
        #expect(!fit.pannableX && !fit.pannableY)
        let fill = try #require(FrameGeometry.view(imageWidth: 1600, imageHeight: 1000, box: box, zoom: 1.6, panX: 0.5, panY: 0.5))
        #expect(fill.pannableX && !fill.pannableY)
    }

    @Test func badInputsAreRefusedOrNeutral() {
        #expect(FrameGeometry.box(budgetWidth: 0, budgetHeight: 600, frame: ShotFrame(width: 1, height: 1)!) == nil)
        #expect(FrameGeometry.box(budgetWidth: .nan, budgetHeight: 600, frame: ShotFrame(width: 1, height: 1)!) == nil)
        #expect(FrameGeometry.view(imageWidth: 0, imageHeight: 10, box: box, zoom: 1, panX: 0.5, panY: 0.5) == nil)
        #expect(FrameGeometry.exportLayout(imageWidth: 10, imageHeight: 0, box: box, zoom: 1, panX: 0.5, panY: 0.5) == nil)
        let nanPan = FrameGeometry.view(imageWidth: 1600, imageHeight: 1000, box: box, zoom: 2, panX: .nan, panY: .infinity)
        let centred = FrameGeometry.view(imageWidth: 1600, imageHeight: 1000, box: box, zoom: 2, panX: 0.5, panY: 0.5)
        #expect(nanPan?.visibleX == centred?.visibleX, "a NaN pan is centred")
        #expect(FrameGeometry.view(imageWidth: 1600, imageHeight: 1000, box: box, zoom: .nan, panX: 0.5, panY: 0.5)?.zoom == 1)
    }

    @Test func theClickIsMeasuredInTheRender() {
        var step = ProjectStep(id: "s", order: 1, kind: .shot, screenshot: "shots/1.png", trigger: .hotkey)
        #expect(step.clickInRender == nil)
        step.click = StepClick(global: Point(x: 0, y: 0), image: Point(x: 500, y: 300), button: .left)
        #expect(step.clickInRender.map { [$0.x, $0.y] } == [500, 300])
        step.crop = Rect(x: 100, y: 50, width: 800, height: 600)
        #expect(step.clickInRender.map { [$0.x, $0.y] } == [400, 250], "a render is the crop at 1:1")
    }
}

/// The `shotFrame` key and its setter.
@Suite struct ShotFrameStorage {
    private func project() async throws -> (ProjectStore, String) {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        return (store, try await store.createProject(title: "Frame").path)
    }

    private func raw(_ path: String) throws -> String {
        try String(contentsOfFile: (path as NSString).appendingPathComponent("project.json"), encoding: .utf8)
    }

    @Test func aNewProjectHasNoFrameOnDisk() async throws {
        let (store, path) = try await project()
        #expect(try await store.openProject(at: path).manifest.frame == nil)
        #expect(!(try raw(path).contains("shotFrame")))
    }

    @Test func settingAFrameWritesItOnceAndNoneRemovesIt() async throws {
        let (store, path) = try await project()
        let fiveFour = try #require(ShotFrame(rawValue: "5:4"))
        #expect(try await store.setShotFrame(at: path, fiveFour) != nil)
        let set = try await store.openProject(at: path).manifest
        #expect(set.shotFrame == "5:4")
        #expect(set.frame == fiveFour)

        #expect(try await store.setShotFrame(at: path, ShotFrame(rawValue: "10:8")) == nil,
                "the same frame, however written, writes nothing")
        #expect(try await store.openProject(at: path).manifest.updatedAt == set.updatedAt, "and does not re-date it")

        #expect(try await store.setShotFrame(at: path, nil) != nil)
        #expect(!(try raw(path).contains("shotFrame")))
        #expect(try await store.setShotFrame(at: path, nil) == nil)
    }

    /// A value this build cannot parse is not applied, survives unrelated writes,
    /// and choosing a real frame replaces it.
    @Test func anUnparseableValueIsKeptUntilReplaced() async throws {
        let (store, path) = try await project()
        let file = (path as NSString).appendingPathComponent("project.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        json["shotFrame"] = "golden"
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: file))

        _ = try await store.renameProject(at: path, title: "Renamed")
        let m = try await store.openProject(at: path).manifest
        #expect(m.shotFrame == "golden")
        #expect(m.frame == nil)
        #expect(try await store.setShotFrame(at: path, ShotFrame(rawValue: "1:1")) != nil)
        #expect(try await store.openProject(at: path).manifest.shotFrame == "1:1")
    }
}
