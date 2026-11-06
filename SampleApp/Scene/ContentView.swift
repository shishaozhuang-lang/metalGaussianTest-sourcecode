import SwiftUI
import UniformTypeIdentifiers
import simd

@MainActor
final class CameraControlModel: ObservableObject {
    @Published var autoRotationEnabled = false
    @Published var showsCameraInfo = true
    @Published private(set) var position = SIMD3<Float>.zero
    @Published private(set) var rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    @Published private(set) var fovyDegrees: Float = 0

    private var lastTelemetryUpdate = Date.distantPast
    private var lastFileWrite = Date.distantPast

    static let cameraStateFileURL = URL(fileURLWithPath: "/tmp/metal-splatter-camera.json")

    func updateCameraTelemetry(viewMatrix: simd_float4x4, fovyDegrees: Float) {
        self.fovyDegrees = fovyDegrees

        let now = Date()
        guard now.timeIntervalSince(lastTelemetryUpdate) >= 0.2 else { return }
        lastTelemetryUpdate = now

        let cameraTransform = viewMatrix.inverse
        position = SIMD3(cameraTransform.columns.3.x,
                         cameraTransform.columns.3.y,
                         cameraTransform.columns.3.z)
        rotation = simd_quatf(cameraTransform).normalized

        writeCameraStateFile(now: now)
    }

    /// Writes the live camera pose to /tmp so it can be inspected while tuning,
    /// and read back as the saved default view once tuning is done.
    private func writeCameraStateFile(now: Date) {
        guard now.timeIntervalSince(lastFileWrite) >= 0.5 else { return }
        lastFileWrite = now

        let state: [String: Any] = [
            "position": [position.x, position.y, position.z],
            "rotation": [rotation.real, rotation.imag.x, rotation.imag.y, rotation.imag.z],
            "fov_degrees": fovyDegrees,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Self.cameraStateFileURL)
    }

