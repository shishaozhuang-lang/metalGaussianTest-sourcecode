import Foundation
import CoreGraphics

/// Camera configuration loaded from a scene's `view.json`.
/// Two pose semantics are supported:
/// - `"view"` (default): position/rotation are view-matrix T·R parameters;
/// - `"camera_world"`: position/rotation are the camera's world-space pose
///   (position in world coordinates, orientation quaternion [w,x,y,z]).
struct SceneViewConfiguration: Codable, Sendable, Equatable, Hashable {
    var position: [Float]
    /// Quaternion in [w, x, y, z] order.
    var rotation: [Float]
    var fovDegrees: Float
    var nearPlane: Float
    var farPlane: Float
    /// "view" (default) or "camera_world".
    var poseSemantics: String?
    /// Fixed render resolution [width, height]; absent = window size.
    var renderResolution: [Int]?

    enum CodingKeys: String, CodingKey {
        case position
        case rotation
        case fovDegrees = "fov_degrees"
        case nearPlane = "near_plane"
        case farPlane = "far_plane"
        case poseSemantics = "pose_semantics"
        case renderResolution = "render_resolution"
    }

    var isCameraWorldPose: Bool { poseSemantics == "camera_world" }

    /// Fixed render size from `render_resolution: [w, h]`, if valid.
    var renderSize: CGSize? {
        guard let r = renderResolution, r.count == 2, r[0] > 0, r[1] > 0 else { return nil }
        return CGSize(width: r[0], height: r[1])
    }

    static func load(from url: URL) -> SceneViewConfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SceneViewConfiguration.self, from: data)
    }
}
