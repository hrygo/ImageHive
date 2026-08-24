// NPY.swift — minimal .npy reader for parity fixtures (v1/v2, C-order,
// dtypes '<f4' and '<i8' — exactly what capture_*.py emits).

import Foundation
import MLX

enum NPYError: Error {
    case badMagic, badHeader(String), unsupportedDtype(String)
}

enum NPY {
    static func load(_ url: URL) throws -> MLXArray {
        let data = try Data(contentsOf: url)
        guard data.count > 10, data.prefix(6) == Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else {
            throw NPYError.badMagic
        }
        let major = data[6]
        var headerLen = 0
        var headerStart = 0
        if major == 1 {
            headerLen = Int(data[8]) | (Int(data[9]) << 8)
            headerStart = 10
        } else {
            headerLen = Int(data[8]) | (Int(data[9]) << 8) | (Int(data[10]) << 16) | (Int(data[11]) << 24)
            headerStart = 12
        }
        guard let header = String(data: data.subdata(in: headerStart ..< headerStart + headerLen), encoding: .ascii) else {
            throw NPYError.badHeader("undecodable")
        }
        guard header.contains("'fortran_order': False") else {
            throw NPYError.badHeader("fortran order unsupported")
        }
        guard let descrRange = header.range(of: "'descr': '"),
              let descrEnd = header.range(of: "'", range: descrRange.upperBound ..< header.endIndex)
        else { throw NPYError.badHeader("no descr") }
        let descr = String(header[descrRange.upperBound ..< descrEnd.lowerBound])

        guard let shapeStart = header.range(of: "'shape': ("),
              let shapeEnd = header.range(of: ")", range: shapeStart.upperBound ..< header.endIndex)
        else { throw NPYError.badHeader("no shape") }
        let shapeStr = header[shapeStart.upperBound ..< shapeEnd.lowerBound]
        let shape = shapeStr.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        let count = shape.isEmpty ? 1 : shape.reduce(1, *)

        let payload = data.subdata(in: (headerStart + headerLen) ..< data.count)
        switch descr {
        case "<f4":
            let values = payload.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float32.self).prefix(count))
            }
            return MLXArray(values, shape.isEmpty ? [1] : shape)
        case "<i8":
            let values = payload.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Int64.self).prefix(count))
            }
            return MLXArray(values.map { Int32($0) }, shape.isEmpty ? [1] : shape)
        default:
            throw NPYError.unsupportedDtype(descr)
        }
    }
}
