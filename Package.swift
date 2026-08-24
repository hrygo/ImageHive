// swift-tools-version: 6.2
// sensenova-u1-swift — Swift/MLX port of SenseNova-U1.5-8B-MoT (Apache-2.0):
// NEO-Unify Mixture-of-Transformers (8.1B und + 8.1B gen streams on a shared
// 42-layer Qwen3 skeleton), pixel-space rectified-flow T2I/edit/VQA, NO VAE.
// Reference = OpenSenseNova/SenseNova-U1 @ a62fd54 (src/sensenova_u1/models/neo_unify),
// weights = sensenova/SenseNova-U1.5-8B-MoT @ 07d76f6.
// Spec + trap ledger: ../sensenova-u1-oracle/PORTING-SPEC.md (AB-T-0089).
// Parity gates on fixtures from ../sensenova-u1-oracle/capture_*.py
// (SENSENOVA_FIXTURES env var points at the fixtures dir).

import PackageDescription

let package = Package(
    name: "SenseNovaU1",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "SenseNovaU1", targets: ["SenseNovaU1"]),
        // MLXEngine wrapper: the conformant multi-capability ModelPackage
        // (textToImage + imageEdit on one resident core).
        .library(name: "MLXSenseNovaU1", targets: ["MLXSenseNovaU1"]),
        .executable(name: "sensenova-cli", targets: ["sensenova-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
        // MLXEngine contract (MLXToolKit) + conformance kits. ≥0.32.0 for
        // engine-executed materialization (contract 1.24) and the CAN gate.
        .package(url: "https://github.com/xocialize/mlx-engine-swift", from: "0.32.0"),
    ],
    targets: [
        .target(
            name: "SenseNovaU1",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/SenseNovaU1"
        ),
        .target(
            name: "MLXSenseNovaU1",
            dependencies: [
                "SenseNovaU1",
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ],
            path: "Sources/MLXSenseNovaU1"
        ),
        .testTarget(
            name: "MLXSenseNovaU1Tests",
            dependencies: [
                "MLXSenseNovaU1",
                .product(name: "MLXServeConformance", package: "mlx-engine-swift"),
            ],
            path: "Tests/MLXSenseNovaU1Tests"
        ),
        .executableTarget(
            name: "sensenova-cli",
            dependencies: [
                "SenseNovaU1",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/sensenova-cli"
        ),
        .testTarget(
            name: "SenseNovaU1Tests",
            dependencies: ["SenseNovaU1"],
            path: "Tests/SenseNovaU1Tests"
        ),
    ]
)
