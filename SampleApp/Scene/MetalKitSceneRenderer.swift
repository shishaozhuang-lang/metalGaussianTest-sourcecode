#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalPerformanceShaders
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SplatIO
import SwiftUI

@MainActor
class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let fixedRenderSize: CGSize?
    let imageScaler: MPSImageBilinearScale
    let cameraControls: CameraControlModel?
    var offscreenColorTexture: MTLTexture?

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?
    var proceduralSplatController: ProceduralSplatController?
    var sceneViewConfiguration: SceneViewConfiguration?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero
    var manualYaw: Float = 0
    var manualPitch: Float = 0
    var zoomScale: Float = 1

    var drawableSize: CGSize = .zero

    init?(_ metalKitView: MTKView,
          fixedRenderSize: CGSize? = nil,
          cameraControls: CameraControlModel? = nil) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.fixedRenderSize = fixedRenderSize
        self.imageScaler = MPSImageBilinearScale(device: self.device)
        self.cameraControls = cameraControls
        self.metalKitView = metalKitView
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
#if os(iOS)
        // The standalone iPhone viewer doesn't consume depth for reprojection,
        // AR occlusion, or scene composition. Disabling it selects the simpler
        // single-stage alpha-blended splat pipeline.
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.invalid
        metalKitView.framebufferOnly = false
