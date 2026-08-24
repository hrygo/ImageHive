// ConformanceTests.swift — offline conformance for the MLXSenseNovaU1 wrapper:
// manifest sanity, the fetch-vs-origin provenance split, the MAT gate
// (MaterializationConformance) per variant, and the CAN gate
// (CancellationConformance: pre-cancelled propagation + cadence declaration).
// Nothing here touches weights or runs a kernel (Stage-1 doctrine).

import Foundation
import MLXServeConformance
import MLXToolKit
import XCTest

@testable import MLXSenseNovaU1

final class ConformanceTests: XCTestCase {

    func testManifestSanity() {
        let m = SenseNovaU1Package.manifest
        XCTAssertEqual(m.license.weightLicense, .apache2)
        XCTAssertEqual(m.license.portCodeLicense, .mit)
        XCTAssertEqual(m.provenance.tier, 3)

        // every variant's quant tier carries a split footprint
        let quants = Set(m.requirements.footprints.map(\.quant))
        for variant in SenseNovaVariant.allCases {
            XCTAssertTrue(quants.contains(variant.quant), "no footprint for \(variant)")
        }
        for fp in m.requirements.footprints {
            XCTAssertGreaterThan(fp.residentBytes, 0)
            XCTAssertGreaterThan(fp.peakActivationBytes, 0, "flat footprint (activation folded in?)")
        }

        let caps = Set(m.surfaces.map(\.capability))
        XCTAssertEqual(caps, [.textToImage, .imageEdit])
    }

    /// The split-provenance rule: fetch address = OUR namespace, origin = theirs,
    /// and the trailing model name survives the mirror.
    func testProvenanceSplit() {
        let m = SenseNovaU1Package.manifest
        XCTAssertTrue(m.provenance.sourceRepo.hasPrefix("sensenova/"), "origin must be upstream")
        for variant in SenseNovaVariant.allCases {
            let config = SenseNovaU1Configuration(variant: variant)
            for source in config.weightSources {
                XCTAssertTrue(
                    source.repo.hasPrefix("mlx-community/"),
                    "\(variant): fetch address must be ours (\(source.repo))")
                XCTAssertTrue(
                    source.repo.contains("SenseNova-U1.5-8B-MoT"),
                    "\(variant): artifact name must carry the upstream checkpoint name")
            }
        }
    }

    func testMATGatePerVariant() {
        for variant in SenseNovaVariant.allCases {
            let report = MaterializationConformance.check(
                freshConfiguration: SenseNovaU1Configuration(variant: variant))
            XCTAssertTrue(report.passed, "MAT gate failed for \(variant):\n\(report.summary)")
        }
    }

    /// CAN-1/2: a pre-cancelled run must propagate CancellationError unchanged
    /// (the entry checkpoint precedes notLoaded validation, so no weights needed).
    func testCANPreCancelledRun() async {
        let package = SenseNovaU1Package(configuration: SenseNovaU1Configuration())
        let report = await CancellationConformance.checkRun(
            package: package, request: T2IRequest(prompt: "conformance probe"))
        XCTAssertTrue(report.passed, "CAN run gate failed:\n\(report.summary)")
    }

    /// CAN-3: long-run manifests declare their checkpoint cadence.
    func testCANCadenceDeclaration() {
        let report = CancellationConformance.checkCadence(
            manifest: SenseNovaU1Package.manifest,
            posture: .cadence([
                CancellationConformance.CheckpointCadence(phase: "denoise", unit: .step),
                CancellationConformance.CheckpointCadence(phase: "decode", unit: .token),
            ]))
        XCTAssertTrue(report.passed, "CAN cadence gate failed:\n\(report.summary)")
    }
}
