//
//  H264FrameEncoder.swift
//  VirtualDisplayKit
//
//  Hardware H.264 encoding for the browser stream. A video codec sends only
//  what changed between frames — with motion compensation — so scrolling or
//  dragging a window costs a fraction of what a JPEG per frame does.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One encoded H.264 access unit, ready for the wire.
struct EncodedVideoFrame {
    /// NAL units, each prefixed with its 4-byte big-endian length (AVCC)
    let data: Data

    /// True when the frame decodes on its own
    let isKeyframe: Bool

    /// The avcC decoder configuration record. Carried on every keyframe, so
    /// any keyframe is a complete starting point for a viewer.
    let configuration: Data?

    /// Presentation time in milliseconds since the encoder started
    let timestamp: UInt32
}

/// Wraps a real-time `VTCompressionSession` tuned for latency: no frame
/// reordering, no frame delay, one output per input.
///
/// Only ever touched on `queue` — VideoToolbox's output callback hops back
/// onto it — which is what makes the unchecked conformance safe.
final class H264FrameEncoder: @unchecked Sendable {

    /// Called on `queue` for every encoded frame.
    var onFrame: ((EncodedVideoFrame) -> Void)?

    private let queue: DispatchQueue
    private let frameRate: Int
    private var bitrate: Int

    private var session: VTCompressionSession?
    private var sessionSize = (width: 0, height: 0)

    private var startTime: CFAbsoluteTime?
    private var lastTimestamp: Int64 = -1
    private var lastKeyframeTime: CFAbsoluteTime = 0

    /// Next frame must be a keyframe, no matter how recent the last one was
    private var keyframeForced = false

    /// A viewer lost a frame and waits for a keyframe; honoured at most once
    /// per `minimumRecoverySpacing` so a congested link isn't flooded with
    /// the largest frames there are
    private var keyframeRequested = false

    /// Longest stretch without a keyframe. Only a safety net: viewers that
    /// miss a frame ask for one explicitly.
    static let keyframeInterval: TimeInterval = 4

    static let minimumRecoverySpacing: TimeInterval = 0.5

    init(queue: DispatchQueue, frameRate: Int, bitrate: Int) {
        self.queue = queue
        self.frameRate = max(1, frameRate)
        self.bitrate = bitrate
    }

    deinit {
        invalidate()
    }

    /// Bitrate that suits a stream of this size and rate at a given quality
    /// (0.1–1.0, the same scale as JPEG quality).
    ///
    /// Screen content is mostly still with sharp edges, so it needs more bits
    /// per pixel than camera video to keep text crisp.
    static func bitrate(width: Int, height: Int, frameRate: Int, quality: Double) -> Int {
        let bitsPerPixel = 0.05 + 0.15 * min(max(quality, 0.1), 1.0)
        let raw = Double(width * height * max(1, frameRate)) * bitsPerPixel
        return Int(min(max(raw, 1_000_000), 40_000_000))
    }

    // MARK: - Control

    /// Makes the very next frame a keyframe — for a viewer that just joined
    /// and has nothing to decode against.
    func forceKeyframe() {
        keyframeForced = true
    }

    /// Asks for a keyframe soon, for a viewer that missed a frame.
    func requestKeyframe() {
        keyframeRequested = true
    }

