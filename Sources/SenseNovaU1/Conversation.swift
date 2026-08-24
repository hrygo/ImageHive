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

    /// The T2I unconditional (CFG) prompt.
    public static func t2iUncondPrompt() -> String {
        buildPrompt(userMessage: "", systemMessage: "", appendText: imgStartToken)
    }
}
