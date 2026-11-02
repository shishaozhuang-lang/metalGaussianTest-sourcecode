import Foundation
import Metal
import simd
import SplatIO

/// Stable, opaque handle identifying a chunk within a SplatRenderer.
/// ChunkIDs are assigned monotonically and never reused; they are *not* the same as the contiguous
/// chunk indices used internally by the sorter and shaders (see ``ChunkedSplatIndex``).
public struct ChunkID: Hashable, Sendable, Equatable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
}

/// A chunk of gaussian splats.
/// Created externally and added to a SplatRenderer via `addChunk(_:)`.
public struct SplatChunk: @unchecked Sendable {
    /// The splat data buffer
    public let splats: MetalBuffer<EncodedSplatPoint>

    /// Optional buffer containing higher-order spherical harmonics coefficients.
    /// This is nil for SH degree 0 (view-independent color).
    /// For SH1: 9 Float16 values per splat (3 coefficients × 3 RGB)
    /// For SH2: 24 Float16 values per splat (8 coefficients × 3 RGB, cumulative)
    /// For SH3: 45 Float16 values per splat (15 coefficients × 3 RGB, cumulative)
    public let shCoefficients: MetalBuffer<Float16>?

    /// Optional texture atlas containing higher-order SH coefficients as one RGB coefficient per RGBA16Float texel.
    public let shCoefficientsTexture: (any MTLTexture)?
    public let shTextureTexelsPerSplat: Int?
    public let shTextureLayerTexelCapacity: Int?
    public let shTextureScale: SIMD3<Float>
    public let shTextureBias: SIMD3<Float>

    /// The spherical harmonics degree for this chunk.
    /// All splats in a chunk share the same SH degree.
    public let shDegree: SHDegree

    /// Number of splats in this chunk
    public var splatCount: Int { splats.count }

    /// Creates a new splat chunk with spherical harmonics support.
    /// - Parameters:
    ///   - splats: The Metal buffer containing splat data (with raw SH0 in color field)
    ///   - shCoefficients: Optional buffer with higher-order SH coefficients (nil for SH0)
    ///   - shDegree: The spherical harmonics degree for this chunk
    public init(splats: MetalBuffer<EncodedSplatPoint>,
                shCoefficients: MetalBuffer<Float16>? = nil,
                shCoefficientsTexture: (any MTLTexture)? = nil,
                shTextureTexelsPerSplat: Int? = nil,
                shTextureLayerTexelCapacity: Int? = nil,
                shTextureScale: SIMD3<Float> = .one,
                shTextureBias: SIMD3<Float> = .zero,
                shDegree: SHDegree = .sh0) {
        self.splats = splats
        self.shCoefficients = shCoefficients
        self.shCoefficientsTexture = shCoefficientsTexture
        self.shTextureTexelsPerSplat = shTextureTexelsPerSplat
        self.shTextureLayerTexelCapacity = shTextureLayerTexelCapacity
        self.shTextureScale = shTextureScale
        self.shTextureBias = shTextureBias
        self.shDegree = shDegree
    }

    /// Creates a chunk from scene points, extracting and preserving spherical harmonics data.
    /// - Parameters:
    ///   - device: Metal device for buffer allocation
    ///   - points: Array of scene points with SH data
    public init(device: MTLDevice,
                from points: [SplatPoint],
                preferSHTexture: Bool = false) throws {
        // Determine the SH degree from the data
        let shDegree = points.first?.color.shDegree ?? .sh0

        // Create splat buffer - always stores raw SH0 coefficients
        let splatBuffer = try MetalBuffer<EncodedSplatPoint>(device: device, capacity: points.count)
        splatBuffer.count = points.count

        for (i, point) in points.enumerated() {
            splatBuffer.values[i] = EncodedSplatPoint(point)
        }

        // Create SH coefficient storage if we have higher-order SH.
        // The texture path is an experiment that validates the ASTC/texture atlas access pattern.
        if shDegree > .sh0 {
            let coeffsPerSplat = shDegree.extraCoefficientCount
            if preferSHTexture,
               let astc = Self.loadASTCSHTexture(device: device, splatCount: points.count),
               let texture = astc.texture {
                self.shCoefficients = nil
                self.shCoefficientsTexture = texture
                self.shTextureTexelsPerSplat = astc.texelsPerSplat
                self.shTextureLayerTexelCapacity = astc.layerCapacity
                self.shTextureScale = astc.scale
                self.shTextureBias = astc.bias
                self.shDegree = shDegree
            } else if preferSHTexture, let texture = Self.makeSHCoefficientTexture(device: device, points: points, shDegree: shDegree) {
                self.shCoefficients = nil
                self.shCoefficientsTexture = texture
                self.shTextureTexelsPerSplat = coeffsPerSplat
                self.shTextureLayerTexelCapacity = texture.width * texture.height
                self.shTextureScale = .one
                self.shTextureBias = .zero
                self.shDegree = shDegree
            } else {
                let valuesPerSplat = coeffsPerSplat * 3  // RGB per coefficient
                let totalCoeffs = points.count * valuesPerSplat
                let shBuffer = try MetalBuffer<Float16>(device: device, capacity: totalCoeffs)
                shBuffer.count = totalCoeffs

                // Copy SH coefficients to buffer
                for (i, point) in points.enumerated() {
                    let higherOrderCoeffs = point.color.higherOrderSHCoefficients
                    let offset = i * valuesPerSplat
                    for (j, coeff) in higherOrderCoeffs.enumerated() {
                        shBuffer.values[offset + j] = Float16(coeff)
                    }
                }

                self.shCoefficients = shBuffer
                self.shCoefficientsTexture = nil
                self.shTextureTexelsPerSplat = nil
                self.shTextureLayerTexelCapacity = nil
                self.shTextureScale = .one
                self.shTextureBias = .zero
                self.shDegree = shDegree
            }
        } else {
            self.shCoefficients = nil
            self.shCoefficientsTexture = nil
            self.shTextureTexelsPerSplat = nil
            self.shTextureLayerTexelCapacity = nil
            self.shTextureScale = .one
            self.shTextureBias = .zero
            self.shDegree = .sh0
        }

        self.splats = splatBuffer
    }