    func setBitrate(_ newBitrate: Int) {
        bitrate = newBitrate
        guard let session else { return }
        applyRateLimits(to: session)
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Encoding

    func encode(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if session == nil || sessionSize != (width, height) {
            invalidate()
            session = makeSession(width: width, height: height)
            sessionSize = (width, height)
            // A new session starts with a keyframe anyway; keep viewers in step.
            keyframeForced = true
        }
        guard let session else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if startTime == nil { startTime = now }

        // Timestamps must strictly increase, even for two frames in one ms.
        let milliseconds = max(lastTimestamp + 1, Int64((now - startTime!) * 1000))
        lastTimestamp = milliseconds

        var wantsKeyframe = keyframeForced
        if keyframeRequested && now - lastKeyframeTime >= Self.minimumRecoverySpacing {
            wantsKeyframe = true
        }
        if wantsKeyframe {
            keyframeForced = false
            keyframeRequested = false
        }

        let properties: CFDictionary? = wantsKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: milliseconds, timescale: 1000),
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let frame = Self.package(sample), let encoder = self else { return }
            encoder.queue.async {
                if frame.isKeyframe { encoder.lastKeyframeTime = CFAbsoluteTimeGetCurrent() }
                encoder.onFrame?(frame)
            }
        }
    }

    // MARK: - Session

    private func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else { return nil }

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            // B-frames would hold every frame back until a later one exists.
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: Self.keyframeInterval,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(Self.keyframeInterval) * frameRate,
            // Tag the colours so browsers convert back to RGB the same way.
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        applyRateLimits(to: session)

        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private func applyRateLimits(to session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Allow bursts — a keyframe after a still spell is worth it — but keep
        // any one second from swamping the link.
        let bytesPerSecond = Double(bitrate) / 8 * 1.5
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bytesPerSecond, 1.0] as CFArray
        )
    }

    // MARK: - Packaging

    static func package(_ sample: CMSampleBuffer) -> EncodedVideoFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var configuration: Data?
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            configuration = decoderConfiguration(of: format).map(H264ReorderRestriction.applied(to:))
        }

        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let milliseconds = time.isValid ? UInt32(truncatingIfNeeded: time.convertScale(1000, method: .default).value) : 0

        return EncodedVideoFrame(
            data: data,
            isKeyframe: isKeyframe,
            configuration: configuration,
            timestamp: milliseconds
        )
    }

    /// The avcC record: SPS, PPS and NAL length size, exactly what both
    /// WebCodecs (`description`) and an MP4 `avc1` sample entry expect.
    static func decoderConfiguration(of format: CMFormatDescription) -> Data? {
        guard let atoms = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else { return nil }
        return atoms["avcC"] as? Data
    }
}

// MARK: - SPS rewriting

/// Declares in the SPS that frames never need reordering.
///
/// VideoToolbox encodes without B-frames when asked, but doesn't say so in
/// the bitstream. Without `max_num_reorder_frames = 0`, decoders must assume
/// they might, and hold several decoded frames back before showing any — the
/// browser then shows the picture late, and on a still screen never shows the
/// last frames at all, since nothing arrives to push them out.
enum H264ReorderRestriction {

    /// Returns `avcC` with every SPS declaring no reordering. Anything this
    /// can't safely rewrite is returned untouched.
    static func applied(to avcC: Data) -> Data {
        let bytes = [UInt8](avcC)
        guard bytes.count > 7, bytes[0] == 1 else { return avcC }

        var output = Array(bytes[0..<5])
        var offset = 5

        let spsCount = Int(bytes[offset] & 0x1F)
        output.append(bytes[offset])
        offset += 1

        for _ in 0..<spsCount {
            guard offset + 2 <= bytes.count else { return avcC }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard offset + 2 + length <= bytes.count else { return avcC }
            let sps = Array(bytes[(offset + 2)..<(offset + 2 + length)])
            let rewritten = rewrite(sps: sps) ?? sps
            guard rewritten.count <= Int(UInt16.max) else { return avcC }
            output.append(UInt8(rewritten.count >> 8))
            output.append(UInt8(rewritten.count & 0xFF))
            output.append(contentsOf: rewritten)
            offset += 2 + length
        }

        // PPS entries and any profile extension bytes are unchanged.
        output.append(contentsOf: bytes[offset...])
        return Data(output)
    }

