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

    // WASD-flying camera offset (world space), applied on top of the scene view pose.
    var cameraOffset: SIMD3<Float> = .zero
    var lastMovementUpdateTimestamp: Date? = nil
    // Key-up events can be lost (focus changes, alerts); drop held keys that go stale.
    var lastKeyPressedTimestamp: Date? = nil

    var drawableSize: CGSize = .zero

    /// Monotonic counter of MTKView draw() invocations, for --frame-log.
    private var frameLogCounter = 0

    // Keys currently held down; updated by the local keyboard event monitor.
    var pressedKeys: Set<KeyEquivalent> = []

    /// Live camera pose in "camera_world" semantics — the same values the overlay
    /// displays. Saving writes pose_semantics: "camera_world", which loads back
    /// as V = cameraWorld⁻¹ · calibration, reproducing the on-screen view exactly.
    var currentCameraState: (position: [Float], rotation: [Float], fovDegrees: Float) {
        let descriptor = self.viewport
        // V = T·R·P·Y·C ⇒ cameraWorld = V⁻¹ = C⁻¹·(P·Y)⁻¹·R⁻¹·T⁻¹; with P, Y baked to
        // identity, cameraWorld = C·V⁻¹. Drop the trailing C from V first: V' = V·C.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
        let cameraWorld = (descriptor.viewMatrix * commonUpCalibration).inverse

        let position = SIMD3<Float>(cameraWorld.columns.3.x,
                                    cameraWorld.columns.3.y,
                                    cameraWorld.columns.3.z)
        let rotation = simd_quatf(cameraWorld).normalized

        let baseFov = sceneViewConfiguration?.fovDegrees ?? Float(Constants.fovy.degrees)
        return ([position.x, position.y, position.z],
                [rotation.real, rotation.imag.x, rotation.imag.y, rotation.imag.z],
                baseFov / zoomScale)
    }

    // Perf recording: enabled via --perf[=PATH]; writes per-frame telemetry CSV.
    static let perfRecordingEnabled = ProcessInfo.processInfo.arguments.contains { $0 == "--perf" || $0.hasPrefix("--perf=") }
    var perfRecorder: PerfRecorder?

    /// --no-present skips present() so the render loop is not gated by the
    /// display vsync — measures pure pipeline throughput.
    static let noPresentEnabled = ProcessInfo.processInfo.arguments.contains("--no-present")

    /// --frame-log prints a per-frame line to stdout marking whether the full
    /// 3DGS render pipeline ran (or why the frame was skipped) — used to verify
    /// that every frame executes the complete pipeline under a fixed camera.
    static let frameLogEnabled = ProcessInfo.processInfo.arguments.contains("--frame-log")

    /// --max-fps=N: frame-rate cap (N>0); --max-fps=0: uncapped peak-throughput mode.
    static func requestedMaxFPS() -> Int? {
        for argument in ProcessInfo.processInfo.arguments {
            if argument.hasPrefix("--max-fps=") {
                return Int(argument.dropFirst("--max-fps=".count))
            }
            if argument == "--max-fps" {
                return 0
            }
        }
        return nil
    }

    static func perfOutputPath() -> URL? {
        for argument in ProcessInfo.processInfo.arguments {
            if argument.hasPrefix("--perf=") {
                var path = String(argument.dropFirst("--perf=".count))
                #if os(iOS)
                // iOS sandbox: bare filenames resolve into the app's Documents directory.
                if !path.hasPrefix("/") {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    path = docs?.appendingPathComponent(path).path ?? path
                }
                #endif
                return URL(fileURLWithPath: path)
            }
        }
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("perf.csv")
        #else
        return URL(fileURLWithPath: "/tmp/metal-splatter-perf.csv")
        #endif
    }

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
        // Render every frame (continuous loop), never pausing when occluded or
        // backgrounded — required for consistent performance measurement.
        metalKitView.isPaused = false
        metalKitView.enableSetNeedsDisplay = false
        // --max-fps=N: cap at N fps; --max-fps=0 uncaps (timer-driven, may exceed
        // display vsync — used to measure peak rendering throughput).
        if let maxFPS = Self.requestedMaxFPS() {
            if maxFPS == 0 {
                // 0 = uncapped: run the timer as fast as the render loop allows
                metalKitView.preferredFramesPerSecond = 240
            } else {
                metalKitView.preferredFramesPerSecond = maxFPS
            }
        }
        self.drawableSize = metalKitView.drawableSize
        if Self.perfRecordingEnabled, let path = Self.perfOutputPath() {
            perfRecorder = PerfRecorder(url: path)
            print("Perf recording to \(path.path)")
        }
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
            SplatRenderer.debugLogFrames = Self.frameLogEnabled
            SplatRenderer.debugLogSorts = Self.frameLogEnabled
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
            if Self.perfRecordingEnabled {
                let recorder = perfRecorder
                splat.onRenderTelemetry = { telemetry in
                    recorder?.record(telemetry)
                }
            }

            // --save-current-view: after the model settles, dump the live view
            // parameters to stdout and exit (round-trip verification harness).
            if ProcessInfo.processInfo.arguments.contains("--save-current-view") {
                let renderer = self
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    let state = renderer.currentCameraState
                    let json = CameraControlModel.viewConfigurationJSON(position: state.position,
                                                                        rotation: state.rotation,
                                                                        fovDegrees: state.fovDegrees)
                    print("SAVE-CURRENT-VIEW:\(json.replacingOccurrences(of: "\n", with: ""))")
                    fflush(stdout)
                    exit(0)
                }
            }
            // --benchmark-frames=N: peak offscreen throughput measurement
            var benchmarkFrames = 0
            for argument in ProcessInfo.processInfo.arguments {
                if argument.hasPrefix("--benchmark-frames=") {
                    benchmarkFrames = Int(argument.dropFirst("--benchmark-frames=".count)) ?? 0
                }
            }
            if benchmarkFrames > 0 {
                modelRenderer = splat
                let renderer = self
                Task { @MainActor in
                    // warm-up: first sort must complete so the renderer is ready
                    for _ in 0..<120 {
                        if renderer.modelRenderer?.isReadyToRender == true { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    renderer.runFrameBenchmark(frames: benchmarkFrames)
                }
                return
            }
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
            if view.isCameraWorldPose {
                let quaternion = simd_quatf(ix: view.rotation[1],
                                            iy: view.rotation[2],
                                            iz: view.rotation[3],
                                            r: view.rotation[0])
                var cameraWorld = simd_float4x4(quaternion)
                cameraWorld.columns.3 = SIMD4<Float>(view.position[0],
                                                     view.position[1],
                                                     view.position[2], 1)
                let calibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
                let cameraInverse = cameraWorld.inverse * calibration
                translationMatrix = matrix4x4_translation(cameraInverse.columns.3.x,
                                                           cameraInverse.columns.3.y,
                                                           cameraInverse.columns.3.z)
                initialRotationMatrix = simd_float4x4(simd_quatf(cameraInverse).normalized)
            } else {
                translationMatrix = matrix4x4_translation(view.position[0], view.position[1], view.position[2])
                let quaternion = simd_quatf(ix: view.rotation[1],
                                            iy: view.rotation[2],
                                            iz: view.rotation[3],
                                            r: view.rotation[0])
                initialRotationMatrix = simd_float4x4(quaternion)
            }
        } else {
            translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
            initialRotationMatrix = matrix_identity_float4x4
        }
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let viewport = MTLViewport(originX: 0, originY: 0, width: renderSize.width, height: renderSize.height, znear: 0, zfar: 1)

        let viewMatrix = translationMatrix * initialRotationMatrix * pitchMatrix * yawMatrix * commonUpCalibration

        // Compute movement against the pre-offset view matrix so direction follows
        // the camera's (rotation-only) heading, not an offset-shifted basis.
        updateCameraMovement(viewMatrix: viewMatrix)

        var effectiveViewMatrix = viewMatrix
        if cameraOffset != .zero {
            // Moving the camera by +offset in world space = translating the world by -offset
            // in the view transform, so left-multiply the inverse translation.
            effectiveViewMatrix = matrix4x4_translation(-cameraOffset.x, -cameraOffset.y, -cameraOffset.z) * viewMatrix
        }
        // Only the key (focused) window updates telemetry and writes the camera
        // state file — otherwise duplicate render windows overwrite each other's
        // pose with whichever window happens to render last.
        if metalKitView.window?.isKeyWindow ?? false {
            cameraControls?.updateCameraTelemetry(viewMatrix: effectiveViewMatrix, fovyDegrees: (baseFovDegrees / zoomScale))
        }

        return ModelRendererViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: effectiveViewMatrix,
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
        // Full turntable rotation: no dead zone at ±90° pitch. Once pitch passes
        // straight up/down, yaw flips direction so the view stays continuous
        // (the world appears upside-down past the pole, which is correct).
        let delta = deltaY * Constants.dragRotationRadiansPerPoint
        let oldPitch = manualPitch
        manualPitch += delta

        // Handle pole crossings: |pitch| > π/2 means we are past straight up/down.
        // Wrap pitch into [-π, π] and compensate yaw so the camera keeps turning
        // in the direction the user is dragging.
        if manualPitch > .pi {
            manualPitch -= 2 * .pi
        } else if manualPitch < -.pi {
            manualPitch += 2 * .pi
        }
        let crossedPole = (oldPitch > .pi / 2 && manualPitch < .pi / 2)
                       || (oldPitch < -.pi / 2 && manualPitch > -.pi / 2)
        let wasPastPole = abs(oldPitch) > .pi / 2
        let isPastPole = abs(manualPitch) > .pi / 2
        if crossedPole || (wasPastPole != isPastPole) {
            // Passing the pole: flip yaw continuity by adding π.
            manualYaw += .pi
        }

        manualYaw += deltaX * Constants.dragRotationRadiansPerPoint
    }

    func zoom(by scale: Float) {
        guard scale.isFinite, scale > 0 else { return }
        zoomScale = min(4, max(0.5, zoomScale * scale))
    }

    /// Advances the WASD-flying camera offset based on currently held keys.
    /// Movement is in the camera's local frame (post-rotation view basis).
    private func updateCameraMovement(viewMatrix: simd_float4x4) {
        // Drop keys held longer than 0.5 s without a repeating keyDown — the keyUp was lost.
        if let lastPressed = lastKeyPressedTimestamp,
           Date().timeIntervalSince(lastPressed) > 0.5 {
            pressedKeys.removeAll()
        }
        let now = Date()
        defer { lastMovementUpdateTimestamp = now }
        guard let lastMovementUpdateTimestamp else { return }
        guard !pressedKeys.isEmpty else { return }

        let dt = Float(now.timeIntervalSince(lastMovementUpdateTimestamp))
        guard dt > 0, dt < 1 else { return }

        // View basis: right/forward/up axes of the camera in world space.
        // viewMatrix transforms world -> camera, so rows of its rotation part
        // (equivalently columns of the inverse) are the camera axes.
        let cameraTransform = viewMatrix.inverse
        let right = SIMD3<Float>(cameraTransform.columns.0.x,
                                 cameraTransform.columns.0.y,
                                 cameraTransform.columns.0.z)
        let forward = SIMD3<Float>(cameraTransform.columns.2.x,
                                   cameraTransform.columns.2.y,
                                   cameraTransform.columns.2.z)
        let up = SIMD3<Float>(cameraTransform.columns.1.x,
                              cameraTransform.columns.1.y,
                              cameraTransform.columns.1.z)

        let speed: Float = 2.0  // world units per second
        var delta = SIMD3<Float>.zero
        for key in pressedKeys {
            switch key {
            case "w": delta += forward * (speed * dt)
            case "s": delta -= forward * (speed * dt)
            case "a": delta -= right * (speed * dt)
            case "d": delta += right * (speed * dt)
            case "q": delta -= up * (speed * dt)
            case "e": delta += up * (speed * dt)
            default: break
            }
        }
        cameraOffset += delta
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

    /// --benchmark-frames=N: after loading, render N frames back-to-back to an
    /// offscreen texture (no drawable, no vsync) and report peak throughput.
    private func runFrameBenchmark(frames: Int) {
        let width = Int(fixedRenderSize?.width ?? drawableSize.width)
        let height = Int(fixedRenderSize?.height ?? drawableSize.height)
        guard width > 0, height > 0 else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: metalKitView.colorPixelFormat,
                                                                   width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        print("BENCH: rendering \(frames) frames at \(width)x\(height) offscreen…", terminator: ""); fflush(stdout)
        let start = DispatchTime.now()
        var rendered = 0
        for _ in 0..<frames {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { break }
            _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { @Sendable _ in semaphore.signal() }
            do {
                let ok = try modelRenderer?.render(viewports: [viewport],
                                                   colorTexture: texture,
                                                   colorStoreAction: .dontCare,
                                                   depthTexture: nil,
                                                   rasterizationRateMap: nil,
                                                   renderTargetArrayLength: 0,
                                                   to: commandBuffer) ?? false
                if ok { rendered += 1 }
            } catch {
                break
            }
            commandBuffer.commit()
        }
        // Drain: wait until all in-flight buffers completed (semaphore back to full)
        for _ in 0..<Constants.maxSimultaneousRenders {
            _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
            inFlightSemaphore.signal()
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let fps = elapsed > 0 ? Double(rendered) / elapsed : 0
        let frameMs = rendered > 0 ? elapsed / Double(rendered) * 1000 : 0
        print("BENCH-RESULT: \(rendered) frames in \(String(format: "%.3f", elapsed))s → \(String(format: "%.1f", fps)) FPS (frame \(String(format: "%.3f", frameMs)) ms)", terminator: ""); fflush(stdout)
        exit(0)
    }

    func draw(in view: MTKView) {
        frameLogCounter += 1
        let frameIndex = frameLogCounter
        func skipLog(_ reason: String) {
            if Self.frameLogEnabled { print("[frame \(frameIndex)] SKIP: \(reason)") }
        }

        guard let modelRenderer, modelRenderer.isReadyToRender else {
            skipLog("modelRenderer nil or not ready to render")
            return
        }
        guard let drawable = view.currentDrawable else {
            skipLog("no drawable")
            return
        }
        guard let colorTexture = renderTarget(for: drawable) else {
            skipLog("no render target texture")
            return
        }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            skipLog("no command buffer")
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

        if Self.frameLogEnabled && !didRender {
            print("[frame \(frameIndex)] SKIP: render() returned false")
        }

        if didRender {
            if Self.frameLogEnabled {
                print("[frame \(frameIndex)] OK (full pipeline ran)")
            }
            if fixedRenderSize != nil {
                imageScaler.encode(commandBuffer: commandBuffer,
                                   sourceTexture: colorTexture,
                                   destinationTexture: drawable.texture)
            }
            // --no-present skips present() so the render loop is not gated by the
            // display vsync — measures pure pipeline throughput (encode + GPU execute).
            if !Self.noPresentEnabled {
                commandBuffer.present(drawable)
            }
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
