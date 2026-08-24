// SharedTestModel.swift — one bf16 full-model load shared by every e2e suite
// (33 GB resident; suites run serially in-process under `swift test`).

import Foundation
import MLX

@testable import SenseNovaU1

enum SharedTestModel {
    nonisolated(unsafe) static var model: NEOChatModel!

    static func get() throws -> NEOChatModel {
        if model == nil {
            print("[shared] loading full model bf16 ...")
            let t0 = Date()
            model = try WeightLoading.load(
                from: ComponentParityTests.weightsDir, dtype: .bfloat16)
            print("[shared] loaded in \(Date().timeIntervalSince(t0))s")
        }
        return model
    }
}