    /// The `max_num_reorder_frames` an SPS in `avcC` declares, or `nil` when
    /// it declares none.
    static func declaredReorderFrames(in avcC: Data) -> Int? {
        let bytes = [UInt8](avcC)
        guard bytes.count > 8, bytes[5] & 0x1F > 0 else { return nil }
        let length = Int(bytes[6]) << 8 | Int(bytes[7])
        guard bytes.count >= 8 + length, length > 1 else { return nil }
        var reader = BitReader(removingEmulationPrevention(Array(bytes[9..<(8 + length)])))
        guard let layout = try? parse(&reader), layout.hasRestriction else { return nil }
        _ = reader.bit()                                  // motion_vectors_over_pic_boundaries
        for _ in 0..<4 { _ = try? reader.unsignedGolomb() }
        return try? reader.unsignedGolomb()
    }

    // MARK: Rewriting

    private struct Layout {
        var maxReferenceFrames: Int
        /// Bit where the VUI starts, or where its present-flag is when absent
        var vuiFlagPosition: Int
        var hasVUI: Bool
        /// Bit of bitstream_restriction_flag, when there is a VUI
        var restrictionFlagPosition: Int
        var hasRestriction: Bool
    }

    private static func rewrite(sps: [UInt8]) -> [UInt8]? {
        guard sps.count > 4, sps[0] & 0x1F == 7 else { return nil }
        let rbsp = removingEmulationPrevention(Array(sps.dropFirst()))

        var reader = BitReader(rbsp)
        guard let layout = try? parse(&reader), !layout.hasRestriction else { return nil }

        var writer = BitWriter()
        if layout.hasVUI {
            // Everything up to bitstream_restriction_flag stays as it was.
            writer.copy(rbsp, bits: layout.restrictionFlagPosition)
        } else {
            writer.copy(rbsp, bits: layout.vuiFlagPosition)
            writer.write(1, bits: 1)                      // vui_parameters_present_flag
            for _ in 0..<5 { writer.write(0, bits: 1) }   // aspect, overscan, signal, chroma loc, timing
            writer.write(0, bits: 1)                      // nal_hrd_parameters_present_flag
            writer.write(0, bits: 1)                      // vcl_hrd_parameters_present_flag
            writer.write(0, bits: 1)                      // pic_struct_present_flag
        }

        writer.write(1, bits: 1)                          // bitstream_restriction_flag
        writer.write(1, bits: 1)                          // motion_vectors_over_pic_boundaries_flag
        writer.writeGolomb(2)                             // max_bytes_per_pic_denom
        writer.writeGolomb(1)                             // max_bits_per_mb_denom
        writer.writeGolomb(16)                            // log2_max_mv_length_horizontal
        writer.writeGolomb(16)                            // log2_max_mv_length_vertical
        writer.writeGolomb(0)                             // max_num_reorder_frames
        writer.writeGolomb(max(1, layout.maxReferenceFrames)) // max_dec_frame_buffering
        writer.write(1, bits: 1)                          // rbsp_stop_one_bit
        writer.alignWithZeros()

        return [sps[0]] + addingEmulationPrevention(writer.bytes)
    }

    private struct Unsupported: Error {}

    /// Walks the SPS far enough to find the VUI and, inside it, the
    /// bitstream restriction. Bails on the rare parts VideoToolbox never
    /// writes (scaling matrices, HRD parameters) rather than guess.
    private static func parse(_ r: inout BitReader) throws -> Layout {
        let profile = try r.bits(8)
        _ = try r.bits(16)                                // constraint flags, level
        _ = try r.unsignedGolomb()                        // seq_parameter_set_id

        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = try r.unsignedGolomb()
            if chroma == 3 { _ = try r.bits(1) }
            _ = try r.unsignedGolomb()                    // bit_depth_luma_minus8
            _ = try r.unsignedGolomb()                    // bit_depth_chroma_minus8
            _ = try r.bits(1)                             // qpprime_y_zero_transform_bypass
            if try r.bits(1) == 1 { throw Unsupported() } // seq_scaling_matrix_present
        }

        _ = try r.unsignedGolomb()                        // log2_max_frame_num_minus4
        let pocType = try r.unsignedGolomb()
        if pocType == 0 {
            _ = try r.unsignedGolomb()
        } else if pocType == 1 {
            _ = try r.bits(1)
            _ = try r.signedGolomb()
            _ = try r.signedGolomb()
            let cycle = try r.unsignedGolomb()
            for _ in 0..<cycle { _ = try r.signedGolomb() }
        }

