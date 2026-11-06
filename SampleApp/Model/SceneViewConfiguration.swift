import Foundation

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

    enum CodingKeys: String, CodingKey {
        case position
        case rotation
        case fovDegrees = "fov_degrees"
        case nearPlane = "near_plane"
        case farPlane = "far_plane"
        case poseSemantics = "pose_semantics"
    }

    var isCameraWorldPose: Bool { poseSemantics == "camera_world" }

    static func load(from url: URL) -> SceneViewConfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SceneViewConfiguration.self, from: data)
    }
}
