import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import simd

enum ScanContract {
    static let schemaVersion = 1
    // Keyframe gate: how much the face must move before a new frame is kept.
    // Lower = denser capture. TrueDepth depth arrives at ~15 Hz, so a slow scan
    // can afford tight thresholds; 3 mm / 1.5 deg targets roughly 4x the frames
    // of the original 12 mm / 6 deg gate.
    static let translationThreshold: Float = 0.003
    static let rotationThreshold: Float = 1.5 * .pi / 180
}

struct FrameRecord: Codable {
    var index: Int
    var timestamp: Double
    var pose: [Double]
    var intrinsics: [Double]
    var depthWidth: Int
    var depthHeight: Int
    var colorWidth: Int
    var colorHeight: Int
    var depthFile: String
    var colorFile: String
    var confidence: Double
    /// ARFaceAnchor.transform (face->world). Optional; lets the Mac side fuse in
    /// the face frame when the camera world pose proves unreliable.
    var facePose: [Double]?

    enum CodingKeys: String, CodingKey {
        case index
        case timestamp
        case pose
        case intrinsics
        case depthWidth = "depth_width"
        case depthHeight = "depth_height"
        case colorWidth = "color_width"
        case colorHeight = "color_height"
        case depthFile = "depth_file"
        case colorFile = "color_file"
        case confidence
        case facePose = "face_pose"
    }
}

struct ScanMetaDocument: Codable {
    var schemaVersion: Int
    var runId: String
    var deviceModel: String
    var worldTrackingEnabled: Bool
    var frames: [FrameRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runId = "run_id"
        case deviceModel = "device_model"
        case worldTrackingEnabled = "world_tracking_enabled"
        case frames
    }
}

struct StatusDocument: Codable {
    var schemaVersion: Int
    var runId: String
    var state: String
    var keyframes: Int
    var depthMissing: Int
    var depthTotal: Int
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runId = "run_id"
        case state
        case keyframes
        case depthMissing = "depth_missing"
        case depthTotal = "depth_total"
        case updatedAt = "updated_at"
    }
}

enum DeviceModel {
    static let identifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }()
}

enum MatrixCodec {
    static func rowMajor(_ m: simd_float4x4) -> [Double] {
        let c = m.columns
        return [
            Double(c.0.x), Double(c.1.x), Double(c.2.x), Double(c.3.x),
            Double(c.0.y), Double(c.1.y), Double(c.2.y), Double(c.3.y),
            Double(c.0.z), Double(c.1.z), Double(c.2.z), Double(c.3.z),
            Double(c.0.w), Double(c.1.w), Double(c.2.w), Double(c.3.w),
        ]
    }

    static func rowMajor(_ m: simd_float3x3) -> [Double] {
        let c = m.columns
        return [
            Double(c.0.x), Double(c.1.x), Double(c.2.x),
            Double(c.0.y), Double(c.1.y), Double(c.2.y),
            Double(c.0.z), Double(c.1.z), Double(c.2.z),
        ]
    }

    static func scaleToDepth(_ matrix: simd_float3x3, reference: CGSize, depthWidth: Int, depthHeight: Int) -> [Double] {
        guard reference.width > 0, reference.height > 0, depthWidth > 0, depthHeight > 0 else {
            return rowMajor(matrix_identity_float3x3)
        }
        var m = matrix
        let sx = Float(depthWidth) / Float(reference.width)
        let sy = Float(depthHeight) / Float(reference.height)
        m.columns.0.x *= sx
        m.columns.1.y *= sy
        m.columns.2.x *= sx
        m.columns.2.y *= sy
        return rowMajor(m)
    }
}

enum DepthBinError: Error {
    case lockFailed
    case badFormat
    case noBaseAddress
    case badDimensions
    case rowTooShort
}

enum DepthBin {
    static func tightFloat32(from depthData: AVDepthData) throws -> (bytes: Data, width: Int, height: Int) {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buffer = converted.depthDataMap
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else {
            throw DepthBinError.badFormat
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else {
            throw DepthBinError.badDimensions
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw DepthBinError.lockFailed
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        let base: UnsafeMutableRawPointer?
        let rowBytes: Int
        if planeCount > 0 {
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        } else {
            base = CVPixelBufferGetBaseAddress(buffer)
            rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        }
        guard let base else {
            throw DepthBinError.noBaseAddress
        }
        let tightRow = width * MemoryLayout<Float>.size
        guard rowBytes >= tightRow else {
            throw DepthBinError.rowTooShort
        }
        let expected = tightRow * height
        var data = Data(count: expected)
        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress else { return }
            if rowBytes == tightRow {
                memcpy(dst, base, expected)
            } else {
                for row in 0..<height {
                    memcpy(
                        dst.advanced(by: row * tightRow),
                        base.advanced(by: row * rowBytes),
                        tightRow
                    )
                }
            }
        }
        guard data.count == width * height * 4 else {
            throw DepthBinError.badDimensions
        }
        return (data, width, height)
    }
}

enum RunIdentifier {
    static func resolve(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if !trimmed.isEmpty,
           trimmed.count <= 64,
           trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return trimmed
        }
        return timestamp()
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