        let maxReferenceFrames = try r.unsignedGolomb()
        _ = try r.bits(1)                                 // gaps_in_frame_num_allowed
        _ = try r.unsignedGolomb()                        // pic_width_in_mbs_minus1
        _ = try r.unsignedGolomb()                        // pic_height_in_map_units_minus1
        if try r.bits(1) == 0 { _ = try r.bits(1) }       // frame_mbs_only / mb_adaptive
        _ = try r.bits(1)                                 // direct_8x8_inference
        if try r.bits(1) == 1 {                           // frame_cropping
            for _ in 0..<4 { _ = try r.unsignedGolomb() }
        }

        let vuiFlagPosition = r.position
        guard try r.bits(1) == 1 else {
            return Layout(maxReferenceFrames: maxReferenceFrames, vuiFlagPosition: vuiFlagPosition,
                          hasVUI: false, restrictionFlagPosition: 0, hasRestriction: false)
        }

        if try r.bits(1) == 1 {                           // aspect_ratio_info
            if try r.bits(8) == 255 { _ = try r.bits(32) }
        }
        if try r.bits(1) == 1 { _ = try r.bits(1) }       // overscan
        if try r.bits(1) == 1 {                           // video_signal_type
            _ = try r.bits(4)
            if try r.bits(1) == 1 { _ = try r.bits(24) }  // colour description
        }
        if try r.bits(1) == 1 {                           // chroma_loc_info
            _ = try r.unsignedGolomb()
            _ = try r.unsignedGolomb()
        }
        if try r.bits(1) == 1 { _ = try r.bits(32); _ = try r.bits(32); _ = try r.bits(1) } // timing
        let nalHRD = try r.bits(1), vclHRD = try r.bits(1)
        if nalHRD == 1 || vclHRD == 1 { throw Unsupported() }
        _ = try r.bits(1)                                 // pic_struct_present

        let restrictionFlagPosition = r.position
        let hasRestriction = try r.bits(1) == 1
        return Layout(maxReferenceFrames: maxReferenceFrames, vuiFlagPosition: vuiFlagPosition,
                      hasVUI: true, restrictionFlagPosition: restrictionFlagPosition, hasRestriction: hasRestriction)
    }

    // MARK: Emulation prevention

    static func removingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    static func addingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 4)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte <= 3 { output.append(3); zeros = 0 }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    // MARK: Bits

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bit() -> Int? {
            guard position < bytes.count * 8 else { return nil }
            defer { position += 1 }
            return Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
        }

        mutating func bits(_ count: Int) throws -> Int {
            var value = 0
            for _ in 0..<count {
                guard let b = bit() else { throw Unsupported() }
                value = value << 1 | b
            }
            return value
        }

        mutating func unsignedGolomb() throws -> Int {
            var zeros = 0
            while try bits(1) == 0 {
                zeros += 1
                if zeros > 31 { throw Unsupported() }
            }
            return (1 << zeros) - 1 + (try bits(zeros))
        }

        mutating func signedGolomb() throws -> Int {
            let k = try unsignedGolomb()
            return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var count = 0

        mutating func write(_ value: Int, bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                if count & 7 == 0 { bytes.append(0) }
                if (value >> i) & 1 == 1 { bytes[bytes.count - 1] |= 1 << (7 - UInt8(count & 7)) }
                count += 1
            }
        }

        mutating func writeGolomb(_ value: Int) {
            let coded = value + 1
            let length = Int.bitWidth - coded.leadingZeroBitCount
            write(0, bits: length - 1)
            write(coded, bits: length)
        }

        mutating func copy(_ source: [UInt8], bits: Int) {
            for i in 0..<bits {
                write(Int(source[i >> 3] >> (7 - UInt8(i & 7)) & 1), bits: 1)
            }
        }

        mutating func alignWithZeros() {
            while count & 7 != 0 { write(0, bits: 1) }
        }
    }
}
