import Foundation
import Testing
@testable import ShotModel

// C2: render-freshness invalidation (step-render.ts) + the fail-closed egress
// gate (render-gate.ts) + updateStep/mergeSteps.
@Suite struct RenderFreshnessTests {
    let root: String
    let projectDir: String
    let store: ProjectStore

    init() throws {
        root = NSTemporaryDirectory() + "shotai-render-\(UUID().uuidString)"
        projectDir = root + "/proj"
        try FileManager.default.createDirectory(atPath: projectDir + "/shots", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projectDir + "/export", withIntermediateDirectories: true)
        var m = ProjectManifest(id: "p", title: "T", createdAt: "", updatedAt: "")
        m.steps = [ProjectStep(id: "s1", order: 1, screenshot: "shots/step-0001.png", trigger: .click)]
        try ProjectJSON.encodeManifest(m).write(to: URL(fileURLWithPath: projectDir + "/project.json"))
        store = ProjectStore(settings: InMemorySettings(projectsDir: root))
    }
    private func cleanup() { try? FileManager.default.removeItem(atPath: root) }
    private func read() throws -> ProjectStep {
        try ProjectJSON.decodeManifest(Data(contentsOf: URL(fileURLWithPath: projectDir + "/project.json"))).steps[0]
    }
    private func blur() -> Annotation {
        .blur(BlurAnnotation(id: "b", x: 0, y: 0, width: 10, height: 10, mode: .solid, blockSize: 12))
    }

    // A fresh render co-written with the patch is kept + renderRev bumped.
    @Test func freshRenderIsWrittenAndPointedAt() async throws {
        var p = StepPatch(); p.annotations = [blur()]
        _ = try await store.updateStep(at: projectDir, stepId: "s1", patch: p, flattenedPng: Data([0x89, 0x50]))
        let s = try read()
        #expect(s.flattened == "export/.render/s1.png")
        #expect(s.renderRev == 1)
        #expect(FileManager.default.fileExists(atPath: projectDir + "/export/.render/s1.png"))
        cleanup()
    }

    // Changing annotations/crop WITHOUT a fresh PNG must drop the stale render
    // (the freshness invariant) so egress is forced to re-flatten.
    @Test func changingAnnotationsWithoutRenderInvalidatesStale() async throws {
        // Seed a flattened render first.
        var p1 = StepPatch(); p1.annotations = [blur()]
        _ = try await store.updateStep(at: projectDir, stepId: "s1", patch: p1, flattenedPng: Data([0x89]))
        #expect(try read().flattened != nil)
        // Now change annotations with NO co-written PNG → stale render dropped.
        var p2 = StepPatch(); p2.annotations = [blur(), blur()]
        _ = try await store.updateStep(at: projectDir, stepId: "s1", patch: p2, flattenedPng: nil)
        let s = try read()
        #expect(s.flattened == nil, "stale render must be invalidated")
        #expect(s.markerBaked != true)
        cleanup()
    }

    // A non-geometry patch (caption) must NOT drop the render.
    @Test func captionOnlyPatchKeepsRender() async throws {
        var p1 = StepPatch(); p1.annotations = [blur()]
        _ = try await store.updateStep(at: projectDir, stepId: "s1", patch: p1, flattenedPng: Data([0x89]))
        var p2 = StepPatch(); p2.caption = "New caption"
        _ = try await store.updateStep(at: projectDir, stepId: "s1", patch: p2, flattenedPng: nil)
        let s = try read()
        #expect(s.flattened == "export/.render/s1.png")
        #expect(s.caption == "New caption")
        cleanup()
    }

    // Clearing the crop (PatchField .set(nil)) counts as a geometry change.
    @Test func clearingCropInvalidatesStale() async throws {
        var p1 = StepPatch(); p1.crop = .set(Rect(x: 0, y: 0, width: 5, height: 5))
        _ = try await store.updateStep(at: projectDir, stepId: "s1", patch: p1, flattenedPng: Data([0x89]))
        var p2 = StepPatch(); p2.crop = .set(nil)
        _ = try await store.updateStep(at: projectDir, stepId: "s1", patch: p2, flattenedPng: nil)
        #expect(try read().flattened == nil)
        cleanup()
    }

    // MARK: - render gate (fail-closed egress)

