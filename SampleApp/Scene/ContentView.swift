import SwiftUI
import UniformTypeIdentifiers
import simd

@MainActor
final class CameraControlModel: ObservableObject {
    @Published var autoRotationEnabled = false
    @Published var showsCameraInfo = false
    @Published private(set) var position = SIMD3<Float>.zero
    @Published private(set) var rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    private var lastTelemetryUpdate = Date.distantPast

    func updateCameraTelemetry(viewMatrix: simd_float4x4) {
        guard showsCameraInfo else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTelemetryUpdate) >= 0.2 else { return }
        lastTelemetryUpdate = now

        let cameraTransform = viewMatrix.inverse
        position = SIMD3(cameraTransform.columns.3.x,
                         cameraTransform.columns.3.y,
                         cameraTransform.columns.3.z)
        rotation = simd_quatf(cameraTransform).normalized
    }
}

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
#if os(macOS) || os(visionOS)
        mainView
#elseif os(iOS)
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
#endif // os(iOS)
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
    private func openCommandLineModelIfNeeded() -> Bool {
        guard !didOpenCommandLineModel else { return true }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--model"),
              arguments.indices.contains(flagIndex + 1) else { return false }

        didOpenCommandLineModel = true
        let url = URL(fileURLWithPath: arguments[flagIndex + 1])
        openWindow(value: ModelIdentifier.gaussianSplat(url, nil))
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
