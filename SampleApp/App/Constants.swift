import Foundation
import simd
import SwiftUI

enum Constants {
    static let maxSimultaneousRenders = 3
    static let rotationPerSecond = Angle(degrees: 7)
    static let rotationAxis = SIMD3<Float>(0, 1, 0)
    static let dragRotationRadiansPerPoint: Float = 0.006
#if os(iOS)
    static let initialCameraPosition = SIMD3<Float>(-0.74738, 0.00310, -3.00962)
    // Quaternion component order: [w, x, y, z].
    static let initialCameraRotation = simd_quatf(
        ix: 0.992527,
        iy: 0.001505,
        iz: -0.121395,
        r: 0.012308
    ).normalized
#endif
#if !os(visionOS)
    static let fovy = Angle(degrees: 65)
#endif
    static let modelCenterZ: Float = -8

    // Procedural splat geometry
    static let proceduralCubeSize: Float = 1.0
    static let proceduralCubeDistance: Float = 1.0
    static let proceduralCubeGridSizes: [Int] = [10, 20, 50]
    static let proceduralCubeSplatRelativeRadius: Float = 0.1
    static let proceduralCubeSwapDelay: TimeInterval = 2.0
}
