import Foundation
import simd
import CZstd

/// Decodes Spatial Vivid MP4 files (EGSC-compressed 3D Gaussian Splats in a GLB
/// packaged as MP4) into `SplatPoint`s.
///
/// Pipeline: MP4 (ISOBMFF) → GLB → EGSC bitstream → ZSTD substreams →
/// unpack / de-predict / de-quantize / de-transform → splat points.
///
/// Reference: spatial-vivid-egsc Decoder/C++ (T/UWA 050-2026), ported to Swift.
public enum EGSCDecodeError: Swift.Error {
    case notSpatialVivid
    case invalidGLB
    case invalidEGSCStream(String)
    case unsupported(String)
    case decodeFailed(String)
}

public class MP4SpatialVividSceneReader: SplatSceneReader {
    public init(_ url: URL) throws {
        self.url = url
    }

    private let url: URL

    public func read() async throws -> AsyncThrowingStream<[SplatPoint], Swift.Error> {
        let points = try await readAll()
        return AsyncThrowingStream { continuation in
            continuation.yield(points)
            continuation.finish()
        }
    }

    public func readAll() async throws -> [SplatPoint] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let glb = try MP4SpatialVividDemuxer(data: data).extractGLB()
        let decoded = try EGSCDecoder(glb: glb).decode()
        return decoded
    }
}

// MARK: - GLB container

struct GLBContainer {
    struct Chunk {
        var type: UInt32
        var data: Data
    }

    var json: [String: Any]
    var binary: Data

    init(glb: Data) throws {
        guard glb.count >= 12, glb.prefix(4) == Data("glTF".utf8) else {
            throw EGSCDecodeError.invalidGLB
        }
        var chunks: [Chunk] = []
        var pos = 12
        while pos + 8 <= glb.count {
            let length = Int(UInt32(littleEndian: glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }))
            let chunkType = UInt32(littleEndian: glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos+4, as: UInt32.self) })
            guard pos + 8 + length <= glb.count else { break }
            chunks.append(Chunk(type: chunkType, data: glb.subdata(in: pos+8..<pos+8+length)))
            pos += 8 + length
            pos = (pos + 3) & ~3 // 4-byte alignment
        }
        guard let jsonChunk = chunks.first(where: { $0.type == 0x4E4F534A }),
              let json = try JSONSerialization.jsonObject(with: jsonChunk.data) as? [String: Any],
              let binChunk = chunks.first(where: { $0.type == 0x004E4942 }) else {
            throw EGSCDecodeError.invalidGLB
        }
        self.json = json
        self.binary = binChunk.data
    }
}

// MARK: - EGSC bitstream decoder

struct EGSCDecoder {
    let bitstream: Data

    enum AttributeType: Int {
        case position = 0, opacity, scale, rotation
        // 4..19: SH coefficients (sh0 = 4, rest = 5..19), 20: features_rest, 21: importance
    }

    static let attributeName: [Int: String] = [
        0: "means", 1: "opacity", 2: "scaling", 3: "rotation",
        4: "features_dc", 21: "importance",
    ]

    init(glb: Data) throws {
        let container = try GLBContainer(glb: glb)
        guard let mesh = (container.json["meshes"] as? [[String: Any]])?.first,
              let primitive = (mesh["primitives"] as? [[String: Any]])?.first,
              let primExtensions = primitive["extensions"] as? [String: Any],
              let khr = primExtensions["KHR_gaussian_splatting"] as? [String: Any],
              let khrExt = khr["extensions"] as? [String: Any],
              let egsc = khrExt["UWA_gaussian_splatting_compression_EGSC"] as? [String: Any],
              let bufferViewIndex = egsc["bufferView"] as? Int,
              let bufferViews = container.json["bufferViews"] as? [[String: Any]],
              bufferViewIndex < bufferViews.count else {
            throw EGSCDecodeError.notSpatialVivid
        }
        let view = bufferViews[bufferViewIndex]
        let byteOffset = view["byteOffset"] as? Int ?? 0
        let byteLength = view["byteLength"] as? Int ?? container.binary.count
        self.bitstream = container.binary.subdata(in: byteOffset..<min(byteOffset+byteLength, container.binary.count))
    }