    @Test func gateRefusesRawShotForUnbakedBlur() throws {
        var step = ProjectStep(id: "s", order: 1, screenshot: "shots/s.png", trigger: .click)
        step.annotations = [blur()] // blur but no flattened
        #expect(throws: RenderGateError.self) {
            _ = try resolveSendableRender(dir: projectDir, step: step, stepLabel: "Step 1", verb: "send")
        }
        cleanup()
    }

    @Test func gateRefusesRawShotForUnbakedCrop() throws {
        var step = ProjectStep(id: "s", order: 1, screenshot: "shots/s.png", trigger: .click)
        step.crop = Rect(x: 0, y: 0, width: 5, height: 5)
        #expect(throws: RenderGateError.self) {
            _ = try resolveSendableRender(dir: projectDir, step: step, stepLabel: "Step 1", verb: "export")
        }
        cleanup()
    }

    @Test func gateAllowsFlattenedRenderAndPlainShot() throws {
        // Baked render → read the flattened.
        var baked = ProjectStep(id: "s", order: 1, screenshot: "shots/s.png", trigger: .click)
        baked.annotations = [blur()]
        baked.flattened = "export/.render/s.png"
        let r1 = try resolveSendableRender(dir: projectDir, step: baked, stepLabel: "1", verb: "send")
        #expect(r1.abs.hasSuffix("export/.render/s.png"))
        // No blur/crop → the raw shot is fine.
        let plain = ProjectStep(id: "s2", order: 2, screenshot: "shots/s2.png", trigger: .click)
        let r2 = try resolveSendableRender(dir: projectDir, step: plain, stepLabel: "2", verb: "export")
        #expect(r2.abs.hasSuffix("shots/s2.png"))
        #expect(r2.mediaType == .png)
        cleanup()
    }

    // Egress must refuse a symlinked shots/ path: a shared project could plant
    // `shots/leak.png -> ~/.ssh/id_rsa`, and Data(contentsOf:) would follow it,
    // exfiltrating the target to Claude / into an export. confinePathNoSymlinks
    // rejects the symlinked leaf, so the gate throws instead of reading it.
    @Test func gateRejectsSymlinkedRenderOrShot() throws {
        let secret = root + "/secret_id_rsa"
        try Data("PRIVATE KEY".utf8).write(to: URL(fileURLWithPath: secret))
        try FileManager.default.createSymbolicLink(
            atPath: projectDir + "/shots/leak.png", withDestinationPath: secret)

        // (a) flattened points at the symlink (the markerBaked-skip exploit shape).
        var viaFlattened = ProjectStep(id: "s", order: 1, screenshot: "shots/real.png", trigger: .click)
        viaFlattened.flattened = "shots/leak.png"
        #expect(throws: RenderGateError.self) {
            _ = try resolveSendableRender(dir: projectDir, step: viaFlattened, stepLabel: "1", verb: "send")
        }
        // (b) the screenshot itself is the symlink (no flattened, no redaction).
        let viaShot = ProjectStep(id: "s2", order: 2, screenshot: "shots/leak.png", trigger: .click)
        #expect(throws: RenderGateError.self) {
            _ = try resolveSendableRender(dir: projectDir, step: viaShot, stepLabel: "2", verb: "export")
        }
        cleanup()
    }

    // A malformed blur (e.g. "solid" omitting blockSize, or an unknown mode) must
    // still decode AS a blur so the gate recognizes the redaction and fails
    // closed — NOT demote to .unknown, which would ship the raw screenshot.
    @Test func malformedBlurStaysBlurAndGateFailsClosed() throws {
        let solidNoBlock = #"{"type":"blur","id":"b1","x":1,"y":2,"width":30,"height":10,"mode":"solid"}"#
        let ann = try JSONDecoder().decode(Annotation.self, from: Data(solidNoBlock.utf8))
        guard case .blur(let b) = ann else { Issue.record("expected .blur, got \(ann)"); return }
        #expect(b.mode == .solid)
        #expect(b.blockSize == 12)  // defaulted, not a decode failure

        var step = ProjectStep(id: "s", order: 1, screenshot: "shots/s.png", trigger: .click)
        step.annotations = [ann]
        #expect(throws: RenderGateError.self) {
            _ = try resolveSendableRender(dir: projectDir, step: step, stepLabel: "1", verb: "send")
        }
        // An unknown mode string still decodes as a blur (→ pixelate).
        let badMode = try JSONDecoder().decode(
            Annotation.self,
            from: Data(#"{"type":"blur","id":"b","x":0,"y":0,"width":5,"height":5,"mode":"???"}"#.utf8))
        guard case .blur(let b2) = badMode else { Issue.record("expected .blur"); return }
        #expect(b2.mode == .pixelate)
        cleanup()
    }

    @Test func patchClickSetsAndClears() {
        var step = ProjectStep(id: "s", order: 1, screenshot: "shots/s.png", trigger: .click)
        step.click = StepClick(global: Point(x: 10, y: 10), image: Point(x: 5, y: 5), button: .left)
        // .unset leaves the click untouched.
        applyPatchAndInvalidate(&step, StepPatch(), hasFreshPng: true)
        #expect(step.click != nil)
        // .set(newClick) updates it.
        var p1 = StepPatch()
        p1.click = .set(StepClick(global: Point(x: 1, y: 1), image: Point(x: 9, y: 9), button: .left, radius: 30))
        applyPatchAndInvalidate(&step, p1, hasFreshPng: true)
        #expect(step.click?.image == Point(x: 9, y: 9))
        #expect(step.click?.radius == 30)
        // .set(nil) removes it (the editable click marker's delete).
        var p2 = StepPatch(); p2.click = .set(nil)
        applyPatchAndInvalidate(&step, p2, hasFreshPng: true)
        #expect(step.click == nil)
        cleanup()
    }

    // MARK: - mergeSteps

    @Test func mergeStepsKeepsOneAndRenumbers() async throws {
        // Add a second step so we can merge.
        try await store.addStep(at: projectDir, ProjectStep(id: "s2", order: 2, screenshot: "shots/step-0002.png", trigger: .click))
        var p = StepPatch(); p.annotations = [.marker(MarkerAnnotation(id: "m", x: 1, y: 1, color: "#e11d48"))]
        let m = try await store.mergeSteps(at: projectDir, keepId: "s2", dropId: "s1", patch: p, flattenedPng: Data([0x89]))
        #expect(m.steps.map(\.id) == ["s2"]) // s1 dropped, kept at s1's old position
        #expect(m.steps[0].order == 1)
        #expect(m.steps[0].flattened == "export/.render/s2.png")
        cleanup()
    }

    @Test func mergeIntoSelfThrows() async throws {
        await #expect(throws: ProjectStore.StoreError.cannotMergeIntoSelf) {
            _ = try await store.mergeSteps(at: projectDir, keepId: "s1", dropId: "s1", patch: StepPatch())
        }
        cleanup()
    }
}
