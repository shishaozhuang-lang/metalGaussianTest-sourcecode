#if os(iOS) || os(macOS)

import SwiftUI
import MetalKit

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
private typealias ViewRepresentable = UIViewRepresentable
#endif

struct MetalKitSceneView: ViewRepresentable {
    var modelIdentifier: ModelIdentifier?
    var cameraControls: CameraControlModel? = nil

    /// Optional benchmark-only render size, supplied as
    /// `--render-size WIDTHxHEIGHT` (for example, `--render-size 1080x1920`).
    private static var requestedDrawableSize: CGSize? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let optionIndex = arguments.firstIndex(of: "--render-size"),
              arguments.indices.contains(optionIndex + 1) else {
            return nil
        }

        let components = arguments[optionIndex + 1]
            .lowercased()
            .split(separator: "x", maxSplits: 1)
        guard components.count == 2,
              let width = Int(components[0]),
              let height = Int(components[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    @MainActor
    class Coordinator: NSObject {
        var renderer: MetalKitSceneRenderer?

#if os(macOS)
        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            renderer?.setCameraInteractionActive(gesture.state != .ended && gesture.state != .cancelled)
            let translation = gesture.translation(in: gesture.view)
            renderer?.rotate(byX: Float(translation.x), y: Float(translation.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }
#elseif os(iOS)
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            renderer?.setCameraInteractionActive(gesture.state != .ended && gesture.state != .cancelled)
            let translation = gesture.translation(in: gesture.view)
            renderer?.rotate(byX: Float(translation.x), y: Float(-translation.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            renderer?.setCameraInteractionActive(gesture.state != .ended && gesture.state != .cancelled)
            renderer?.zoom(by: Float(gesture.scale))
            gesture.scale = 1
        }
#endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

#if os(macOS)
    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#elseif os(iOS)
    func makeUIView(context: UIViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#endif

    private func makeView(_ coordinator: Coordinator) -> MTKView {
        let metalKitView = MTKView()

        if let metalDevice = MTLCreateSystemDefaultDevice() {
            metalKitView.device = metalDevice
        }

        let renderer = MetalKitSceneRenderer(
            metalKitView,
            fixedRenderSize: Self.requestedDrawableSize,
            cameraControls: cameraControls
        )
        coordinator.renderer = renderer
        metalKitView.delegate = renderer

#if os(macOS)
        metalKitView.addGestureRecognizer(NSPanGestureRecognizer(target: coordinator,
                                                                 action: #selector(Coordinator.handlePan(_:))))
#elseif os(iOS)
        let panGesture = UIPanGestureRecognizer(target: coordinator,
                                                action: #selector(Coordinator.handlePan(_:)))
        let pinchGesture = UIPinchGestureRecognizer(target: coordinator,
                                                    action: #selector(Coordinator.handlePinch(_:)))
        panGesture.delegate = coordinator
        pinchGesture.delegate = coordinator
        metalKitView.addGestureRecognizer(panGesture)
        metalKitView.addGestureRecognizer(pinchGesture)
#endif

        Task {
            do {
                try await renderer?.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }

        return metalKitView
    }

#if os(macOS)
    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#elseif os(iOS)
    func updateUIView(_ view: MTKView, context: UIViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#endif

    private func updateView(_ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        Task {
            do {
                try await renderer.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }
    }
}

#if os(iOS)
extension MetalKitSceneView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif

#endif // os(iOS) || os(macOS)