    // MARK: Metadata structures

    struct SubBitstreamInfo {
        var size: Int
        var subsetID: Int
        var decodeType: Int  // 0=ZSTD, 1=ASTC, 2=video
        // entropy meta (decodeType 0)
        var entropyDecodeType: Int = 0
        var attributeType: Int = -1
        var bitdepth: Int = 0
        var byteshift: Int = 0
        // texture meta (decodeType 1)
        var textureInfo: TextureInfo?
    }

    struct TextureInfo {
        var blockWidth: Int
        var blockHeight: Int
        var imageWidth: Int
        var imageHeight: Int
        var packedData: Data  // raw ASTC blocks (16 bytes each)
    }

    struct ReconstructionInfo {
        var attributeType: Int = 0
        var component: Int = 0
        var quantizationType: Int = 0
        var quantizationBitdepth: Int = 0
        var predictionType: Int = 0
        var predictionByteshift: Int = 0
        var predictionBlocksize: Int = 16
        var transformationType: Int = 0
        var quantMin: [Float] = []
        var quantMax: [Float] = []
        /// quantizationType == 3: per-patch [size, min×component, max×component]
        var patchData: [[Float]] = []
    }

    struct BitReader {
        let data: Data
        var pos: Int
        var bit: Int = 0

        init(_ data: Data, pos: Int = 0) {
            self.data = data
            self.pos = pos
        }

