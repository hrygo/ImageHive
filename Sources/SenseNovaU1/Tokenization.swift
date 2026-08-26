// Tokenization.swift — Qwen2-BPE tokenizer via swift-transformers.
//
// The HF checkpoint ships only vocab.json + merges.txt (no tokenizer.json —
// same gap as the qwen-image family). We generate `tokenizer.json` offline
// (oracle venv: AutoTokenizer.save_pretrained; roundtrip-verified against the
// fixture ids) and load it here from the weights directory. No BOS; special
// tokens (<img>, <|im_start|>, …) come from added_tokens inside the file.

import Foundation
import Hub
import Tokenizers

public struct SenseNovaTokenizer {
    private let tokenizer: Tokenizer

    /// Load from a checkpoint directory containing tokenizer.json +
    /// tokenizer_config.json (run the oracle's tokenizer export first if the
    /// json is missing — see PORTING-SPEC open items).
    public static func load(from directory: URL) async throws -> SenseNovaTokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return SenseNovaTokenizer(tokenizer: tokenizer)
    }

    public func encode(_ text: String) -> [Int32] {
        tokenizer.encode(text: text).map(Int32.init)
    }

    public func decode(_ ids: [Int32]) -> String {
        tokenizer.decode(tokens: ids.map(Int.init))
    }

    /// The T2I prompt pair (cond with gen system message + think block + <img>,
    /// uncond with no system block).
    public func t2iIDs(
        prompt: String, negativePrompt: String = ""
    ) -> (cond: [Int32], uncond: [Int32]) {
        (
            encode(Conversation.t2iCondPrompt(prompt)),
            encode(Conversation.t2iUncondPrompt(negativePrompt: negativePrompt))
        )
    }
}
