import CoreGraphics
import Metal
import RealityKit
import simd
import SplatIO

/// Owns all buffers referenced by a RealityKit GaussianSplatResource.
/// Keep this object alive for at least as long as the entity is in the scene.
final class RealityKitSplatAsset: @unchecked Sendable {
    let entity: Entity
    let resource: GaussianSplatResource
    let splatCount: Int

    private let positionBuffer: LowLevelBuffer
    private let scaleBuffer: LowLevelBuffer
    private let rotationBuffer: LowLevelBuffer
    private let opacityBuffer: LowLevelBuffer
    private let sphericalHarmonicsBuffer: LowLevelBuffer

    @MainActor
    init(points sourcePoints: [SplatPoint], configuration: RealityKitSplatConfiguration) throws {
        let points = Self.selectPoints(sourcePoints, limit: configuration.pointLimit)
        guard let firstPoint = points.first else {
            throw RealityKitSplatBuilderError.emptyAsset
        }

        splatCount = points.count
        let sourceDegree = firstPoint.color.shDegree
        let degree = min(sourceDegree, configuration.maximumSHDegree)
        let coefficientCount = degree.coefficientCount

        positionBuffer = try Self.makeBuffer(floatCount: splatCount * 3)
        scaleBuffer = try Self.makeBuffer(floatCount: splatCount * 3)
        rotationBuffer = try Self.makeBuffer(floatCount: splatCount * 4)
        opacityBuffer = try Self.makeBuffer(floatCount: splatCount)
        sphericalHarmonicsBuffer = try Self.makeBuffer(floatCount: splatCount * coefficientCount * 3)

        Self.fill(positionBuffer) { output in
            for (index, point) in points.enumerated() {
                output[index * 3 + 0] = Self.finite(point.position.x)
                output[index * 3 + 1] = Self.finite(point.position.y)
                output[index * 3 + 2] = Self.finite(point.position.z)
            }
        }
        Self.fill(scaleBuffer) { output in
            for (index, point) in points.enumerated() {
                let scale = point.scale.asLinearFloat
                output[index * 3 + 0] = Self.finite(scale.x)
                output[index * 3 + 1] = Self.finite(scale.y)
                output[index * 3 + 2] = Self.finite(scale.z)
            }
        }
        Self.fill(rotationBuffer) { output in
            for (index, point) in points.enumerated() {
                let rotation = point.rotation.normalized
                // RealityKit documents the quaternion buffer as r, x, y, z.
                output[index * 4 + 0] = Self.finite(rotation.real)
                output[index * 4 + 1] = Self.finite(rotation.imag.x)
                output[index * 4 + 2] = Self.finite(rotation.imag.y)
                output[index * 4 + 3] = Self.finite(rotation.imag.z)
            }
        }
        Self.fill(opacityBuffer) { output in
            for (index, point) in points.enumerated() {
                output[index] = Self.finite(point.opacity.asLinearFloat)
            }
        }
        Self.fill(sphericalHarmonicsBuffer) { output in
            for (splatIndex, point) in points.enumerated() {
                let coefficients = point.color.asSphericalHarmonicFloat
                for coefficientIndex in 0..<coefficientCount {
                    let coefficient = coefficientIndex < coefficients.count ? coefficients[coefficientIndex] : .zero
                    let offset = (splatIndex * coefficientCount + coefficientIndex) * 3
                    output[offset + 0] = Self.finite(coefficient.x)
                    output[offset + 1] = Self.finite(coefficient.y)
                    output[offset + 2] = Self.finite(coefficient.z)
                }
            }
        }

        let position = Self.descriptor(positionBuffer, format: .float3, stride: 3 * MemoryLayout<Float>.stride)
        let scale = Self.descriptor(scaleBuffer, format: .float3, stride: 3 * MemoryLayout<Float>.stride)
        let rotation = Self.descriptor(rotationBuffer, format: .float4, stride: 4 * MemoryLayout<Float>.stride)
        let opacity = Self.descriptor(opacityBuffer, format: .float, stride: MemoryLayout<Float>.stride)
        let sphericalHarmonics = Self.descriptor(
            sphericalHarmonicsBuffer,
            format: .float3,
            stride: coefficientCount * 3 * MemoryLayout<Float>.stride
        )

        let bufferResource = try GaussianSplatResource.BufferResource(
            count: splatCount,
            position: position,
            scale: scale,
            rotation: rotation,
            opacity: opacity,
            sphericalHarmonics: (sphericalHarmonics, .init(rawValue: degree.rawValue) ?? .zero)
        )
        resource = GaussianSplatResource(bufferResource)
        resource.scaleActivation = .identity
        resource.opacityActivation = .identity
        resource.sortingMode = configuration.sortingMode
        resource.colorSpace = configuration.colorSpace

        entity = Entity()
        entity.name = "RealityKitGaussianSplat"
        entity.components.set(GaussianSplatComponent(resource))
    }

    private static func selectPoints(_ points: [SplatPoint], limit: Int?) -> [SplatPoint] {
        guard let limit, limit > 0, limit < points.count else { return points }
        // Deterministic evenly-spaced selection keeps benchmark runs repeatable.
        return (0..<limit).map { points[$0 * points.count / limit] }
    }

    private static func makeBuffer(floatCount: Int) throws -> LowLevelBuffer {
        let byteCount = floatCount * MemoryLayout<Float>.stride
        let alignedByteCount = (byteCount + 15) & ~15
        return try LowLevelBuffer(descriptor: .init(capacity: alignedByteCount, sizeMultiple: 16))
    }

    private static func descriptor(
        _ buffer: LowLevelBuffer,
        format: MTLAttributeFormat,
        stride: Int
    ) -> GaussianSplatResource.BufferDescriptor {
        .init(buffer: buffer, format: format, stride: stride, offset: 0)
    }

    private static func fill(_ buffer: LowLevelBuffer, body: (UnsafeMutableBufferPointer<Float>) -> Void) {
        buffer.withUnsafeMutableBytes { bytes in
            body(bytes.bindMemory(to: Float.self))
        }
    }

    private static func finite(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }
}

struct RealityKitSplatConfiguration {
    var pointLimit: Int?
    var maximumSHDegree: SHDegree = .sh3
    var sortingMode: GaussianSplatResource.SortingMode = .depth
    var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
}

enum RealityKitSplatBuilderError: LocalizedError {
    case emptyAsset

    var errorDescription: String? {
        switch self {
        case .emptyAsset: "The splat asset contains no points."
        }
    }
}