    private static func makeSHCoefficientTexture(device: MTLDevice,
                                                 points: [SplatPoint],
                                                 shDegree: SHDegree) -> (any MTLTexture)? {
        let coeffsPerSplat = shDegree.extraCoefficientCount
        guard coeffsPerSplat > 0, !points.isEmpty else { return nil }
        let totalTexels = points.count * coeffsPerSplat
        let width = 8192
        let layerCapacity = width * width
        let layerCount = max(1, (totalTexels + layerCapacity - 1) / layerCapacity)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = width
        descriptor.height = width
        descriptor.arrayLength = layerCount
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = MTLStorageMode.shared
        descriptor.usage = MTLTextureUsage.shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "SH Coefficients RGBA16F Texture"

        let bytesPerPixel = MemoryLayout<PackedRGBHalf4>.stride
        var row = Array(repeating: PackedRGBHalf4(r: 0, g: 0, b: 0, a: 0), count: width)
        for layer in 0..<layerCount {
            for y in 0..<width {
                for x in 0..<width {
                    let texel = layer * layerCapacity + y * width + x
                    if texel < totalTexels {
                        let pointIndex = texel / coeffsPerSplat
                        let coeffIndex = texel % coeffsPerSplat
                        let coeffs = points[pointIndex].color.higherOrderSHCoefficients
                        let base = coeffIndex * 3
                        row[x] = PackedRGBHalf4(r: Float16(coeffs[base + 0]),
                                                g: Float16(coeffs[base + 1]),
                                                b: Float16(coeffs[base + 2]),
                                                a: 0)
                    } else {
                        row[x] = PackedRGBHalf4(r: 0, g: 0, b: 0, a: 0)
                    }
                }
                texture.replace(region: MTLRegionMake2D(0, y, width, 1),
                                mipmapLevel: 0,
                                slice: layer,
                                withBytes: row,
                                bytesPerRow: width * bytesPerPixel,
                                bytesPerImage: 0)
            }
        }
        return texture
    }

    private static func loadASTCSHTexture(device: MTLDevice,
                                          splatCount: Int) -> (texture: (any MTLTexture)?, texelsPerSplat: Int, layerCapacity: Int, scale: SIMD3<Float>, bias: SIMD3<Float>)? {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .map { $0.appendingPathComponent("bicycle500w.sh.astcbin") }
        guard let url = urls.first, let data = try? Data(contentsOf: url) else { return nil }
        let headerSize = 8 + 5 * MemoryLayout<UInt32>.size + 6 * MemoryLayout<Float>.size
        guard data.count > headerSize else { return nil }
        let magic = data.prefix(8)
        let magicString = String(decoding: magic, as: UTF8.self)
        let blockSize: Int
        switch magicString {
        case "MSHASTC4": blockSize = 4
        case "MSHASTC6": blockSize = 6
        case "MSHASTC8": blockSize = 8
        default: return nil
        }
        func u32(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
        func f32(_ offset: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) } }
        let width = Int(u32(8)), height = Int(u32(12)), layers = Int(u32(16))
        let texelsPerSplat = Int(u32(20)), layerCapacity = Int(u32(24))
        let scale = SIMD3<Float>(f32(28), f32(32), f32(36))
        let bias = SIMD3<Float>(f32(40), f32(44), f32(48))
        let payloadOffset = 52
        let expected = (width / blockSize) * (height / blockSize) * 16 * layers
        guard width > 0, height > 0, layers > 0, texelsPerSplat > 0,
              layerCapacity > 0, splatCount * texelsPerSplat <= layerCapacity * layers,
              data.count >= payloadOffset + expected else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = blockSize == 4 ? .astc_4x4_ldr : (blockSize == 6 ? .astc_6x6_ldr : .astc_8x8_ldr)
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = layers
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerRow = (width / blockSize) * 16
        let bytesPerImage = bytesPerRow * (height / blockSize)
        data.withUnsafeBytes { raw in
            for layer in 0..<layers {
                let ptr = raw.baseAddress!.advanced(by: payloadOffset + layer * bytesPerImage)
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: layer,
                                withBytes: ptr, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
            }
        }
        texture.label = "SH Coefficients ASTC 4x4 Texture"
        return (texture, texelsPerSplat, layerCapacity, scale, bias)
    }
}

/// Index into the sorted splat list, identifying both the chunk and the local splat index.
/// Uses 8 bytes for alignment (6 bytes of meaningful data).
/// Keep in sync with ShaderCommon.h : ChunkedSplatIndex
public struct ChunkedSplatIndex: Sendable {
    /// Contiguous index into the chunks array (0..<chunkCount), *not* the same as ``ChunkID``.
    public var chunkIndex: UInt16

    /// Padding for alignment
    public var _padding: UInt16

    /// Index of the splat within its chunk
    public var splatIndex: UInt32

    public init(chunkIndex: UInt16, splatIndex: UInt32) {
        self.chunkIndex = chunkIndex
        self._padding = 0
        self.splatIndex = splatIndex
    }
}