#else
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float
#endif
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        self.drawableSize = metalKitView.drawableSize
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        proceduralSplatController = nil
        sceneViewConfiguration = nil
        switch model {
        case .gaussianSplat(let url, let viewConfiguration):
            sceneViewConfiguration = viewConfiguration
            let performanceOptions = Self.performanceOptimizationOptionsFromArguments()
            let splat = try SplatRenderer(device: device,
                                          colorFormat: metalKitView.colorPixelFormat,
                                          depthFormat: metalKitView.depthStencilPixelFormat,
                                          sampleCount: metalKitView.sampleCount,
                                          maxViewCount: 1,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders,
                                          performanceOptimizationsEnabled: !ProcessInfo.processInfo.arguments.contains("--disable-render-optimizations"),
                                          performanceOptimizationOptions: performanceOptions)
            let reader = try AutodetectSceneReader(url)
            let points = try await reader.readAll()
            let preferSHTexture = performanceOptions?.contains(.sphericalHarmonicsTexture) ?? false
            let chunk = try SplatChunk(device: device, from: points, preferSHTexture: preferSHTexture)
            await splat.addChunk(chunk)
            modelRenderer = splat
        case .proceduralSplat:
            let controller = try ProceduralSplatController(
                device: device,
                colorFormat: metalKitView.colorPixelFormat,
                depthFormat: metalKitView.depthStencilPixelFormat,
                sampleCount: metalKitView.sampleCount,
                maxViewCount: 1,
                maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            await controller.start()
            proceduralSplatController = controller
            modelRenderer = controller.splatRenderer
        case .sampleBox:
            modelRenderer = try! SampleBoxRenderer(device: device,
                                                   colorFormat: metalKitView.colorPixelFormat,
                                                   depthFormat: metalKitView.depthStencilPixelFormat,
                                                   sampleCount: metalKitView.sampleCount,
                                                   maxViewCount: 1,
                                                   maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }
    }

    private var viewport: ModelRendererViewportDescriptor {
        let renderSize = fixedRenderSize ?? drawableSize
        let baseFovDegrees = sceneViewConfiguration?.fovDegrees ?? Float(Constants.fovy.degrees)
        let fovyRadians = (baseFovDegrees / zoomScale) * .pi / 180
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: fovyRadians,
                                                             aspectRatio: Float(renderSize.width / renderSize.height),
                                                             nearZ: sceneViewConfiguration?.nearPlane ?? 0.1,
                                                             farZ: sceneViewConfiguration?.farPlane ?? 100.0)

        let yawMatrix = matrix4x4_rotation(radians: Float(rotation.radians) + manualYaw,
                                           axis: Constants.rotationAxis)
        let pitchMatrix = matrix4x4_rotation(radians: manualPitch,
                                             axis: SIMD3<Float>(1, 0, 0))
        let translationMatrix: simd_float4x4
        let initialRotationMatrix: simd_float4x4
        if let view = sceneViewConfiguration,
           view.position.count == 3,
           view.rotation.count == 4 {
            translationMatrix = matrix4x4_translation(view.position[0], view.position[1], view.position[2])
            let quaternion = simd_quatf(ix: view.rotation[1],
                                        iy: view.rotation[2],
                                        iz: view.rotation[3],
                                        r: view.rotation[0])
            initialRotationMatrix = simd_float4x4(quaternion)
        } else {
            translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
            initialRotationMatrix = matrix_identity_float4x4
        }
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let viewport = MTLViewport(originX: 0, originY: 0, width: renderSize.width, height: renderSize.height, znear: 0, zfar: 1)

#if os(iOS)
        // Use a reproducible world-space camera pose for iPhone performance tests.
        // The view matrix is the inverse of the camera's world transform.
        var initialCameraTransform = simd_float4x4(Constants.initialCameraRotation)
        initialCameraTransform.columns.3 = SIMD4<Float>(Constants.initialCameraPosition, 1)
        let viewMatrix = initialCameraTransform.inverse * pitchMatrix * yawMatrix
#else
        let viewMatrix = translationMatrix * initialRotationMatrix * pitchMatrix * yawMatrix * commonUpCalibration
#endif
        cameraControls?.updateCameraTelemetry(viewMatrix: viewMatrix)

        return ModelRendererViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: viewMatrix,
                                               screenSize: SIMD2(x: Int(renderSize.width), y: Int(renderSize.height)))
    }

    private func renderTarget(for drawable: CAMetalDrawable) -> MTLTexture? {
        guard let fixedRenderSize else { return drawable.texture }
        let width = Int(fixedRenderSize.width)
        let height = Int(fixedRenderSize.height)
        if let texture = offscreenColorTexture,
           texture.width == width, texture.height == height {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: metalKitView.colorPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        offscreenColorTexture = device.makeTexture(descriptor: descriptor)
        offscreenColorTexture?.label = "Fixed Resolution Color \(width)x\(height)"
        return offscreenColorTexture
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard cameraControls?.autoRotationEnabled ?? true,
              let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
    }

    func rotate(byX deltaX: Float, y deltaY: Float) {
        manualYaw += deltaX * Constants.dragRotationRadiansPerPoint
        manualPitch = min(.pi / 2, max(-.pi / 2,
                                      manualPitch + deltaY * Constants.dragRotationRadiansPerPoint))
    }

    func zoom(by scale: Float) {
        guard scale.isFinite, scale > 0 else { return }
        zoomScale = min(4, max(0.5, zoomScale * scale))
    }

    func setCameraInteractionActive(_ active: Bool) {
        (modelRenderer as? SplatRenderer)?.setCameraInteractionActive(active)
    }

    private static func performanceOptimizationOptionsFromArguments() -> SplatRenderer.PerformanceOptimizationOptions? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--disable-render-optimizations") {
            return []
        }
        guard let optionIndex = arguments.firstIndex(of: "--renderer-optimization-options"),
              arguments.indices.contains(optionIndex + 1) else {
            return nil
        }

        let value = arguments[optionIndex + 1].lowercased()
        switch value {
        case "mobile-540p", "mobile540p", "quality-performance-540p":
            return .mobile540p
        case "all":
            return .all
        case "none":
            return []
        case "quality-preserving":
            return .qualityPreserving
        default:
            var options: SplatRenderer.PerformanceOptimizationOptions = []
            for token in value.split(separator: ",").map(String.init) {
                switch token {
                case "all":
                    options.formUnion(.all)
                case "none":
                    options = []
                case "quality-preserving":
                    options.formUnion(.qualityPreserving)
                case "sort-cache":
                    options.insert(.sortPoseCaching)
                case "interaction-sort-rate-limit":
                    options.insert(.interactionSortRateLimit)
                case "cpu-cull":
                    options.insert(.cpuVisibilityCulling)
                case "cpu-opacity-cull":
                    options.insert(.cpuOpacityCulling)
                case "cpu-radius-cull":
                    options.insert(.cpuProjectedRadiusCulling)
                case "cpu-frustum-cull":
                    options.insert(.cpuFrustumCulling)
                case "gpu-opacity-cull":
                    options.insert(.gpuOpacityCulling)
                case "gpu-radius-cull":
                    options.insert(.gpuProjectedRadiusCulling)
                case "chunk-cache":
                    options.insert(.chunkTableCaching)
                case "interaction-sh-reduction":
                    options.insert(.interactionSHReduction)
                case "large-index-batches":
                    options.insert(.largeIndexedSplatBatches)
                case "sh1", "low-bandwidth-sh1":
                    options.insert(.sphericalHarmonics1)
                case "sh0", "low-bandwidth-sh0", "quantized-sh0":
                    options.insert(.sphericalHarmonics0)
                case "sh-texture", "astc-sh-texture":
                    options.insert(.sphericalHarmonicsTexture)
                case "adaptive-gpu-radius-cull":
                    options.insert([.gpuProjectedRadiusCulling, .adaptiveGPUProjectedRadiusCulling])
                case "contribution-adaptive-radius", "gradient-adaptive-radius":
                    options.insert([.gpuProjectedRadiusCulling, .contributionAdaptiveRadiusCulling])
                case "opacity-threshold-2":
                    options.insert([.cpuOpacityCulling, .opacityThreshold2])
                case "opacity-threshold-4":
                    options.insert([.cpuOpacityCulling, .opacityThreshold4])
                case "opacity-threshold-3":
                    options.insert([.cpuOpacityCulling, .opacityThreshold3])
                case "opacity-threshold-2-5", "opacity-threshold-25":
                    options.insert([.cpuOpacityCulling, .opacityThreshold25])
                default:
                    break
                }
            }
            return options
        }
    }

    func draw(in view: MTKView) {
        guard let modelRenderer, modelRenderer.isReadyToRender else { return }
        guard let drawable = view.currentDrawable else { return }
        guard let colorTexture = renderTarget(for: drawable) else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { @Sendable (_ commandBuffer) -> Void in
            semaphore.signal()
        }

        updateRotation()
        proceduralSplatController?.update()

        let didRender: Bool
        do {
            didRender = try modelRenderer.render(viewports: [viewport],
                                                 colorTexture: colorTexture,
                                                 colorStoreAction: .store,
                                                 depthTexture: nil,
                                                 rasterizationRateMap: nil,
                                                 renderTargetArrayLength: 0,
                                                 to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
            didRender = false
        }

        if didRender {
            if fixedRenderSize != nil {
                imageScaler.encode(commandBuffer: commandBuffer,
                                   sourceTexture: colorTexture,
                                   destinationTexture: drawable.texture)
            }
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return
        }
        drawableSize = size
    }
}

#endif // os(iOS) || os(macOS)
