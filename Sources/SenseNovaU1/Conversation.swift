// Conversation.swift — the `neo1_0` ChatML template (conversation.py) and the
// generation system message (utils.SYSTEM_MESSAGE_FOR_GEN), verbatim.
//
// T2I prompt shapes (validated against tokenizer fixtures, not re-derived):
//   cond:   <|im_start|>system\n{GEN_SYSTEM}<|im_end|>\n<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n<img>
//   uncond: <|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|im_end|>\n<|im_start|>assistant\n<img>
// ⚠ the uncond branch uses the template's EMPTY default system message and has
// no think block (trap ledger #7).

import Foundation

public enum Conversation {
    public static let imStart = "<|im_start|>"
    public static let sep = "<|im_end|>\n"
    public static let imgStartToken = "<img>"
    public static let imgEndToken = "</img>"
    public static let imgContextToken = "<IMG_CONTEXT>"
    public static let imgStartTokenID: Int32 = 151670

    public static let systemMessageForGen = """
        You are an image generation and editing assistant that accurately understands and executes user intent.

        You support two modes:

        1. Think Mode:
        If the task requires reasoning, you MUST start with a <think></think> block. Put all reasoning inside the block using plain text. DO NOT include any image tags. Keep it reasonable and directly useful for producing the final image.

        2. Non-Think Mode:
        If no reasoning is needed, directly produce the final image.

        Task Types:

        A. Text-to-Image Generation:
        - Generate a high-quality image based on the user's description.
        - Ensure visual clarity, semantic consistency, and completeness.
        - DO NOT introduce elements that contradict or override the user's intent.

        B. Image Editing:
        - Use the provided image(s) as input or reference for modification or transformation.
        - The result can be an edited image or a new image based on the reference(s).
        - Preserve all unspecified attributes unless explicitly changed.

        General Rules:
        - For any visible text in the image, follow the language specified for the rendered text in the user's description, not the language of the prompt. If no language is specified, use the user's input language.
        """

    /// neo1_0 / MPT-style ChatML prompt ending with an open assistant turn.
    /// ⚠ `get_prompt` OMITS the system block entirely when the system message
    /// is empty (the uncond prompt therefore starts at `<|im_start|>user`).
    public static func buildPrompt(
        userMessage: String,
        systemMessage: String = "",
        appendText: String = ""
    ) -> String {
        var out = systemMessage.isEmpty ? "" : "\(imStart)system\n\(systemMessage)\(sep)"
        out += "\(imStart)user\n\(userMessage)\(sep)"
        out += "\(imStart)assistant\n"
        return out + appendText
    }

    /// The T2I conditional prompt (non-think).
    public static func t2iCondPrompt(_ prompt: String) -> String {
        buildPrompt(
            userMessage: prompt,
            systemMessage: systemMessageForGen,
            appendText: "<think>\n\n</think>\n\n" + imgStartToken)
    }

    /// VQA / chat prompt. The model reasons by default and emits a
    /// `<think>…</think>` block that consumes the token budget before the answer
    /// (measured: 200 tokens of deliberation, answer truncated). Pre-closing the
    /// block — the same convention the reference uses for non-think T2I — makes
    /// the model answer immediately. `think: true` restores deliberation.
    public static func vqaPrompt(userMessage: String, think: Bool = false) -> String {
        buildPrompt(
            userMessage: userMessage, systemMessage: "",
            appendText: think ? "" : "<think>\n\n</think>\n\n")
    }

    /// Split a raw decode into (answer, reasoning) — the model's think block is
    /// never the answer, so the canonical text must not carry it.
    public static func splitReasoning(_ raw: String) -> (answer: String, reasoning: String?) {
        guard let close = raw.range(of: "</think>") else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let head = raw[raw.startIndex ..< close.lowerBound]
        let reasoning = head
            .replacingOccurrences(of: "<think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = String(raw[close.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer, reasoning.isEmpty ? nil : reasoning)
    }

    /// The T2I unconditional (CFG) prompt. A non-empty `negativePrompt` rides
    /// the same branch — that IS the CFG negative for this architecture (the
    /// reference passes an empty user message here).
    public static func t2iUncondPrompt(negativePrompt: String = "") -> String {
        buildPrompt(userMessage: negativePrompt, systemMessage: "", appendText: imgStartToken)
    }
}
