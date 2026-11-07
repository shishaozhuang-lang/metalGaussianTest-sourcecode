import Foundation

public enum SplatFileFormat {
    case ply
    case dotSplat
    case spz
    case mp4

    public init?(for url: URL) {
        switch url.pathExtension.lowercased() {
        case "ply": self = .ply
        case "splat": self = .dotSplat
        case "spz": self = .spz
        case "mp4", "mov", "m4v": self = .mp4
        default: return nil
        }
    }
}
