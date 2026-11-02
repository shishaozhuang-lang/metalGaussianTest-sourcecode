import Foundation
@preconcurrency import Metal
import MetalKit
import os
import SplatIO
import Synchronization

public final class SplatRenderer: @unchecked Sendable {
    public struct PerformanceOptimizationOptions: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let sortPoseCaching = Self(rawValue: 1 << 0)
        public static let interactionSortRateLimit = Self(rawValue: 1 << 1)
        public static let cpuOpacityCulling = Self(rawValue: 1 << 2)
        public static let gpuOpacityCulling = Self(rawValue: 1 << 3)
        public static let gpuProjectedRadiusCulling = Self(rawValue: 1 << 4)
        public static let chunkTableCaching = Self(rawValue: 1 << 5)
        public static let interactionSHReduction = Self(rawValue: 1 << 6)
        public static let cpuProjectedRadiusCulling = Self(rawValue: 1 << 7)
        public static let cpuFrustumCulling = Self(rawValue: 1 << 8)
        public static let largeIndexedSplatBatches = Self(rawValue: 1 << 9)
        public static let sphericalHarmonics1 = Self(rawValue: 1 << 10)
        public static let adaptiveGPUProjectedRadiusCulling = Self(rawValue: 1 << 11)
        public static let opacityThreshold2 = Self(rawValue: 1 << 12)
        public static let opacityThreshold4 = Self(rawValue: 1 << 13)
        public static let opacityThreshold3 = Self(rawValue: 1 << 17)
        public static let opacityThreshold25 = Self(rawValue: 1 << 18)
        public static let contributionAdaptiveRadiusCulling = Self(rawValue: 1 << 14)
        public static let sphericalHarmonics0 = Self(rawValue: 1 << 15)
        public static let sphericalHarmonicsTexture = Self(rawValue: 1 << 16)
        public static let cpuVisibilityCulling: Self = [
            .cpuOpacityCulling,
            .cpuProjectedRadiusCulling,
            .cpuFrustumCulling,
        ]

        public static let all: Self = [
            .sortPoseCaching,
            .interactionSortRateLimit,
            .cpuOpacityCulling,
            .cpuFrustumCulling,
            .gpuOpacityCulling,
            .gpuProjectedRadiusCulling,
            .chunkTableCaching,
            .interactionSHReduction,
        ]

        public static let qualityPreserving: Self = [
            .sortPoseCaching,
            .interactionSortRateLimit,
            .chunkTableCaching,
        ]