    /// View-configuration JSON in "camera_world" pose semantics: position/rotation
    /// are the camera's world-space pose (same values the overlay displays).
    static func viewConfigurationJSON(position: [Float],
                                      rotation: [Float],
                                      fovDegrees: Float,
                                      nearPlane: Float = 0.1,
                                      farPlane: Float = 100.0) -> String {
        let obj: [String: Any] = [
            "position": position,
            "rotation": rotation,
            "fov_degrees": fovDegrees,
            "near_plane": nearPlane,
            "far_plane": farPlane,
            "pose_semantics": "camera_world",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

#if os(iOS) || os(macOS)
struct SceneContainer: View {
    let modelIdentifier: ModelIdentifier
    @StateObject private var cameraControls = CameraControlModel()
    @State private var liveRenderer: MetalKitSceneRenderer?

    private var isPerfRun: Bool {
        ProcessInfo.processInfo.arguments.contains { $0 == "--perf" || $0.hasPrefix("--perf=") }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MetalKitSceneView(modelIdentifier: modelIdentifier,
                              cameraControls: cameraControls,
                              onRendererAvailable: { liveRenderer = $0 },
                              onCmdSave: { saveCurrentView() })

            if !isPerfRun {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("自动旋转", isOn: $cameraControls.autoRotationEnabled)
                    Toggle("显示相机信息", isOn: $cameraControls.showsCameraInfo)

                    if cameraControls.showsCameraInfo {
                        Divider()
                        Text(cameraDescription)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Button("保存当前视角") {
                        saveCurrentView()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("保存当前视角 (⌘S)")
                }
                .padding(12)
                .frame(maxWidth: 310)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(12)
            }
        }
    }

    private var cameraDescription: String {
        let p = cameraControls.position
        let q = cameraControls.rotation
        return String(format: "位置 (world)\nx: % .5f\ny: % .5f\nz: % .5f\n\n旋转四元数 [w,x,y,z]\nw: % .6f\nx: % .6f\ny: % .6f\nz: % .6f\n\nFOV: %.1f°",
                      p.x, p.y, p.z,
                      q.real, q.imag.x, q.imag.y, q.imag.z,
                      cameraControls.fovyDegrees)
    }

    #if os(macOS)
    private func saveCurrentView() {
        guard case .gaussianSplat(let url, _) = modelIdentifier else { return }
        // Read the live pose straight from the renderer so the saved view matches
        // what is on screen at the moment of the click (the throttled telemetry
        // cache can lag by 0.2–0.5 s or hold a stale pose when rendering paused).
        guard let renderer = liveRenderer else {
            print("Save failed: renderer not available")
            return
        }
        let state = renderer.currentCameraState
        let viewURL = url.deletingLastPathComponent().appendingPathComponent("view.json")
        let json = CameraControlModel.viewConfigurationJSON(position: state.position,
                                                            rotation: state.rotation,
                                                            fovDegrees: state.fovDegrees)
        do {
            try json.write(to: viewURL, atomically: true, encoding: .utf8)
            print("Saved camera view to \(viewURL.path): pos \(state.position) fov \(state.fovDegrees)")
        } catch {
            print("Failed to save camera view: \(error.localizedDescription)")
        }
    }
    #endif
}
#endif

#if os(iOS)
private struct IOSSceneContainer: View {
    let modelIdentifier: ModelIdentifier
    @StateObject private var cameraControls = CameraControlModel()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MetalKitSceneView(modelIdentifier: modelIdentifier,
                              cameraControls: cameraControls)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("自动旋转", isOn: $cameraControls.autoRotationEnabled)
                Toggle("显示相机信息", isOn: $cameraControls.showsCameraInfo)

                if cameraControls.showsCameraInfo {
                    Divider()
                    Text(cameraDescription)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: 310)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
    }

    private var cameraDescription: String {
        let p = cameraControls.position
        let q = cameraControls.rotation
        return String(format: "位置 (world)\nx: % .5f\ny: % .5f\nz: % .5f\n\n旋转四元数 [w,x,y,z]\nw: % .6f\nx: % .6f\ny: % .6f\nz: % .6f",
                      p.x, p.y, p.z,
                      q.real, q.imag.x, q.imag.y, q.imag.z)
    }
}
#endif

struct ContentView: View {
    @State private var isPickingFile = false
    @State private var didOpenCommandLineModel = false
    @State private var didOpenDefaultScene = false

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#elseif os(iOS)
    @State private var navigationPath = NavigationPath()

    private func openWindow(value: ModelIdentifier) {
        navigationPath.append(value)
    }
#elseif os(visionOS)
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    @State var immersiveSpaceIsShown = false

    private func openWindow(value: ModelIdentifier) {
        Task {
            switch await openImmersiveSpace(value: value) {
            case .opened:
                immersiveSpaceIsShown = true
            case .error, .userCancelled:
                break
            @unknown default:
                break
            }
        }
    }
#endif

    var body: some View {
#if os(iOS)
        NavigationStack(path: $navigationPath) {
            mainView
                .navigationDestination(for: ModelIdentifier.self) { modelIdentifier in
                    IOSSceneContainer(modelIdentifier: modelIdentifier)
                        .navigationTitle(modelIdentifier.description)
                        .navigationBarBackButtonHidden(true)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    guard !navigationPath.isEmpty else { return }
                                    navigationPath.removeLast()
                                } label: {
                                    Label("返回", systemImage: "chevron.left")
                                }
                            }
                        }
                }
        }
        .onAppear {
            openDefaultSceneIfNeeded()
        }
#else
        mainView
            .onAppear {
                if !openCommandLineModelIfNeeded() {
                    openDefaultSceneIfNeeded()
                }
            }
#endif
    }

    @ViewBuilder
    var mainView: some View {
        ScrollView {
        VStack {
            Spacer()

            Text("MetalSplatter SampleApp")

            Spacer()

            Button("Read Scene File") {
                isPickingFile = true
            }
            .padding()
            .buttonStyle(.borderedProminent)
            .disabled(isPickingFile)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif
            .fileImporter(isPresented: $isPickingFile,
                          allowedContentTypes: [
                            UTType(filenameExtension: "ply")!,
                            UTType(filenameExtension: "splat")!,
                            UTType(filenameExtension: "spz")!,
                          ]) {
                isPickingFile = false
                switch $0 {
                case .success(let url):
                    _ = url.startAccessingSecurityScopedResource()
                    Task {
                        // This is a sample app. In a real app, this should be more tightly scoped, not using a silly timer.
                        try await Task.sleep(for: .seconds(10))
                        url.stopAccessingSecurityScopedResource()
                    }
                    openWindow(value: ModelIdentifier.gaussianSplat(url, nil))
                case .failure:
                    break
                }
            }

            Button("Procedural Splat") {
                openWindow(value: ModelIdentifier.proceduralSplat)
            }
            .padding()
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Button("Show Sample Box") {
                openWindow(value: ModelIdentifier.sampleBox)
            }
            .padding()
            .buttonStyle(.borderedProminent)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif

            Text("Bundled Scenes")
                .font(.headline)
                .padding(.top)

            ForEach(bundledSceneNames, id: \.self) { sceneName in
                Button(sceneName) {
                    openBundledScene(named: sceneName)
                }
                .padding(.horizontal)
                .buttonStyle(.bordered)
            }

            Spacer()

#if os(visionOS)
            Button("Dismiss Immersive Space") {
                Task {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                }
            }
            .disabled(!immersiveSpaceIsShown)

            Spacer()
#endif // os(visionOS)
        }
        }
#if os(macOS)
        .onAppear {
            if !openCommandLineModelIfNeeded() {
                openDefaultSceneIfNeeded()
            }
        }
#elseif os(iOS)
        .onAppear {
            openDefaultSceneIfNeeded()
        }
#endif
    }

