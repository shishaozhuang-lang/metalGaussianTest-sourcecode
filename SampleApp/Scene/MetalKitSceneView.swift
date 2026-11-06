#if os(macOS)
import SwiftUI
import MetalKit

private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
import SwiftUI
import MetalKit

private typealias ViewRepresentable = UIViewRepresentable
#endif

struct MetalKitSceneView: ViewRepresentable {
    var modelIdentifier: ModelIdentifier?
    var cameraControls: CameraControlModel? = nil
    /// Called by the save-view button to read the live camera pose directly from the renderer.
    var onRendererAvailable: ((MetalKitSceneRenderer?) -> Void)? = nil
    /// Invoked on ⌘S inside the render window.
    var onCmdSave: (() -> Void)? = nil

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
        var keyMonitor: Any?
        /// Invoked on ⌘S in the render window.
        var saveHandler: (() -> Void)?

#if os(macOS)
        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            renderer?.setCameraInteractionActive(gesture.state != .ended && gesture.state != .cancelled)
            let translation = gesture.translation(in: gesture.view)
            renderer?.rotate(byX: Float(translation.x), y: Float(translation.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let renderer = self.renderer,
                      let window = event.window,
                      renderer.metalKitView.window === window else {
                    return event
                }

                // ⌘S saves the current view — handled here because SwiftUI button
                // shortcuts don't reach windows created via openWindow(value:).
                if event.type == .keyDown,
                   event.charactersIgnoringModifiers?.lowercased() == "s",
                   event.modifierFlags.contains(.command) {
                    self.saveHandler?()
                    return nil
                }

                let wasdKeys: Set<Character> = ["w", "a", "s", "d", "q", "e"]
                guard let keyChar = event.charactersIgnoringModifiers?.first,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.command).isEmpty,
                      wasdKeys.contains(keyChar) else {
                    return event
                }
                let key = KeyEquivalent(keyChar)

                switch event.type {
                case .keyDown:
                    renderer.pressedKeys.insert(key)
                    renderer.lastKeyPressedTimestamp = Date()
                case .keyUp:
                    renderer.pressedKeys.remove(key)
                default:
                    break
                }
                // Don't pass WASD through to other responders (e.g. typing in the overlay).
                return nil
            }
        }

        isolated deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
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
        onRendererAvailable?(renderer)

#if os(macOS)
        metalKitView.addGestureRecognizer(NSPanGestureRecognizer(target: coordinator,
                                                                 action: #selector(Coordinator.handlePan(_:))))
        coordinator.saveHandler = onCmdSave
        coordinator.installKeyMonitor()
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