        /// Mobile 540p quality/performance profile. Keeps full SH3 shading and
        /// uses the measured 4/255 opacity cutoff; expected PSNR is above 40 dB.
        public static let mobile540p: Self = [
            .all,
            .opacityThreshold4,
        ]
    }

    public enum SphericalHarmonicsQuality: UInt8, Sendable {
        case sh0 = 0
        case sh1 = 1
        case sh3 = 3
    }

    public struct PassCounterSamples {
        public var labels: [String]
        public var sampleBuffer: any MTLCounterSampleBuffer
        public var timestampFrequency: UInt64?
    }

    public struct RenderTelemetry: Sendable {
        public var totalEncodeMs: Double = 0
        public var accessWaitMs: Double = 0
        public var chunkListMs: Double = 0
        public var poseUpdateMs: Double = 0
        public var obtainSortBufferMs: Double = 0
        public var uniformsMs: Double = 0
        public var chunksBufferMs: Double = 0
        public var pipelineMs: Double = 0
        public var renderEncoderMs: Double = 0
        public var indexBufferMs: Double = 0
        public var resourceResidencyMs: Double = 0
        public var drawCallMs: Double = 0
        public var splatCount: Int = 0
        public var indexedSplatCount: Int = 0
        public var instanceCount: Int = 0
        public var chunkCount: Int = 0
        public var isMultiStage: Bool = false
    }

    private static func telemetryNowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func telemetryMs(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
    enum Constants {
        // Keep in sync with Shaders.metal : maxViewCount
        static let maxViewCount = 2
        // Sort by euclidian distance squared from camera position (true), or along the "forward" vector (false)
        // TODO: compare the behaviour and performance of sortByDistance
        // notes: sortByDistance introduces unstable artifacts when you get close to an object; whereas !sortByDistance introduces artifacts are you turn -- but they're a little subtler maybe?
        static let sortByDistance = true
        // Only store indices for 1024 splats; for the remainder, use instancing of these existing indices.
        // Setting to 1 uses only instancing (with a significant performance penalty); setting to a number higher than the splat count
        // uses only indexing (with a significant memory penalty for th elarge index array, and a small performance penalty
        // because that can't be cached as easiliy). Anywhere within an order of magnitude (or more?) of 1k seems to be the sweet spot,
        // with effectively no memory penalty compated to instancing, and slightly better performance than even using all indexing.
        static let maxIndexedSplatCount = 1024
        static let largeIndexedSplatCount = 4096

        // Chunk indices are UInt16 in ChunkedSplatIndex, so the maximum number of
        // simultaneous chunks (enabled + disabled) is UInt16.max.
        static let maxChunks = Int(UInt16.max)

        static let tileSize = MTLSize(width: 32, height: 32, depth: 1)
    }

    private static let log =
        Logger(subsystem: Bundle.module.bundleIdentifier!,
               category: "SplatRenderer")

    public struct ViewportDescriptor {
        public var viewport: MTLViewport
        public var projectionMatrix: simd_float4x4
        public var viewMatrix: simd_float4x4
        public var screenSize: SIMD2<Int>

        public init(viewport: MTLViewport, projectionMatrix: simd_float4x4, viewMatrix: simd_float4x4, screenSize: SIMD2<Int>) {
            self.viewport = viewport
            self.projectionMatrix = projectionMatrix
            self.viewMatrix = viewMatrix
            self.screenSize = screenSize
        }
    }

    // Keep in sync with Shaders.metal : BufferIndex
    enum BufferIndex: NSInteger {
        case uniforms    = 0
        case chunks      = 1
        case splatIndex  = 2
    }

    // Keep in sync with Shaders.metal : Uniforms
    struct Uniforms {
        var projectionMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
        var cameraPosition: MTLPackedFloat3   // World-space camera position for SH evaluation
        var _padding0: UInt32 = 0             // Padding for alignment
        var screenSize: SIMD2<UInt32>         // Size of screen in pixels

        // Precomputed values for covariance projection (derived from projectionMatrix and screenSize)
        var focalX: Float                     // screenSize.x * projectionMatrix[0][0] / 2
        var focalY: Float                     // screenSize.y * projectionMatrix[1][1] / 2
        var tanHalfFovX: Float                // 1 / projectionMatrix[0][0]
        var tanHalfFovY: Float                // 1 / projectionMatrix[1][1]

        var chunkCount: UInt32

        var splatCount: UInt32
        var indexedSplatCount: UInt32
        var performanceOptimizationFlags: UInt32
        var shTextureWidth: UInt32
        var shTextureTexelsPerSplat: UInt32
        var _shTexturePadding0: UInt32 = 0
        var _shTexturePadding1: UInt32 = 0
    }

    // Keep in sync with Shaders.metal : UniformsArray
    struct UniformsArray {
        // maxViewCount = 2, so we have 2 entries
        var uniforms0: Uniforms
        var uniforms1: Uniforms

        // The 256 byte aligned size of our uniform structure
        static var alignedSize: Int { (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100 }

        mutating func setUniforms(index: Int, _ uniforms: Uniforms) {
            switch index {
            case 0: uniforms0 = uniforms
            case 1: uniforms1 = uniforms
            default: break
            }
        }
    }

    // Keep in sync with Shaders.metal : ChunkInfo
    // Expected layout: splatsPointer (8), shCoefficientsPointer (8), splatCount (4), shDegree (1), enabled (1), padding (2) = 24 bytes
    struct GPUChunkInfo {
        var splatsPointer: UInt64             // device pointer to splats
        var shCoefficientsPointer: UInt64     // device pointer to SH coefficients (0 for SH0)
        var splatCount: UInt32
        var shDegree: UInt8                   // SHDegree enum value
        var enabled: UInt8                    // Non-zero = enabled for rendering
        var _shPadding: (UInt8, UInt8) = (0, 0)
    }

    public let device: MTLDevice
    public let colorFormat: MTLPixelFormat
    public let depthFormat: MTLPixelFormat
    public let sampleCount: Int
    public let maxViewCount: Int
    public let maxSimultaneousRenders: Int
    public let performanceOptimizationsEnabled: Bool
    public let performanceOptimizationOptions: PerformanceOptimizationOptions
    private let timestampCounterSet: (any MTLCounterSet)?
    private var passCounterFrameIndex = 0
    private var emptySHTexture: (any MTLTexture)?

    /**
     High-quality depth takes longer, but results in a continuous, more-representative depth buffer result, which is useful for reducing artifacts during Vision Pro's frame reprojection.
     */
    public let highQualityDepth: Bool

    /**
     The color to clear the render target to before rendering splats.
     */
    public let clearColor: MTLClearColor

    private var writeDepth: Bool {
        depthFormat != .invalid
    }

    /**
     The SplatRenderer has two shader pipelines.
     - The single stage has a vertex shader, and a fragment shader. It can produce depth (or not), but the depth it produces is the depth of the nearest splat, whether it's visible or now.
     - The multi-stage pipeline uses a set of shaders which communicate using imageblock tile memory: initialization (which clears the tile memory), draw splats (similar to the single-stage
     pipeline but the end result is tile memory, not color+depth), and a post-process stage which merely copies the tile memory (color and optionally depth) to the frame's buffers.
     This is neccessary so that the primary stage can do its own blending -- of both color and depth -- by reading the previous values and writing new ones, which isn't possible without tile
     memory. Color blending works the same as the hardcoded path, but depth blending uses color alpha and results in mostly-transparent splats contributing only slightly to the depth,
     resulting in a much more continuous and representative depth value, which is important for reprojection on Vision Pro.
     */
    private var useMultiStagePipeline: Bool {
#if targetEnvironment(simulator)
        false
#else
        writeDepth && highQualityDepth
#endif
    }

    private var maxIndexedSplatCount: Int {
        performanceOptimizationOptions.contains(.largeIndexedSplatBatches) ?
        Constants.largeIndexedSplatCount :
        Constants.maxIndexedSplatCount
    }

    private var minimumOpacity: Float {
        if performanceOptimizationOptions.contains(.opacityThreshold4) {
            return 4.0 / 255.0
        }
        if performanceOptimizationOptions.contains(.opacityThreshold3) {
            return 3.0 / 255.0
        }
        if performanceOptimizationOptions.contains(.opacityThreshold25) {
            return 2.5 / 255.0
        }
        if performanceOptimizationOptions.contains(.opacityThreshold2) {
            return 2.0 / 255.0
        }
        return 1.0 / 255.0
    }

    /// Called when a sort starts
    public var onSortStart: (@Sendable () -> Void)? {
        get { sorter.onSortStart }
        set { sorter.onSortStart = newValue }
    }
    /// Called when a sort completes. The TimeInterval is the duration of the sort.
    public var onSortComplete: (@Sendable (TimeInterval) -> Void)? {
        get { sorter.onSortComplete }
        set { sorter.onSortComplete = newValue }
    }

    /// Called after CPU-side render command encoding finishes. Used by benchmark harnesses.
    public var onRenderTelemetry: (@Sendable (RenderTelemetry) -> Void)?

    /// Called after pass timestamp counter samples have been encoded.
    /// The receiver must resolve the sample buffer after the command buffer completes.
    public var onPassCounterSamples: (@Sendable (PassCounterSamples) -> Void)?

    private let library: MTLLibrary

    // MARK: - Chunk Storage

    /// Internal storage for a chunk
    private struct ChunkEntry {
        let id: ChunkID
        var chunk: SplatChunk
        var isEnabled: Bool
    }

    private var chunks: [ChunkID: ChunkEntry] = [:]
    private var nextChunkID: UInt = 0

    /// Chunk IDs in chunk-index order: `orderedChunkIDs[i]` is the chunk at index `i`.
    /// Append-only on add; compact on remove.
    private var orderedChunkIDs: [ChunkID] = []

    /// Maps ChunkID to the contiguous chunk index used by the sorter and shaders.
    /// Rebuilt from `orderedChunkIDs` whenever chunks are added or removed.
    private var chunkIDToIndex: [ChunkID: UInt16] = [:]

    private let sorter: SplatSorter

    /// Uniform buffer storage - contains maxSimultaneousRenders uniform buffers that we round-robin through.
    private let dynamicUniformBuffers: MTLBuffer

    /// State accessed only during render() execution.
    /// Protected by serial render() enforcement via `isRendering` flag in AccessState.
    private struct RenderState {
        // Pipeline caches - lazily built, thread-safe for concurrent GPU use

        // Single-stage pipeline
        var singleStagePipelineState: MTLRenderPipelineState?
        var singleStageDepthState: MTLDepthStencilState?

        // Multi-stage pipeline
        var initializePipelineState: MTLRenderPipelineState?
        var drawSplatPipelineState: MTLRenderPipelineState?
        var drawSplatDepthState: MTLDepthStencilState?
        var postprocessPipelineState: MTLRenderPipelineState?
        var postprocessDepthState: MTLDepthStencilState?

        // Uniform buffer management - which slot in the ring buffer we're using
        var uniformBufferOffset: Int = 0
        var uniformBufferIndex: Int = 0
        var uniforms: UnsafeMutablePointer<UniformsArray>

        // Index buffer for triangle vertices (grown as needed)
        var triangleVertexIndexBuffer: MetalBuffer<UInt32>

        init(uniforms: UnsafeMutablePointer<UniformsArray>,
             triangleVertexIndexBuffer: MetalBuffer<UInt32>) {
            self.uniforms = uniforms
            self.triangleVertexIndexBuffer = triangleVertexIndexBuffer
        }
    }
    private var renderState: RenderState

    /// State for coordinating render access and chunk modifications.
    private struct AccessState: ~Copyable {
        /// Number of render operations currently in flight (submitted but not yet completed by GPU).
        var inFlightRenderCount: Int = 0
        /// When true, render() is currently executing (encoding commands). Ensures serial render execution.
        var isRendering: Bool = false
        /// When true, a caller has exclusive access for modifying chunks.
        var hasExclusiveAccess: Bool = false
        /// Queue of continuations waiting for exclusive access. First waiter gets access next.
        var exclusiveAccessWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let accessState: Mutex<AccessState>

    private var cachedChunksBuffer: MTLBuffer?
    private var chunksBufferDirty = true
    private struct QualityState {
        var requested: SphericalHarmonicsQuality = .sh3
        var isInteracting = false
    }
    private let qualityState = Mutex(QualityState())

    /// Selects the maximum SH band evaluated by the shader. During interaction
    /// `.sh3` automatically falls back to SH1 and returns to SH3 on release.
    public var sphericalHarmonicsQuality: SphericalHarmonicsQuality {
        get { qualityState.withLock { $0.requested } }
        set {
            qualityState.withLock { $0.requested = newValue }
            chunksBufferDirty = true
        }
    }

    /// Lets clients rate-limit sorting while a camera gesture is in progress.
    public func setCameraInteractionActive(_ active: Bool) {
        qualityState.withLock { $0.isInteracting = active }
        chunksBufferDirty = true
        sorter.setInteractionActive(active)
    }

    /// Returns true if exclusive access is currently held. Used for precondition checks.
    private var hasExclusiveAccess: Bool {
        accessState.withLock { $0.hasExclusiveAccess }
    }

    /// Returns true if the renderer is likely ready to render successfully.
    /// Check this before acquiring a drawable to avoid wasting frames.
    public var isReadyToRender: Bool {
        accessState.withLock { state in
            !state.hasExclusiveAccess &&
            state.exclusiveAccessWaiters.isEmpty &&
            !state.isRendering &&
            state.inFlightRenderCount < maxSimultaneousRenders
        }
    }

    /// Total splat count across all enabled chunks
    public var splatCount: Int {
        chunks.values
            .filter { $0.isEnabled }
            .reduce(0) { $0 + $1.chunk.splatCount }
    }

    /// Registers a one-shot handler to be called after the next successful sort completes.
    /// Use this to wait until a newly-added chunk has been included in a valid sorted index buffer
    /// before enabling it, to avoid visual glitches.
    public func afterNextSort(_ handler: @escaping @Sendable () -> Void) {
        sorter.addSortCompletionHandler(handler)
    }

    public init(device: MTLDevice,
                colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat,
                sampleCount: Int,
                maxViewCount: Int,
                maxSimultaneousRenders: Int,
                performanceOptimizationsEnabled: Bool = true,
                performanceOptimizationOptions: PerformanceOptimizationOptions? = nil,
                highQualityDepth: Bool = true,
                clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) throws {
#if arch(x86_64)
        fatalError("MetalSplatter is unsupported on Intel architecture (x86_64)")
#endif

        self.device = device

        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.sampleCount = sampleCount
        self.maxViewCount = min(maxViewCount, Constants.maxViewCount)
        self.maxSimultaneousRenders = maxSimultaneousRenders
        self.performanceOptimizationOptions = performanceOptimizationOptions ?? (performanceOptimizationsEnabled ? .all : [])
        self.performanceOptimizationsEnabled = !self.performanceOptimizationOptions.isEmpty
        self.timestampCounterSet = device.counterSets?.first { $0.name == MTLCommonCounterSet.timestamp.rawValue }
        self.highQualityDepth = highQualityDepth
        self.clearColor = clearColor

        let dynamicUniformBuffersSize = UniformsArray.alignedSize * maxSimultaneousRenders
        self.dynamicUniformBuffers = device.makeBuffer(length: dynamicUniformBuffersSize,
                                                       options: .storageModeShared)!
        self.dynamicUniformBuffers.label = "Uniform Buffers"

        let uniformsPointer = UnsafeMutableRawPointer(dynamicUniformBuffers.contents())
            .bindMemory(to: UniformsArray.self, capacity: 1)
        let triangleVertexIndexBuffer = try MetalBuffer<UInt32>(device: device)
        self.renderState = RenderState(uniforms: uniformsPointer,
                                        triangleVertexIndexBuffer: triangleVertexIndexBuffer)

        self.sorter = try SplatSorter(device: device,
                                      performanceOptimizationOptions: self.performanceOptimizationOptions)

        self.accessState = Mutex(AccessState())

        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            // `swift build` copies .metal package resources but, unlike an
            // Xcode application build, may not emit a default.metallib.
            // Compile the bundled sources at runtime as a portable fallback.
            library = try Self.makeBundledSourceLibrary(device: device)
        }
    }

    private static func makeBundledSourceLibrary(device: MTLDevice) throws -> MTLLibrary {
        func resource(_ name: String, _ extensionName: String) throws -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: extensionName) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        let common = try resource("ShaderCommon", "h")
        let declarations = try resource("SplatProcessing", "h")
            .replacingOccurrences(of: "#import \"ShaderCommon.h\"", with: "")
        let sourceNames = ["SplatProcessing", "SingleStageRenderPath", "MultiStageRenderPath"]
        let implementations = try sourceNames.map { name in
            try resource(name, "metal")
                .replacingOccurrences(of: "#import \"SplatProcessing.h\"", with: "")
                .replacingOccurrences(of: "#include \"SplatProcessing.h\"", with: "")
        }
        return try device.makeLibrary(
            source: ([common, declarations] + implementations).joined(separator: "\n"),
            options: nil
        )
    }

    // MARK: - Chunk Management

    /// Adds a chunk to the renderer. The chunk should not be modified after this method returns, except during withChunkAccess {...}.
    ///
    /// Disabled chunks participate in sorting but are not rendered. Adding a chunk as disabled
    /// prepares it for instant future enabling: once a background sort cycle completes, enabling
    /// takes effect on the very next frame with no visual glitches. For instance, this could allow a
    /// seamless switch between two alternative versions of a chunk.
    ///
    /// There is a performance cost to including chunks even if they're disabled: their splats are sorted every cycle (CPU) and
    /// processed by the vertex shader every frame (GPU), proportional to the disabled chunk's splat count.
    ///
    /// - Parameters:
    ///   - chunk: The chunk to add
    ///   - sortByLocality: If true (the default), reorders splats by Morton code to improve cache performance during rendering.
    ///     Set to false if you need to preserve the original splat ordering, or if you'd like to control performance by calling
    ///     SplatChunk.sortByLocality() yourself prior to calling this method.
    ///   - enabled: Whether the chunk should be rendered immediately. Defaults to true.
    /// - Returns: The assigned chunk ID
    @discardableResult
    public func addChunk(_ chunk: SplatChunk, sortByLocality: Bool = true, enabled: Bool = true) async -> ChunkID {
        // The current locality sorter only reorders buffers. If SH data is stored
        // in a texture atlas, splatIndex is also the linear texture index, so keep
        // splats in their original order unless texture reordering is implemented.
        if sortByLocality && chunk.shCoefficientsTexture == nil {
            chunk.sortByLocality()
        }

        return await withChunkAccess {
            if orderedChunkIDs.count >= Constants.maxChunks {
                Self.log.warning("Maximum chunk count (\(Constants.maxChunks)) exceeded; chunk will not be added")
                let id = ChunkID(rawValue: nextChunkID)
                nextChunkID += 1
                return id
            }

            let id = ChunkID(rawValue: nextChunkID)
            nextChunkID += 1

            chunks[id] = ChunkEntry(
                id: id,
                chunk: chunk,
                isEnabled: enabled
            )

            orderedChunkIDs.append(id)
            let chunkIndex = UInt16(orderedChunkIDs.count - 1)
            chunkIDToIndex[id] = chunkIndex
            chunksBufferDirty = true

            try? sorter.addChunkToSort(SplatSorter.ChunkReference(
                chunkIndex: chunkIndex,
                buffer: chunk.splats
            ))
            return id
        }
    }

    /// Removes a chunk from the renderer.
    /// - Parameter id: The chunk ID to remove
    public func removeChunk(_ id: ChunkID) async {
        await withChunkAccess {
            guard let removedIndex = chunkIDToIndex[id] else { return }
            chunks.removeValue(forKey: id)
            chunksBufferDirty = true
            orderedChunkIDs.removeAll { $0 == id }

            // Rebuild chunkIDToIndex from orderedChunkIDs
            chunkIDToIndex.removeAll()
            var indexMapping: [UInt16: UInt16] = [:]
            for (newIdx, chunkID) in orderedChunkIDs.enumerated() {
                let newChunkIndex = UInt16(newIdx)
                // The old index for this chunk was its previous position;
                // find it from the fact that positions after removedIndex shift down
                let oldIdx = UInt16(newIdx) >= removedIndex ? UInt16(newIdx) + 1 : UInt16(newIdx)
                chunkIDToIndex[chunkID] = newChunkIndex
                indexMapping[oldIdx] = newChunkIndex
            }

            try? sorter.removeChunkFromSort(removedChunkIndex: removedIndex, indexMapping: indexMapping)
        }
    }

    /// Removes all chunks from the renderer.
    public func removeAllChunks() async {
        await withChunkAccess {
            chunks.removeAll()
            chunksBufferDirty = true
            orderedChunkIDs.removeAll()
            chunkIDToIndex.removeAll()
            sorter.setChunks([])
        }
    }

    /// Enables or disables a chunk for rendering.
    ///
    /// This does not interact with the sorter — disabled chunks continue to participate
    /// in sorting. The enabled flag takes effect on the next render() call via the GPU
    /// chunk table. This makes enable/disable instant with no sort latency.
    ///
    /// - Parameters:
    ///   - id: The chunk ID
    ///   - enabled: Whether the chunk should be rendered
    public func setChunkEnabled(_ id: ChunkID, enabled: Bool) async {
        await withChunkAccess {
            chunks[id]?.isEnabled = enabled
            chunksBufferDirty = true
        }
    }

    /// Returns whether a chunk is enabled.
    /// - Parameter id: The chunk ID
    /// - Returns: true if the chunk is enabled, false otherwise
    public func isChunkEnabled(_ id: ChunkID) -> Bool {
        chunks[id]?.isEnabled ?? false
    }


    // MARK: - Chunk Access

    @TaskLocal private static var _insideChunkAccess = false

    /// Provides exclusive access to modify chunks.
    ///
    /// This method ensures that no renders are in flight before executing the body,
    /// and prevents new renders from starting until the body completes.
    /// The calling task suspends (without blocking a thread) until exclusive access is available.
    /// Multiple concurrent callers are queued and granted access in order.
    ///
    /// This method is reentrant: calling chunk-management methods (e.g. ``addChunk(_:sortByLocality:enabled:)``,
    /// ``removeChunk(_:)``, ``setChunkEnabled(_:enabled:)``) from within the body is safe and avoids
    /// re-acquiring the lock. This allows multiple operations to execute atomically with respect to rendering.
    public func withChunkAccess<T>(_ body: () async throws -> T) async rethrows -> T {
        if Self._insideChunkAccess {
            return try await body()
        }

        await withCheckedContinuation { continuation in
            let readyNow = accessState.withLock { state -> Bool in
                if !state.hasExclusiveAccess &&
                    state.exclusiveAccessWaiters.isEmpty &&
                    state.inFlightRenderCount == 0 {
                    state.hasExclusiveAccess = true
                    return true
                }
                state.exclusiveAccessWaiters.append(continuation)
                return false
            }
            if readyNow {
                continuation.resume()
            }
        }

        defer {
            let nextWaiter = accessState.withLock { state -> CheckedContinuation<Void, Never>? in
                if !state.exclusiveAccessWaiters.isEmpty && state.inFlightRenderCount == 0 {
                    // Pass access directly to next waiter (hasExclusiveAccess stays true)
                    return state.exclusiveAccessWaiters.removeFirst()
                }
                state.hasExclusiveAccess = false
                return nil
            }
            nextWaiter?.resume()
        }

        return try await Self.$_insideChunkAccess.withValue(true) {
            try await body()
        }
    }

    /// Called when a render's command buffer completes on the GPU.
    private func renderCompleted() {
        let waiter = accessState.withLock { state -> CheckedContinuation<Void, Never>? in
            state.inFlightRenderCount -= 1
            if state.inFlightRenderCount == 0 && !state.hasExclusiveAccess && !state.exclusiveAccessWaiters.isEmpty {
                state.hasExclusiveAccess = true
                return state.exclusiveAccessWaiters.removeFirst()
            }
            return nil
        }
        waiter?.resume()
    }

    // MARK: - Pipeline State Building

    private func resetPipelineStates() {
        renderState.singleStagePipelineState = nil
        renderState.initializePipelineState = nil
        renderState.drawSplatPipelineState = nil
        renderState.drawSplatDepthState = nil
        renderState.postprocessPipelineState = nil
        renderState.postprocessDepthState = nil
    }

    private func buildSingleStagePipelineStatesIfNeeded() throws {
        guard renderState.singleStagePipelineState == nil else { return }

        renderState.singleStagePipelineState = try buildSingleStagePipelineState()
        renderState.singleStageDepthState = try buildSingleStageDepthState()
    }

    private func buildMultiStagePipelineStatesIfNeeded() throws {
        guard renderState.initializePipelineState == nil else { return }

        renderState.initializePipelineState = try buildInitializePipelineState()
        renderState.drawSplatPipelineState = try buildDrawSplatPipelineState()
        renderState.drawSplatDepthState = try buildDrawSplatDepthState()
        renderState.postprocessPipelineState = try buildPostprocessPipelineState()
        renderState.postprocessDepthState = try buildPostprocessDepthState()
    }

    private func buildSingleStagePipelineState() throws -> MTLRenderPipelineState {
        assert(!useMultiStagePipeline)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        pipelineDescriptor.label = "SingleStagePipeline"
        pipelineDescriptor.vertexFunction = library.makeRequiredFunction(name: "singleStageSplatVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeRequiredFunction(name: "singleStageSplatFragmentShader")

        pipelineDescriptor.rasterSampleCount = sampleCount

        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = colorFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .one
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0] = colorAttachment

        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func buildSingleStageDepthState() throws -> MTLDepthStencilState {
        assert(!useMultiStagePipeline)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = writeDepth
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    private func buildInitializePipelineState() throws -> MTLRenderPipelineState {
        assert(useMultiStagePipeline)

        let pipelineDescriptor = MTLTileRenderPipelineDescriptor()

        pipelineDescriptor.label = "InitializePipeline"
        pipelineDescriptor.tileFunction = library.makeRequiredFunction(name: "initializeFragmentStore")
        pipelineDescriptor.threadgroupSizeMatchesTileSize = true;
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat

        return try device.makeRenderPipelineState(tileDescriptor: pipelineDescriptor, options: [], reflection: nil)
    }

    private func buildDrawSplatPipelineState() throws -> MTLRenderPipelineState {
        assert(useMultiStagePipeline)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        pipelineDescriptor.label = "DrawSplatPipeline"
        pipelineDescriptor.vertexFunction = library.makeRequiredFunction(name: "multiStageSplatVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeRequiredFunction(name: "multiStageSplatFragmentShader")

        pipelineDescriptor.rasterSampleCount = sampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func buildDrawSplatDepthState() throws -> MTLDepthStencilState {
        assert(useMultiStagePipeline)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = writeDepth
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    private func buildPostprocessPipelineState() throws -> MTLRenderPipelineState {
        assert(useMultiStagePipeline)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        pipelineDescriptor.label = "PostprocessPipeline"
        pipelineDescriptor.vertexFunction =
            library.makeRequiredFunction(name: "postprocessVertexShader")
        pipelineDescriptor.fragmentFunction =
            writeDepth
            ? library.makeRequiredFunction(name: "postprocessFragmentShader")
            : library.makeRequiredFunction(name: "postprocessFragmentShaderNoDepth")

        pipelineDescriptor.colorAttachments[0]!.pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func buildPostprocessDepthState() throws -> MTLDepthStencilState {
        assert(useMultiStagePipeline)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = writeDepth
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    private func switchToNextDynamicBuffer() {
        renderState.uniformBufferIndex = (renderState.uniformBufferIndex + 1) % maxSimultaneousRenders
        renderState.uniformBufferOffset = UniformsArray.alignedSize * renderState.uniformBufferIndex
        renderState.uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents() + renderState.uniformBufferOffset).bindMemory(to: UniformsArray.self, capacity: 1)
    }

    private func updateUniforms(forViewports viewports: [ViewportDescriptor],
                                chunkCount: UInt32,
                                splatCount: UInt32,
                                indexedSplatCount: UInt32,
                                shTextureWidth: UInt32,
                                shTextureTexelsPerSplat: UInt32,
                                shTextureASTC: UInt32) {
        // Compute average camera position from all viewports
        let cameraPos = viewports.map { Self.cameraWorldPosition(forViewMatrix: $0.viewMatrix) }.mean ?? .zero

        for (i, viewport) in viewports.enumerated() where i <= maxViewCount {
            // Precompute values for covariance projection
            let proj00 = viewport.projectionMatrix[0][0]
            let proj11 = viewport.projectionMatrix[1][1]
            let focalX = Float(viewport.screenSize.x) * proj00 / 2
            let focalY = Float(viewport.screenSize.y) * proj11 / 2
            let tanHalfFovX = 1 / proj00
            let tanHalfFovY = 1 / proj11

            let uniforms = Uniforms(projectionMatrix: viewport.projectionMatrix,
                                    viewMatrix: viewport.viewMatrix,
                                    cameraPosition: MTLPackedFloat3Make(cameraPos.x, cameraPos.y, cameraPos.z),
                                    screenSize: SIMD2(x: UInt32(viewport.screenSize.x), y: UInt32(viewport.screenSize.y)),
                                    focalX: focalX,
                                    focalY: focalY,
                                    tanHalfFovX: tanHalfFovX,
                                    tanHalfFovY: tanHalfFovY,
                                    chunkCount: chunkCount,
                                    splatCount: splatCount,
                                    indexedSplatCount: indexedSplatCount,
                                    performanceOptimizationFlags: performanceOptimizationOptions.rawValue,
                                    shTextureWidth: shTextureWidth,
                                    shTextureTexelsPerSplat: shTextureTexelsPerSplat,
                                    _shTexturePadding0: shTextureASTC,
                                    _shTexturePadding1: 0)
            renderState.uniforms.pointee.setUniforms(index: i, uniforms)
        }
    }

    /// Computes the mean camera world position and forward vector from the given viewports.
    private static func cameraWorldPose(forViewports viewports: [ViewportDescriptor]) -> (position: SIMD3<Float>, forward: SIMD3<Float>) {
        let position = viewports.map { cameraWorldPosition(forViewMatrix: $0.viewMatrix) }.mean ?? .zero
        let forward = viewports.map { cameraWorldForward(forViewMatrix: $0.viewMatrix) }.mean?.normalized ?? .init(x: 0, y: 0, z: -1)
        return (position, forward)
    }

    private static func cameraWorldForward(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: -1, w: 0)).xyz
    }

    private static func cameraWorldPosition(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: 0, w: 1)).xyz
    }

    // MARK: - Chunk Table Building

    private func shTextureWidth(for allChunks: [ChunkEntry]) -> UInt32 {
        guard performanceOptimizationOptions.contains(.sphericalHarmonicsTexture),
              allChunks.count == 1,
              let texture = allChunks.first?.chunk.shCoefficientsTexture else { return 0 }
        return UInt32(texture.width)
    }

    private func shTextureTexelsPerSplat(for allChunks: [ChunkEntry]) -> UInt32 {
        guard performanceOptimizationOptions.contains(.sphericalHarmonicsTexture),
              allChunks.count == 1,
              let texelsPerSplat = allChunks.first?.chunk.shTextureTexelsPerSplat else { return 0 }
        return UInt32(texelsPerSplat)
    }


    private func shTexture(for allChunks: [ChunkEntry]) -> (any MTLTexture)? {
        guard performanceOptimizationOptions.contains(.sphericalHarmonicsTexture),
              allChunks.count == 1 else { return nil }
        return allChunks.first?.chunk.shCoefficientsTexture
    }

    private func textureForSHBinding(_ texture: (any MTLTexture)?) -> (any MTLTexture)? {
        if let texture { return texture }
        if let emptySHTexture { return emptySHTexture }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = 1
        descriptor.height = 1
        descriptor.arrayLength = 1
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        emptySHTexture = device.makeTexture(descriptor: descriptor)
        return emptySHTexture
    }

    private func makePassCounterSampleBuffer(sampleCount: Int) -> (any MTLCounterSampleBuffer)? {
        guard onPassCounterSamples != nil, let timestampCounterSet else { return nil }
        guard device.supportsCounterSampling(.atStageBoundary) else { return nil }
        passCounterFrameIndex += 1
        guard passCounterFrameIndex <= 10 || passCounterFrameIndex % 30 == 0 else { return nil }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = timestampCounterSet
        descriptor.storageMode = .shared
        descriptor.sampleCount = sampleCount
        descriptor.label = "SplatRenderer Pass Timestamp Counters"
        return try? device.makeCounterSampleBuffer(descriptor: descriptor)
    }

    private func buildChunksBuffer(allChunks: [ChunkEntry]) -> MTLBuffer? {
        if performanceOptimizationOptions.contains(.chunkTableCaching), !chunksBufferDirty, let cachedChunksBuffer { return cachedChunksBuffer }
        let chunkInfoSize = MemoryLayout<GPUChunkInfo>.stride
        let requiredSize = max(1, allChunks.count * chunkInfoSize)

        // Try to reuse a pooled buffer; allocate only if nil or too small
        let buffer: MTLBuffer
        // A dirty table may coexist with in-flight command buffers. Allocate a
        // new immutable snapshot instead of rewriting their shared buffer.
        guard let newBuffer = device.makeBuffer(length: requiredSize, options: .storageModeShared) else {
            return nil
        }
        newBuffer.label = "Chunks"
        buffer = newBuffer

        let chunksPtr = buffer.contents().assumingMemoryBound(to: GPUChunkInfo.self)
        let quality = qualityState.withLock { state -> SphericalHarmonicsQuality in
            if performanceOptimizationOptions.contains(.sphericalHarmonics0) {
                return .sh0
            }
            if performanceOptimizationOptions.contains(.sphericalHarmonics1), state.requested == .sh3 {
                return .sh1
            }
            return performanceOptimizationOptions.contains(.interactionSHReduction) && state.isInteracting && state.requested == .sh3 ? .sh1 : state.requested
        }
        for (chunkIndex, entry) in allChunks.enumerated() {
            let shPointer = entry.chunk.shCoefficients?.buffer.gpuAddress ?? 0

            chunksPtr[chunkIndex] = GPUChunkInfo(
                splatsPointer: entry.chunk.splats.buffer.gpuAddress,
                shCoefficientsPointer: shPointer,
                splatCount: UInt32(entry.chunk.splatCount),
                shDegree: min(entry.chunk.shDegree.rawValue, quality.rawValue),
                enabled: entry.isEnabled ? 1 : 0
            )
        }

        cachedChunksBuffer = buffer
        chunksBufferDirty = false
        return buffer
    }

    func renderEncoder(multiStage: Bool,
                       viewports: [ViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       passCounterBuffer: (any MTLCounterSampleBuffer)?,
                       for commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = colorTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = colorStoreAction
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        if let depthTexture {
            renderPassDescriptor.depthAttachment.texture = depthTexture
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.storeAction = .store
            renderPassDescriptor.depthAttachment.clearDepth = 0.0
        }
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = renderTargetArrayLength
        if let passCounterBuffer,
           let sampleAttachment = renderPassDescriptor.sampleBufferAttachments[0] {
            sampleAttachment.sampleBuffer = passCounterBuffer
            sampleAttachment.startOfVertexSampleIndex = 0
            sampleAttachment.endOfVertexSampleIndex = 1
            sampleAttachment.startOfFragmentSampleIndex = 2
            sampleAttachment.endOfFragmentSampleIndex = 3
        }

        renderPassDescriptor.tileWidth  = Constants.tileSize.width
        renderPassDescriptor.tileHeight = Constants.tileSize.height

        if multiStage {
            if let initializePipelineState = renderState.initializePipelineState {
                renderPassDescriptor.imageblockSampleLength = initializePipelineState.imageblockSampleLength
            } else {
                Self.log.error("initializePipeline == nil in renderEncoder()")
            }
        }

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }

        renderEncoder.label = "Primary Render Encoder"

        renderEncoder.setViewports(viewports.map(\.viewport))

        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        return renderEncoder
    }

    /// Renders the gaussian splats to the given command buffer.
    ///
    /// - Parameters:
    ///   - viewports: The viewport descriptors for rendering (supports multiple viewports for stereo on visionOS)
    ///   - colorTexture: The texture to render color output to
    ///   - colorStoreAction: The store action for the color attachment
    ///   - depthTexture: Optional depth texture for depth output
    ///   - rasterizationRateMap: Optional rasterization rate map for variable rate shading
    ///   - renderTargetArrayLength: The render target array length (for layered rendering)
    ///   - accessTimeout: Maximum time to block waiting for render access (when exclusive chunk access is held, or when maxSimultaneousRenders are already in flight). Defaults to 0.1s.
    ///   - sortTimeout: Maximum time to block the caller in order to wait for a valid sorted index buffer to be available. This does not cause the method to wait for the latest sort to complete, it only causes it to block if no sort at all has completed since the last time the sort was invalidated (e.g. if chunks were changed). Passing 0 disables blocking, but may result in a flash after a chunk update instead of a dropped frame. Defaults to blocking 0.1s.
    ///   - commandBuffer: The command buffer to encode rendering commands into
    /// - Returns: `true` if rendering was performed, `false` if rendering was skipped (e.g., due to exclusive access timeout or no splats). When `false` is returned, the caller should drop the frame rather than presenting an incomplete render.
    @discardableResult
    public func render(viewports: [ViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       accessTimeout: TimeInterval = 0.1,
                       sortTimeout: TimeInterval = 0.1,
                       to commandBuffer: MTLCommandBuffer) throws -> Bool {
        let totalStart = Self.telemetryNowNs()
        var telemetry = RenderTelemetry()

        // Try to acquire render access, respecting exclusive access, serial render, and maxSimultaneousRenders
        let accessStart = Self.telemetryNowNs()
        let deadline = Date().addingTimeInterval(accessTimeout)
        while true {
            let acquired = accessState.withLock { state -> Bool in
                if state.hasExclusiveAccess {
                    return false
                }
                // If chunk-access waiters exist, stop admitting new renders so
                // in-flight work can drain to zero and exclusive access can proceed.
                if !state.exclusiveAccessWaiters.isEmpty {
                    return false
                }
                if state.isRendering {
                    return false  // Another render() is in progress - enforce serial execution
                }
                if state.inFlightRenderCount >= maxSimultaneousRenders {
                    return false
                }
                state.isRendering = true
                state.inFlightRenderCount += 1
                return true
            }
            if acquired {
                break
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        telemetry.accessWaitMs = Self.telemetryMs(since: accessStart)

        var renderCompletionScheduled = false
        defer {
            accessState.withLock { state in
                state.isRendering = false
            }
            if !renderCompletionScheduled {
                renderCompleted()
            }
        }

        // Build ordered list of all chunks (enabled + disabled); array index = chunk index
        let chunkListStart = Self.telemetryNowNs()
        let allChunks: [ChunkEntry] = orderedChunkIDs.compactMap { chunks[$0] }
        telemetry.chunkCount = allChunks.count
        telemetry.chunkListMs = Self.telemetryMs(since: chunkListStart)
        assert(allChunks.count == orderedChunkIDs.count)
        assert(allChunks.count == chunkIDToIndex.count)

        // Compute camera pose for sorting
        let poseStart = Self.telemetryNowNs()
        let cameraPose = Self.cameraWorldPose(forViewports: viewports)
        let primaryViewport = viewports[0]
        sorter.updateCameraPose(
            position: cameraPose.position,
            forward: cameraPose.forward,
            visibility: .init(viewProjection: primaryViewport.projectionMatrix * primaryViewport.viewMatrix,
                              screenSize: SIMD2(Float(primaryViewport.screenSize.x), Float(primaryViewport.screenSize.y)),
                              minimumOpacity: minimumOpacity,
                              cullingFlags: performanceOptimizationOptions.intersection(.cpuVisibilityCulling).rawValue))
        telemetry.poseUpdateMs = Self.telemetryMs(since: poseStart)

        // Try to get sorted indices, optionally waiting up to sortTimeout
        let sortBufferStart = Self.telemetryNowNs()
        var splatIndexBuffer = sorter.tryObtainSortedIndices()
        if splatIndexBuffer == nil && sortTimeout > 0 {
            let deadline = Date().addingTimeInterval(sortTimeout)
            while splatIndexBuffer == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
                splatIndexBuffer = sorter.tryObtainSortedIndices()
            }
        }
        telemetry.obtainSortBufferMs = Self.telemetryMs(since: sortBufferStart)
        guard let splatIndexBuffer else { return false }

        commandBuffer.addCompletedHandler { [sorter, weak self] _ in
            self?.renderCompleted()

            // Retain the splatIndexBuffer alive until GPU completion so it won't
            // be reused by the sorter while we're still using it
            sorter.releaseSortedIndices(splatIndexBuffer)
        }
        renderCompletionScheduled = true

        let splatCount = splatIndexBuffer.count
        guard splatCount != 0 else { return false }

        let indexedSplatCount = min(splatCount, maxIndexedSplatCount)
        let instanceCount = (splatCount + indexedSplatCount - 1) / indexedSplatCount
        telemetry.splatCount = splatCount
        telemetry.indexedSplatCount = indexedSplatCount
        telemetry.instanceCount = instanceCount

        let uniformsStart = Self.telemetryNowNs()
        switchToNextDynamicBuffer()
        let activeSHTextureWidth = shTextureWidth(for: allChunks)
        let activeSHTextureTexelsPerSplat = shTextureTexelsPerSplat(for: allChunks)
        let activeSHTextureASTC: UInt32 = {
            guard let format = shTexture(for: allChunks)?.pixelFormat else { return 0 }
            switch format {
            case .astc_4x4_ldr, .astc_6x6_ldr, .astc_8x8_ldr: return 1
            default: return 0
            }
        }()
        updateUniforms(forViewports: viewports,
                       chunkCount: UInt32(allChunks.count),
                       splatCount: UInt32(splatCount),
                       indexedSplatCount: UInt32(indexedSplatCount),
                       shTextureWidth: activeSHTextureWidth,
                       shTextureTexelsPerSplat: activeSHTextureTexelsPerSplat,
                       shTextureASTC: activeSHTextureASTC)
        telemetry.uniformsMs = Self.telemetryMs(since: uniformsStart)

        // Build chunks buffer (from pool if available) — includes all chunks with enabled flag
        let chunksBufferStart = Self.telemetryNowNs()
        guard let chunksBuffer = buildChunksBuffer(allChunks: allChunks) else {
            return false
        }
        telemetry.chunksBufferMs = Self.telemetryMs(since: chunksBufferStart)

        let multiStage = useMultiStagePipeline
        telemetry.isMultiStage = multiStage
        let pipelineStart = Self.telemetryNowNs()
        if multiStage {
            try buildMultiStagePipelineStatesIfNeeded()
        } else {
            try buildSingleStagePipelineStatesIfNeeded()
        }
        telemetry.pipelineMs = Self.telemetryMs(since: pipelineStart)

        let passCounterBuffer = makePassCounterSampleBuffer(sampleCount: 4)
        let passCounterLabels = ["start_vertex", "end_vertex", "start_fragment", "end_fragment"]

        let renderEncoderStart = Self.telemetryNowNs()
        let renderEncoder = renderEncoder(multiStage: multiStage,
                                          viewports: viewports,
                                          colorTexture: colorTexture,
                                          colorStoreAction: colorStoreAction,
                                          depthTexture: depthTexture,
                                          rasterizationRateMap: rasterizationRateMap,
                                          renderTargetArrayLength: renderTargetArrayLength,
                                          passCounterBuffer: passCounterBuffer,
                                          for: commandBuffer)
        telemetry.renderEncoderMs = Self.telemetryMs(since: renderEncoderStart)

        let indexBufferStart = Self.telemetryNowNs()
        let triangleVertexCount = indexedSplatCount * 6
        if renderState.triangleVertexIndexBuffer.count < triangleVertexCount {
            do {
                try renderState.triangleVertexIndexBuffer.ensureCapacity(triangleVertexCount)
            } catch {
                return false
            }
            renderState.triangleVertexIndexBuffer.count = triangleVertexCount
            for i in 0..<indexedSplatCount {
                renderState.triangleVertexIndexBuffer.values[i * 6 + 0] = UInt32(i * 4 + 0)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 1] = UInt32(i * 4 + 1)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 2] = UInt32(i * 4 + 2)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 3] = UInt32(i * 4 + 1)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 4] = UInt32(i * 4 + 2)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 5] = UInt32(i * 4 + 3)
            }
        }
        telemetry.indexBufferMs = Self.telemetryMs(since: indexBufferStart)

        if multiStage {
            guard let initializePipelineState = renderState.initializePipelineState,
                  let drawSplatPipelineState = renderState.drawSplatPipelineState
            else { return false }

            renderEncoder.pushDebugGroup("Initialize")
            renderEncoder.setRenderPipelineState(initializePipelineState)
            renderEncoder.dispatchThreadsPerTile(Constants.tileSize)
            renderEncoder.popDebugGroup()

            renderEncoder.pushDebugGroup("Draw Splats")
            renderEncoder.setRenderPipelineState(drawSplatPipelineState)
            renderEncoder.setDepthStencilState(renderState.drawSplatDepthState)
        } else {
            guard let singleStagePipelineState = renderState.singleStagePipelineState
            else { return false }

            renderEncoder.pushDebugGroup("Draw Splats")
            renderEncoder.setRenderPipelineState(singleStagePipelineState)
            renderEncoder.setDepthStencilState(renderState.singleStageDepthState)
        }

        renderEncoder.setVertexBuffer(dynamicUniformBuffers, offset: renderState.uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(chunksBuffer, offset: 0, index: BufferIndex.chunks.rawValue)
        renderEncoder.setVertexBuffer(splatIndexBuffer.buffer, offset: 0, index: BufferIndex.splatIndex.rawValue)
        // Keep texture(0) bound for every pipeline variant so GPU capture
        // validation sees a complete resource layout when SH uses a buffer.
        renderEncoder.setVertexTexture(textureForSHBinding(shTexture(for: allChunks)), index: 0)

        let resourceResidencyStart = Self.telemetryNowNs()
        // Make splat and SH coefficient buffers resident for all chunks (enabled + disabled).
        // The shader may briefly access disabled chunks' pointers before the enabled check.
        for entry in allChunks {
            renderEncoder.useResource(entry.chunk.splats.buffer, usage: .read, stages: .vertex)
            if let shBuffer = entry.chunk.shCoefficients?.buffer {
                renderEncoder.useResource(shBuffer, usage: .read, stages: .vertex)
            }
            if let shTexture = entry.chunk.shCoefficientsTexture {
                renderEncoder.useResource(shTexture, usage: .read, stages: .vertex)
            }
        }
        telemetry.resourceResidencyMs = Self.telemetryMs(since: resourceResidencyStart)

        let drawCallStart = Self.telemetryNowNs()
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: triangleVertexCount,
                                            indexType: .uint32,
                                            indexBuffer: renderState.triangleVertexIndexBuffer.buffer,
                                            indexBufferOffset: 0,
                                            instanceCount: instanceCount)
        telemetry.drawCallMs = Self.telemetryMs(since: drawCallStart)

        if multiStage {
            guard let postprocessPipelineState = renderState.postprocessPipelineState
            else { return false }

            renderEncoder.popDebugGroup()

            renderEncoder.pushDebugGroup("Postprocess")
            renderEncoder.setRenderPipelineState(postprocessPipelineState)
            renderEncoder.setDepthStencilState(renderState.postprocessDepthState)
            renderEncoder.setCullMode(.none)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.popDebugGroup()
        } else {
            renderEncoder.popDebugGroup()
        }

        renderEncoder.endEncoding()
        if let passCounterBuffer, let onPassCounterSamples {
            commandBuffer.addCompletedHandler { _ in
                onPassCounterSamples(PassCounterSamples(labels: passCounterLabels,
                                                        sampleBuffer: passCounterBuffer,
                                                        timestampFrequency: nil))
            }
        }
        telemetry.totalEncodeMs = Self.telemetryMs(since: totalStart)
        onRenderTelemetry?(telemetry)
        return true
    }

    // MARK: - Locality Sort

    public func optimize(_ chunk: SplatChunk) {
        chunk.sortByLocality()
    }
}

// MARK: - Helper Extensions

extension Array where Element == SIMD3<Float> {
    var mean: SIMD3<Float>? {
        guard !isEmpty else { return nil }
        return reduce(.zero, +) / Float(count)
    }
}

extension SIMD3 where Scalar: BinaryFloatingPoint, Scalar.RawSignificand: FixedWidthInteger {
    var normalized: SIMD3<Scalar> {
        self / Scalar(sqrt(lengthSquared))
    }

    var lengthSquared: Scalar {
        x*x + y*y + z*z
    }

    func vector4(w: Scalar) -> SIMD4<Scalar> {
        SIMD4<Scalar>(x: x, y: y, z: z, w: w)
    }

    static func random(in range: Range<Scalar>) -> SIMD3<Scalar> {
        Self(x: Scalar.random(in: range), y: .random(in: range), z: .random(in: range))
    }
}

private extension SIMD4 where Scalar: BinaryFloatingPoint {
    var xyz: SIMD3<Scalar> {
        .init(x: x, y: y, z: z)
    }
}

private extension MTLLibrary {
    func makeRequiredFunction(name: String) -> MTLFunction {
        guard let result = makeFunction(name: name) else {
            fatalError("Unable to load required shader function: \"\(name)\"")
        }
        return result
    }
}