#if os(macOS)
    private static var didOpenCommandLineModelOnce = false

    private func openCommandLineModelIfNeeded() -> Bool {
        guard !Self.didOpenCommandLineModelOnce, !didOpenCommandLineModel else { return true }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--model"),
              arguments.indices.contains(flagIndex + 1) else { return false }

        Self.didOpenCommandLineModelOnce = true
        didOpenCommandLineModel = true
        let url = URL(fileURLWithPath: arguments[flagIndex + 1])
        let viewURL = url.deletingLastPathComponent().appendingPathComponent("view.json")
        let viewConfiguration = SceneViewConfiguration.load(from: viewURL)
        if viewConfiguration == nil {
            print("No view.json found next to model; starting from default camera pose.")
        }
        openWindow(value: ModelIdentifier.gaussianSplat(url, viewConfiguration))
        return true
    }
#endif

    private func openDefaultSceneIfNeeded() {
        guard !didOpenDefaultScene else { return }
        didOpenDefaultScene = true
        openBundledScene(named: requestedBundledSceneName ?? "bicycle500w")
    }

    private var requestedBundledSceneName: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let optionIndex = arguments.firstIndex(of: "--scene"),
              arguments.indices.contains(optionIndex + 1) else { return nil }
        let sceneName = arguments[optionIndex + 1]
        return bundledSceneNames.contains(sceneName) ? sceneName : nil
    }

    private var bundledSceneNames: [String] {
        ["bicycle500w", "bicycle120w", "garden_images2_3k", "garden_images2_7k", "garden_images2_30k"]
    }

    private func openBundledScene(named sceneName: String) {
        guard let modelURL = Bundle.main.url(forResource: "point_cloud",
                                             withExtension: "ply",
                                             subdirectory: "Scenes/\(sceneName)") else { return }
        let viewURL = Bundle.main.url(forResource: "view",
                                      withExtension: "json",
                                      subdirectory: "Scenes/\(sceneName)")
        let viewConfiguration = viewURL.flatMap(SceneViewConfiguration.load(from:))
        openWindow(value: ModelIdentifier.gaussianSplat(modelURL, viewConfiguration))
    }
}
