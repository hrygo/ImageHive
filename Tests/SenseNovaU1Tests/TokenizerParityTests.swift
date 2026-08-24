// TokenizerParityTests.swift — Swift tokenizer ids must equal the torch
// fixture ids exactly (the fixtures were produced by HF AutoTokenizer from
// the same vocab/merges the exported tokenizer.json encodes).

import Foundation
import XCTest

@testable import SenseNovaU1

final class TokenizerParityTests: XCTestCase {

    func testT2IPromptIDsMatchFixtures() async throws {
        let tok = try await SenseNovaTokenizer.load(from: ComponentParityTests.weightsDir)

        let data = try Data(
            contentsOf: ComponentParityTests.fixturesDir.appendingPathComponent("prompts.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let prompt = obj["prompt"] as! String

        let (cond, uncond) = tok.t2iIDs(prompt: prompt)

        let refCond = try NPY.load(
            ComponentParityTests.fixturesDir.appendingPathComponent("cond_input_ids.npy")
        ).asType(.int32).asArray(Int32.self)
        let refUncond = try NPY.load(
            ComponentParityTests.fixturesDir.appendingPathComponent("uncond_input_ids.npy")
        ).asType(.int32).asArray(Int32.self)

        XCTAssertEqual(cond, refCond, "cond ids")
        XCTAssertEqual(uncond, refUncond, "uncond ids")
        XCTAssertEqual(
            tok.encode(Conversation.imgStartToken), [Conversation.imgStartTokenID], "<img> id")
    }
}