        mutating func uint8() -> Int {
            guard pos < data.count else { return 0 }
            let v = Int(data[pos]); pos += 1; return v
        }
        mutating func uint32() -> Int {
            // Bit-level read: 32 bits starting at the current bit position.
            var v = 0
            for _ in 0..<32 {
                guard pos < data.count else { return v }
                let byte = data[data.startIndex + pos]
                v = (v << 1) | Int((byte >> (7 - bit)) & 1)
                bit += 1
                if bit == 8 { bit = 0; pos += 1 }
            }
            return v
        }
        mutating func bits(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                guard pos < data.count else { return v }
                let byte = data[data.startIndex + pos]
                v = (v << 1) | Int((byte >> (7 - bit)) & 1)
                bit += 1
                if bit == 8 { bit = 0; pos += 1 }
            }
            return v
        }
        mutating func float32() -> Float {
            // Reads 32 bits starting at the current (possibly mid-byte) bit
            // position — EGSC float fields are bit-packed, not byte-aligned.
            var v: UInt32 = 0
            for _ in 0..<32 {
                guard pos < data.count else { return Float(bitPattern: v) }
                let byte = data[data.startIndex + pos]
                v = (v << 1) | UInt32((byte >> (7 - bit)) & 1)
                bit += 1
                if bit == 8 { bit = 0; pos += 1 }
            }
            return Float(bitPattern: v)
        }
        mutating func bytes(_ n: Int) -> Data {
            let d = data.subdata(in: pos..<min(pos+n, data.count))
            pos += n
            return d
        }
        mutating func align() {
            if bit != 0 { bit = 0; pos += 1 }
        }
        var byteIndex: Int { bit == 0 ? pos : pos + 1 }
    }

    // MARK: - Decode

    func decode() throws -> [SplatPoint] {
        guard bitstream.count > 8 else { throw EGSCDecodeError.invalidEGSCStream("too small") }
        let metaByteSize = readBE32(bitstream, 0)
        var reader = BitReader(bitstream, pos: 4)
        let meta = try readMetadata(&reader, metaByteSize)
        // reader starts at absolute offset 4 (after metaByteSize); byteIndex is
        // absolute, so the parsed size is byteIndex - 4 (unit header + metadata).
        if reader.byteIndex - 4 != metaByteSize {
            throw EGSCDecodeError.invalidEGSCStream("metadata size mismatch: \(reader.byteIndex - 4) != \(metaByteSize)")
        }
        guard meta.profileIdc == 1 else {
            throw EGSCDecodeError.unsupported("only basic profile (profileIdc=1) supported, got \(meta.profileIdc)")
        }

        let subStreamHeaderOffset = 4 + metaByteSize
        let subBitstreamByteSize = readBE32(bitstream, subStreamHeaderOffset)
        var subReader = BitReader(bitstream, pos: subStreamHeaderOffset + 4)
        // Sub-bitstream unit header: 4 bits type + 28 bits reserved
        let unitType = subReader.bits(4)
        subReader.bits(28)
        guard unitType == 1 else { throw EGSCDecodeError.invalidEGSCStream("sub unit type \(unitType)") }

        // Decode each substream (ZSTD)
        var decodedSubstreams: [Data] = []
        for (i, sub) in meta.substreams.enumerated() {
            let raw = subReader.bytes(sub.size)
            guard raw.count == sub.size else {
                throw EGSCDecodeError.invalidEGSCStream("substream \(i) truncated")
            }
            switch sub.decodeType {
            case 0:
                let d = try zstdDecompress(raw)
                decodedSubstreams.append(d)
            case 1:
                decodedSubstreams.append(raw) // texture — decompressed later
            default:
                throw EGSCDecodeError.unsupported("video substream \(i) not supported")
            }
        }
        if subReader.byteIndex != subBitstreamByteSize + 8 {
            // tolerant: some streams may have trailing alignment
        }

        // Unpack → de-predict → de-quantize → de-transform, per attribute
        // (matches the C++ decoder's attribute-keyed maps).
        var quantized: [String: [Int32]] = [:]
        for (i, sub) in meta.substreams.enumerated() {
            guard sub.decodeType == 0 else { continue } // texture streams handled separately
            try unpackEntropy(decodedSubstreams[i], sub, meta, &quantized)
        }
        try dePredictMinor(&quantized, meta)
        var dequantized: [String: [Float]] = [:]
        try deQuantize(quantized, meta, &dequantized)
        let points = try buildPoints(dequantized, meta)

        // GLB camera (initial view) is handled by the app layer; here we only emit points.
        return points
    }

    // MARK: Metadata

    struct Metadata {
        var profileIdc = 0
        var gsPointsNum = 0
        var shDegree = 0
        var posMin: [Float] = []
        var posMax: [Float] = []
        var substreams: [SubBitstreamInfo] = []
        var reconstructions: [ReconstructionInfo] = []
    }

    private func readMetadata(_ reader: inout BitReader, _ expectedSize: Int) throws -> Metadata {
        var meta = Metadata()
        // Unit header: 4 bits type + 28 bits reserved
        let unitType = reader.bits(4)
        reader.bits(28)
        guard unitType == 0 else { throw EGSCDecodeError.invalidEGSCStream("meta unit type \(unitType)") }

        meta.profileIdc = reader.uint8()
        meta.gsPointsNum = reader.uint32()
        let subBitstreamNum = reader.bits(5)
        meta.shDegree = reader.bits(3)
        for _ in 0..<3 {
            meta.posMin.append(reader.float32())
            meta.posMax.append(reader.float32())
        }
        let gsSubsetNum = reader.bits(8)
        var subPoints: [Int] = []
        for _ in 0..<gsSubsetNum { subPoints.append(reader.uint32()) }
        _ = subPoints

        for _ in 0..<subBitstreamNum {
            var sub = SubBitstreamInfo(size: 0, subsetID: 0, decodeType: 0)
            sub.size = reader.uint32()
            sub.subsetID = reader.bits(8)
            sub.decodeType = reader.uint8()
            if sub.decodeType == 0 {
                sub.entropyDecodeType = reader.uint8()
                sub.attributeType = reader.uint8()
                sub.bitdepth = reader.bits(8)
                sub.byteshift = reader.bits(8)
            } else if sub.decodeType == 1 {
                // TextureDecodeInformation: entropyDecodeType(8) + packingMapTextureCodecId(8)
                sub.entropyDecodeType = reader.uint8()
                let textureCodecId = reader.uint8()

                // TexturePackingInformation
                let mapWidth = reader.bits(16)
                let mapHeight = reader.bits(16)
                let regionWidth = reader.bits(16)
                let regionHeight = reader.bits(16)
                let scanType = reader.bits(4)
                if scanType == 1 {
                    _ = reader.bits(8) // packingScaningBlockSize
                }
                let regionCountMinus1 = reader.bits(8)
                for _ in 0...regionCountMinus1 {
                    _ = reader.bits(16) // regionTopLeftX
                    _ = reader.bits(16) // regionTopLeftY
                }
                let textureChannelNum = reader.bits(8)
                let textureByteshift = reader.bits(8)
                reader.align()

                sub.attributeType = reader.uint8()
                sub.textureInfo = TextureInfo(
                    blockWidth: 0, blockHeight: 0,
                    imageWidth: mapWidth, imageHeight: mapHeight,
                    packedData: Data())
                sub.byteshift = textureByteshift
                _ = textureCodecId
                _ = textureChannelNum
                _ = regionWidth
                _ = regionHeight
            } else {
                throw EGSCDecodeError.unsupported("video meta in stream")
            }
            meta.substreams.append(sub)
        }

        // Reconstruction information per subset (each entry byte-aligns at its end,
        // matching the Python encoder's writer layout).
        for _ in 0..<gsSubsetNum {
            let count = reader.uint8()
            var subsetRecons: [ReconstructionInfo] = []
            for _ in 0..<count {
                var info = ReconstructionInfo()
                info.attributeType = reader.bits(8)
                info.component = reader.bits(8)
                info.quantizationType = reader.bits(4)
                info.quantizationBitdepth = reader.bits(8)
                info.predictionType = reader.bits(4)
                if info.predictionType == 1 {
                    info.predictionByteshift = reader.bits(4)
                    info.predictionBlocksize = reader.bits(16)
                }
                info.transformationType = reader.bits(4)
                if info.quantizationType == 2 {
                    for _ in 0..<info.component {
                        info.quantMin.append(reader.float32())
                        info.quantMax.append(reader.float32())
                    }
                } else if info.quantizationType == 3 {
                    let patchNum = reader.uint32()
                    var patchMeta: [[Float]] = []
                    for _ in 0..<patchNum {
                        let patchSize = reader.uint32()
                        // Patch layout is contiguous: min[component] then max[component]
                        // (python writer: min bytes block followed by max bytes block).
                        var mins: [Float] = []
                        for _ in 0..<info.component {
                            mins.append(reader.float32())
                        }
                        var maxs: [Float] = []
                        for _ in 0..<info.component {
                            maxs.append(reader.float32())
                        }
                        patchMeta.append([Float(patchSize)] + mins + maxs)
                    }
                    info.patchData = patchMeta
                }
                reader.align()
                if info.quantizationType == 2 {
                    }
                subsetRecons.append(info)
            }
            meta.reconstructions = subsetRecons // single-subset files dominate; keep last
        }
        reader.align()
        return meta
    }


    // MARK: - ZSTD

    private func zstdDecompress(_ input: Data) throws -> Data {
        let frameSize: UInt64 = input.withUnsafeBytes { srcPtr in
            ZSTD_getFrameContentSize(srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), input.count)
        }
        guard frameSize > 0, frameSize != .max, frameSize < 1 << 32 else {
            throw EGSCDecodeError.decodeFailed("zstd frame size unknown")
        }
        let capacity = Int(frameSize)
        var output = Data(count: capacity)
        let decoded = output.withUnsafeMutableBytes { dstPtr in
            input.withUnsafeBytes { srcPtr in
                ZSTD_decompress(
                    dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), capacity,
                    srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), input.count)
            }
        }
        guard decoded == capacity else {
            throw EGSCDecodeError.decodeFailed("zstd decompression failed: expected \(capacity), got \(decoded)")
        }
        return output
    }

    // MARK: - Unpack

    private static func attributeName(_ t: Int) -> String {
        switch t {
        case 0: return "means"
        case 1: return "opacity"
        case 2: return "scaling"
        case 3: return "rotation"
        case 4: return "features_dc"
        case 20: return "features_rest"
        case 21: return "importance"
        default: return (5...19).contains(t) ? "features_rest" : "unknown"
        }
    }

    private static func channels(for attr: String) -> Int {
        switch attr {
        case "means": return 3
        case "opacity": return 1
        case "scaling": return 3
        case "rotation": return 4
        case "features_dc": return 3
        case "features_rest": return 45
        case "importance": return 1
        default: return 3
        }
    }

    // MARK: - Unpack (unpackEntropy)

    private func unpackEntropy(_ data: Data, _ sub: SubBitstreamInfo,
                               _ meta: Metadata, _ out: inout [String: [Int32]]) throws {
        let attr = Self.attributeName(sub.attributeType)
        let channels = Self.channels(for: attr)
        let n = meta.gsPointsNum * channels
        guard data.count >= n else {
            throw EGSCDecodeError.decodeFailed("entropy stream attr \(sub.attributeType) too small: \(data.count) < \(n)")
        }
        let shift = sub.byteshift
        var values = [Int32](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            if shift >= 0 {
                for i in 0..<n {
                    values[i] = Int32(src[i]) << shift
                }
            } else {
                let limit = Int32((1 << -shift) - 1)
                for i in 0..<n {
                    values[i] = min(Int32(src[i]), limit)
                }
            }
        }
        // Multiple entropy streams of the same attribute accumulate (e.g. means low+high).
        if var existing = out[attr] {
            for i in 0..<n where i < existing.count {
                existing[i] += values[i]
            }
            out[attr] = existing
        } else {
            out[attr] = values
        }
    }

    // MARK: - Prediction (minor block cumsum)

    private func dePredictMinor(_ quantized: inout [String: [Int32]], _ meta: Metadata) throws {
        for info in meta.reconstructions {
            let attr = Self.attributeName(info.attributeType)
            guard var data = quantized[attr], info.predictionType == 1,
                  info.predictionByteshift >= 0 else { continue }
            let channels = Self.channels(for: attr)
            let levels = Int32(1 << info.predictionByteshift)
            let blockSize = info.predictionBlocksize
            let blockSizeSquared = blockSize * blockSize
            let count = data.count

            var hi = [Int32](repeating: 0, count: count)
            var lo = [Int32](repeating: 0, count: count)
            for i in 0..<count {
                hi[i] = data[i] / levels
                lo[i] = data[i] % levels
            }
            var numBlocks = count / (blockSizeSquared * channels)
            if count % (blockSizeSquared * channels) != 0 { numBlocks += 1 }
            for b in 0..<numBlocks {
                let blockStart = b * blockSizeSquared * channels
                let blockEnd = min(blockStart + blockSizeSquared * channels, count)
                for c in 0..<channels {
                    var cumsum: Int32 = 0
                    var i = blockStart + c
                    while i < blockEnd {
                        cumsum = (cumsum + hi[i]) % 256
                        hi[i] = cumsum
                        i += channels
                    }
                }
            }
            for i in 0..<count {
                data[i] = hi[i] * levels + lo[i]
            }
            quantized[attr] = data
        }
    }

    // MARK: - Dequantization

    private func deQuantize(_ quantized: [String: [Int32]], _ meta: Metadata,
                            _ out: inout [String: [Float]]) throws {
        for (attr, q) in quantized {
            let info = meta.reconstructions.first { Self.attributeName($0.attributeType) == attr }
            guard let info else {
                out[attr] = q.map(Float.init)
                continue
            }
            let maxQuant = Float((1 << info.quantizationBitdepth) - 1)
            var result = [Float](repeating: 0, count: q.count)

            switch info.quantizationType {
            case 1: // standard
                for i in 0..<q.count { result[i] = Float(q[i]) / maxQuant }
            case 2: // min/max
                let comp = max(info.component, 1)
                for i in 0..<q.count {
                    let c = i % comp
                    let mn = c < info.quantMin.count ? info.quantMin[c] : 0
                    let mx = c < info.quantMax.count ? info.quantMax[c] : 1
                    result[i] = (Float(q[i]) / maxQuant) * (mx - mn + 1e-6) + mn
                }
            case 3: // group/patch min-max
                let comp = max(info.component, 1)
                var groupOffset = 0
                for patch in info.patchData {
                    let groupSize = Int(patch[0])
                    let mins = Array(patch[1...min(comp, patch.count-1)])
                    let maxs = Array(patch[min(comp, patch.count-1)+1...min(2*comp, patch.count-1)])
                    for p in 0..<groupSize*comp where groupOffset + p < q.count {
                        let idx = groupOffset + p
                        let c = idx % comp
                        let mn = c < mins.count ? mins[c] : 0
                        let mx = c < maxs.count ? maxs[c] : 1
                        result[idx] = (Float(q[idx]) / maxQuant) * (mx - mn + 1e-6) + mn
                    }
                    groupOffset += groupSize * comp
                }
            default: // none
                for i in 0..<q.count { result[i] = Float(q[i]) }
            }
            out[attr] = result
        }
    }

    // MARK: - Build points

    private func buildPoints(_ attrs: [String: [Float]], _ meta: Metadata) throws -> [SplatPoint] {
        let n = meta.gsPointsNum
        var points: [SplatPoint] = []
        points.reserveCapacity(n)

        // De-normalize means against the metadata position range.
        let posMin = meta.posMin
        let posMax = meta.posMax
        let means = attrs["means"] ?? [Float](repeating: 0, count: n * 3)
        let opacity = attrs["opacity"] ?? [Float](repeating: 0.5, count: n)
        let scaling = attrs["scaling"] ?? [Float](repeating: 0, count: n * 3)
        let rotation = attrs["rotation"] ?? [Float](repeating: 0, count: n * 4)
        let dc = attrs["features_dc"] ?? [Float](repeating: 0, count: n * 3)
        // SH rest comes from the ASTC texture stream; without GPU ASTC decode we
        // fall back to DC-only color (shDegree effective 0 for this path).
        let shCoefCount = max(1, shCoefficientCount(min(meta.shDegree, 0)))

        for i in 0..<n {
            // Patch de-quantization already produced world-space coordinates.
            let position = SIMD3<Float>(means[i*3], means[i*3+1], means[i*3+2])

            // opacity: raw sigmoid-domain value → linear [0,1]
            let rawOpacity = opacity[i]
            let linearOpacity = 1.0 / (1.0 + exp(-rawOpacity))

            // scaling stays in log/exponent domain (same as 3DGS PLY)
            let scale = SIMD3<Float>(scaling[i*3], scaling[i*3+1], scaling[i*3+2])

            // rotation: euler (roll, pitch, yaw) → quaternion
            let roll = rotation[i*4]
            let pitch = rotation[i*4+1]
            let yaw = rotation[i*4+2]
            let cr = cos(roll * 0.5), sr = sin(roll * 0.5)
            let cp = cos(pitch * 0.5), sp = sin(pitch * 0.5)
            let cy = cos(yaw * 0.5), sy = sin(yaw * 0.5)
            let qw = cr * cp * cy + sr * sp * sy
            let qx = sr * cp * cy - cr * sp * sy
            let qy = cr * sp * cy + sr * cp * sy
            let qz = cr * cp * sy - sr * sp * cy

            // DC color
            let sh0 = SIMD3<Float>(dc[i*3], dc[i*3+1], dc[i*3+2])
            var shCoefs: [SIMD3<Float>] = [sh0]
            _ = shCoefCount

            points.append(SplatPoint(
                position: position,
                color: .sphericalHarmonicFloat(shCoefs),
                opacity: .linearFloat(linearOpacity),
                scale: .exponent(scale),
                rotation: simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)))
        }
        return points
    }

    private func shCoefficientCount(_ degree: Int) -> Int {
        switch degree {
        case 0: return 1
        case 1: return 4
        case 2: return 9
        case 3: return 16
        default: return 1
        }
    }

    private func readBE32(_ d: Data, _ pos: Int) -> Int {
        Int(d[d.startIndex+pos]) << 24 | Int(d[d.startIndex+pos+1]) << 16
        | Int(d[d.startIndex+pos+2]) << 8 | Int(d[d.startIndex+pos+3])
    }
}
