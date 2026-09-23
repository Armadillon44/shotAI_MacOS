import Foundation
import XCTest
@testable import SOPKit

/// What Claude receives, as opposed to what it returns.
final class RequestOrderTests: XCTestCase {

    // MARK: The schema is sent in one deliberate order, every time

    /// Claude writes an object's properties in the order the schema declares them.
    /// The schema used to be a Swift dictionary, sent in a different order on every
    /// launch, so in some launches the model wrote a step's caption and body before
    /// its stepNumber. Pinned byte-for-byte: any change to the schema, or to its
    /// order, has to be made here on purpose.
    func testTheSchemaIsSentInExactlyThisOrder() throws {
        let sent = String(decoding: try RequestJSON.data(sopEditJSONSchema(blockCount: 3)), as: UTF8.self)
        XCTAssertEqual(sent, #"{"type":"object","additionalProperties":false,"required":["title","intro","steps"],"properties":{"title":{"type":"string"},"intro":{"anyOf":[{"type":"object","additionalProperties":false,"required":["heading","body"],"properties":{"heading":{"type":"string"},"body":{"type":"string"}}},{"type":"null"}]},"steps":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,"required":["stepNumber","kind","caption","body","sectionHeading","sectionBody"],"properties":{"stepNumber":{"type":"integer","enum":[1,2,3]},"kind":{"type":"string","enum":["screenshot","text"]},"caption":{"type":"string"},"body":{"type":"string"},"sectionHeading":{"anyOf":[{"type":"string"},{"type":"null"}]},"sectionBody":{"anyOf":[{"type":"string"},{"type":"null"}]}}}}}}"#)
    }

    /// The reason the order matters, stated as the property rather than the bytes:
    /// the model commits to WHICH screenshot before it writes the text for it.
    func testEachStepNamesItsScreenshotBeforeItsText() throws {
        let sent = String(decoding: try RequestJSON.data(sopEditJSONSchema(blockCount: 3)), as: UTF8.self)
        let number = try XCTUnwrap(sent.range(of: #""stepNumber":{"type":"integer","enum":"#))
        let kind = try XCTUnwrap(sent.range(of: #""kind":{"type":"string""#, range: number.upperBound..<sent.endIndex))
        let caption = try XCTUnwrap(sent.range(of: #""caption":{"type":"string"}"#, range: kind.upperBound..<sent.endIndex))
        XCTAssertLessThan(number.lowerBound, kind.lowerBound, "the number comes first")
        XCTAssertLessThan(kind.lowerBound, caption.lowerBound, "then what kind of block it is, then the text")
    }

    /// The pinned bytes above test the encoder. This tests that the encoder is what
    /// actually goes over the wire: it captures the body `SopService.generate` hands
    /// the transport. Reverting the client to plain JSONSerialization passed every
    /// other test here while sending three different orders from three processes.
    func testTheRequestOnTheWireCarriesTheSchemaInThatOrder() async throws {
        final class Box: @unchecked Sendable { var body: Data? }
        let box = Box()
        let (store, path, dir) = try await makeProject(shots: 1)
        let manifest = try await store.openProject(at: path).manifest
        let json = #"{"title":"T","intro":null,"steps":[{"stepNumber":1,"caption":"C","body":"B","sectionHeading":null,"sectionBody":null}]}"#
        let svc = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { req in
                box.body = req.httpBody
                return (sseLines(json: json), ResponseHead(status: 200))
            })),
            keyStore: StubKeyStore())
        _ = try await svc.generate(dir: dir, manifest: manifest, settings: SopSettings(), onProgress: { _ in })
        let sent = String(decoding: try XCTUnwrap(box.body), as: UTF8.self)
        let schema = String(decoding: try RequestJSON.data(sopEditJSONSchema(blockCount: 1)), as: UTF8.self)
        XCTAssertTrue(sent.contains(schema), "the request must carry the schema in its declared order")
    }

    /// Plain dictionaries elsewhere in the body sort, so a whole request is the same
    /// bytes in every process — not only its schema.
    func testPlainDictionariesSerializeInSortedOrder() throws {
        let body: [String: Any] = ["stream": true, "model": "m", "max_tokens": 5,
                                   "output_config": ["effort": "low", "format": ["type": "json_schema"]]]
        XCTAssertEqual(String(decoding: try RequestJSON.data(body), as: UTF8.self),
                       #"{"max_tokens":5,"model":"m","output_config":{"effort":"low","format":{"type":"json_schema"}},"stream":true}"#)
    }

    /// Booleans stay booleans, strings are escaped, null is null. JSONSerialization
    /// handles every leaf, so this only guards against wiring a leaf around it.
    func testLeavesEncodeAsJSON() throws {
        let v: [String: Any] = ["b": false, "n": NSNull(), "s": "a \"q\" \\ \n end", "i": 3]
        let out = try JSONSerialization.jsonObject(with: RequestJSON.data(v)) as? [String: Any]
        XCTAssertEqual(out?["b"] as? Bool, false)
        XCTAssertTrue(out?["n"] is NSNull)
        XCTAssertEqual(out?["s"] as? String, "a \"q\" \\ \n end")
        XCTAssertEqual(out?["i"] as? Int, 3)
    }

    // MARK: Each screenshot's label comes before its image

    /// The instructions call "--- Screenshot step N ---" a heading, and the vision
    /// docs label each image ahead of it. With the label after, a heading-first
    /// reader pairs label N with the next image — every step one late.
    func testEveryScreenshotLabelDirectlyPrecedesItsImage() async throws {
        let (store, path, dir) = try await makeProject(shots: 3)
        _ = try await store.addTextStep(at: path, atIndex: 1, heading: "Between")
        let manifest = try await store.openProject(at: path).manifest
        let content = try assembleRequest(dir: dir, manifest: manifest, settings: SopSettings())
            .messages.first?["content"] as? [[String: Any]] ?? []

        func isLabel(_ b: [String: Any]?) -> Bool {
            (b?["text"] as? String)?.hasPrefix("--- Screenshot step ") == true
        }
        var labels = 0, images = 0
        for (i, block) in content.enumerated() {
            if isLabel(block) {
                labels += 1
                XCTAssertEqual(content[safe: i + 1]?["type"] as? String, "image",
                               "a screenshot label must be followed directly by its image")
            }
            if block["type"] as? String == "image" {
                images += 1
                XCTAssertTrue(isLabel(content[safe: i - 1]),
                              "every image must be directly preceded by its own label")
            }
        }
        XCTAssertEqual(labels, 3)
        XCTAssertEqual(images, 3)
    }

    // MARK: The prompt no longer invites renumbering

    func testTheSystemPromptNoLongerSaysReferenceEachScreenshotByItsNumber() {
        XCTAssertFalse(BASE_SYSTEM_PROMPT.contains("reference each screenshot by its number"),
                       "the sentence Windows removed for inviting a 1, 2, 3 renumbering")
        XCTAssertTrue(BASE_SYSTEM_PROMPT.contains("never renumber them into a fresh sequence"))
        XCTAssertTrue(BASE_SYSTEM_PROMPT.contains("has its first screenshot at step 2"))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
