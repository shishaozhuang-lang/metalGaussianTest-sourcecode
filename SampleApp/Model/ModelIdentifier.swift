import Foundation

enum ModelIdentifier: Equatable, Hashable, Codable, CustomStringConvertible {
    case gaussianSplat(URL, SceneViewConfiguration?)
    case proceduralSplat
    case sampleBox

    var description: String {
        switch self {
        case .gaussianSplat(let url, _):
            "Gaussian Splat: \(url.path)"
        case .proceduralSplat:
            "Procedural Splat"
        case .sampleBox:
            "Sample Box"
        }
    }
}
