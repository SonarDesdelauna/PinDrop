import SceneKit
import SwiftUI
import UIKit

// MARK: - 3D objects orbiting the globe

/// Real 3D objects (satellite, rocket, UFO, moon, ringed planet, airliner, comet, hot air balloon)
/// circling the planet when the map is zoomed out to the globe. They move on their own clock,
/// fixed to the screen, and pass behind the planet thanks to an invisible depth sphere.
/// Purely decorative: ignored by hit testing and accessibility.
struct OrbitingObjectsView: View {
    var body: some View {
        OrbitSceneRepresentable()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct OrbitSceneRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> OrbitSceneView {
        OrbitSceneView()
    }

    func updateUIView(_ uiView: OrbitSceneView, context: Context) {}
}

/// The SceneKit view. The planet has radius 1 in scene units; the camera's field of view is
/// fitted to the screen so that radius matches the globe drawn by the map behind it.
private final class OrbitSceneView: SCNView {
    /// Globe radius on screen, as a fraction of the smaller screen side.
    private static let globeScreenFraction: CGFloat = 0.36
    private static let cameraDistance: Float = 7

    private let cameraNode = SCNNode()

    init() {
        super.init(frame: .zero, options: nil)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        rendersContinuously = true
        isPlaying = true
        loops = true
        scene = makeScene()
        pointOfView = cameraNode
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let globeRadius = min(size.width, size.height) * Self.globeScreenFraction
        let ratio = Double(size.height / 2 / globeRadius)
        let angular = asin(1 / Double(Self.cameraDistance))
        let halfFOV = atan(tan(angular) * ratio)
        cameraNode.camera?.fieldOfView = CGFloat(halfFOV * 2 * 180 / .pi)
    }

    // MARK: Scene

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = OrbitTextures.environment()
        scene.lightingEnvironment.intensity = 1.3

        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 40
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Self.cameraDistance)
        scene.rootNode.addChildNode(cameraNode)

        // Sunlight from the upper left, plus a soft fill.
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1_250
        sun.light?.color = UIColor(white: 1, alpha: 1)
        sun.eulerAngles = SCNVector3(-0.7, -0.6, 0)
        scene.rootNode.addChildNode(sun)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 280
        fill.light?.color = UIColor(red: 0.75, green: 0.8, blue: 1, alpha: 1)
        scene.rootNode.addChildNode(fill)

        // Invisible planet: writes depth only, so objects behind it disappear.
        let occluderGeometry = SCNSphere(radius: 0.985)
        occluderGeometry.segmentCount = 64
        let occluderMaterial = SCNMaterial()
        occluderMaterial.colorBufferWriteMask = []
        occluderMaterial.writesToDepthBuffer = true
        occluderGeometry.materials = [occluderMaterial]
        let occluder = SCNNode(geometry: occluderGeometry)
        occluder.renderingOrder = -100
        scene.rootNode.addChildNode(occluder)

        let kinds = OrbitModel.Kind.allCases.shuffled().prefix(Int.random(in: 6...7))
        for kind in kinds {
            scene.rootNode.addChildNode(Self.orbit(carrying: OrbitModel.make(kind), kind: kind))
        }
        return scene
    }

    /// tilt (screen slant) → incline (ellipse flattening) → spin (motion) → object on the orbit.
    private static func orbit(carrying object: SCNNode, kind: OrbitModel.Kind) -> SCNNode {
        let tilt = SCNNode()
        tilt.eulerAngles.z = Float.random(in: -0.9...0.9)

        let incline = SCNNode()
        incline.eulerAngles.x = Float(asin(Double.random(in: 0.24...0.52))) * (Bool.random() ? 1 : -1)
        tilt.addChildNode(incline)

        let spin = SCNNode()
        spin.eulerAngles.y = Float.random(in: 0...(2 * .pi))
        incline.addChildNode(spin)

        let clockwise = Bool.random()
        let period = Double.random(in: 11...24)
        spin.runAction(.repeatForever(.rotateBy(x: 0, y: (clockwise ? -1 : 1) * 2 * .pi, z: 0, duration: period)))

        // Spinning around +y moves a point at +x toward -z: models face -z, so flip them
        // when the orbit runs the other way.
        let holder = SCNNode()
        holder.position = SCNVector3(Float.random(in: 1.18...1.6), 0, 0)
        if clockwise {
            holder.eulerAngles.y = .pi
        }
        let scale = Float.random(in: 0.95...1.2)
        holder.scale = SCNVector3(scale, scale, scale)
        holder.addChildNode(object)
        spin.addChildNode(holder)

        // Each object also moves on its own.
        switch kind {
        case .satellite:
            object.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: 2 * .pi, duration: 14)))
        case .rocket, .airliner, .comet:
            break
        case .ufo:
            object.childNodes.first?.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 2.4)))
        case .moon, .ringedPlanet:
            object.childNodes.first?.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 16)))
        case .balloon:
            object.runAction(.repeatForever(.sequence([
                .rotateBy(x: 0, y: 0, z: 0.12, duration: 1.8),
                .rotateBy(x: 0, y: 0, z: -0.12, duration: 1.8),
            ])))
        }
        return tilt
    }
}

// MARK: - Models

/// Procedural models built from SceneKit primitives with physically based materials.
/// Every model faces -z (its direction of travel) with +y pointing up on screen.
@MainActor
private enum OrbitModel {
    enum Kind: CaseIterable {
        case satellite, rocket, ufo, moon, ringedPlanet, airliner, comet, balloon
    }

    static func make(_ kind: Kind) -> SCNNode {
        switch kind {
        case .satellite: satellite()
        case .rocket: rocket()
        case .ufo: ufo()
        case .moon: moon()
        case .ringedPlanet: ringedPlanet()
        case .airliner: airliner()
        case .comet: comet()
        case .balloon: balloon()
        }
    }

    // MARK: Materials

    static func pbr(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.5) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metal
        material.roughness.contents = rough
        return material
    }

    static func glow(_ color: UIColor, alpha: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.transparency = alpha
        return material
    }

    static func node(_ geometry: SCNGeometry, _ material: SCNMaterial, at position: SCNVector3 = SCNVector3Zero) -> SCNNode {
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = position
        return node
    }

    /// Models drawn along +y (nose up) are turned so the nose faces -z.
    static func pointingForward(_ node: SCNNode) -> SCNNode {
        let wrapper = SCNNode()
        node.eulerAngles.x = -.pi / 2
        wrapper.addChildNode(node)
        return wrapper
    }

    // MARK: Satellite

    static func satellite() -> SCNNode {
        let root = SCNNode()
        let gold = pbr(UIColor(red: 0.86, green: 0.66, blue: 0.24, alpha: 1), metal: 1, rough: 0.32)
        let steel = pbr(UIColor(white: 0.8, alpha: 1), metal: 0.9, rough: 0.3)
        let panel = pbr(UIColor(red: 0.12, green: 0.22, blue: 0.62, alpha: 1), metal: 0.7, rough: 0.22)
        panel.diffuse.contents = OrbitTextures.solarPanel()

        root.addChildNode(node(SCNBox(width: 0.075, height: 0.075, length: 0.1, chamferRadius: 0.006), gold))
        for side: Float in [-1, 1] {
            root.addChildNode(node(SCNCylinder(radius: 0.004, height: 0.05), steel, at: SCNVector3(side * 0.06, 0, 0)).rotatedZ(.pi / 2))
            root.addChildNode(node(SCNBox(width: 0.17, height: 0.004, length: 0.065, chamferRadius: 0.001), panel, at: SCNVector3(side * 0.17, 0, 0)))
        }
        let dish = node(SCNCone(topRadius: 0.042, bottomRadius: 0.008, height: 0.022), pbr(.white, metal: 0.2, rough: 0.4), at: SCNVector3(0, 0.055, 0))
        root.addChildNode(dish)
        root.addChildNode(node(SCNCylinder(radius: 0.003, height: 0.05), steel, at: SCNVector3(0, 0.075, 0)))
        root.addChildNode(node(SCNSphere(radius: 0.007), glow(UIColor(red: 1, green: 0.25, blue: 0.3, alpha: 1)), at: SCNVector3(0, 0.1, 0)))
        return root
    }

    // MARK: Rocket

    static func rocket() -> SCNNode {
        let body = SCNNode()
        let white = pbr(UIColor(white: 0.96, alpha: 1), metal: 0.15, rough: 0.35)
        let red = pbr(UIColor(red: 0.92, green: 0.18, blue: 0.26, alpha: 1), metal: 0.2, rough: 0.35)
        let dark = pbr(UIColor(white: 0.25, alpha: 1), metal: 0.9, rough: 0.35)

        body.addChildNode(node(SCNCylinder(radius: 0.03, height: 0.14), white))
        body.addChildNode(node(SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.065), red, at: SCNVector3(0, 0.1025, 0)))
        body.addChildNode(node(SCNSphere(radius: 0.012), pbr(UIColor(red: 0.3, green: 0.75, blue: 1, alpha: 1), metal: 0.8, rough: 0.1), at: SCNVector3(0, 0.03, 0.025)))
        body.addChildNode(node(SCNCone(topRadius: 0.019, bottomRadius: 0.026, height: 0.022), dark, at: SCNVector3(0, -0.081, 0)))
        for index in 0..<3 {
            let fin = SCNNode()
            fin.eulerAngles.y = Float(index) * 2 * .pi / 3
            fin.addChildNode(node(SCNBox(width: 0.006, height: 0.05, length: 0.04, chamferRadius: 0.002), red, at: SCNVector3(0, -0.05, 0.04)))
            body.addChildNode(fin)
        }
        let flame = node(SCNCone(topRadius: 0.021, bottomRadius: 0, height: 0.08), glow(UIColor(red: 1, green: 0.58, blue: 0.15, alpha: 1), alpha: 0.9), at: SCNVector3(0, -0.132, 0))
        flame.geometry?.firstMaterial?.blendMode = .add
        flame.geometry?.firstMaterial?.writesToDepthBuffer = false
        let core = node(SCNCone(topRadius: 0.012, bottomRadius: 0, height: 0.05), glow(UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1)), at: SCNVector3(0, -0.118, 0))
        flame.runAction(.repeatForever(.sequence([
            .scale(to: 1.18, duration: 0.09),
            .scale(to: 0.88, duration: 0.11),
        ])))
        body.addChildNode(flame)
        body.addChildNode(core)
        body.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 6)))
        return pointingForward(body)
    }

    // MARK: UFO

    static func ufo() -> SCNNode {
        let root = SCNNode()
        let saucer = SCNNode()
        let hull = node(SCNSphere(radius: 0.09), pbr(UIColor(white: 0.78, alpha: 1), metal: 1, rough: 0.22))
        hull.scale = SCNVector3(1, 0.26, 1)
        saucer.addChildNode(hull)
        let domeMaterial = pbr(UIColor(red: 0.45, green: 1, blue: 0.85, alpha: 1), metal: 0.3, rough: 0.05)
        domeMaterial.emission.contents = UIColor(red: 0.1, green: 0.45, blue: 0.38, alpha: 1)
        domeMaterial.transparency = 0.85
        saucer.addChildNode(node(SCNSphere(radius: 0.042), domeMaterial, at: SCNVector3(0, 0.018, 0)))
        let colors: [UIColor] = [.systemYellow, .systemPink, .systemTeal]
        for index in 0..<10 {
            let angle = Float(index) / 10 * 2 * .pi
            saucer.addChildNode(node(SCNSphere(radius: 0.008), glow(colors[index % colors.count]), at: SCNVector3(cos(angle) * 0.078, -0.004, sin(angle) * 0.078)))
        }
        root.addChildNode(saucer)
        root.eulerAngles.x = 0.35
        return root
    }

    // MARK: Moon

    static func moon() -> SCNNode {
        let root = SCNNode()
        let sphere = SCNSphere(radius: 0.08)
        sphere.segmentCount = 48
        let material = pbr(.white, rough: 0.95)
        material.diffuse.contents = OrbitTextures.moon()
        material.normal.contents = OrbitTextures.moonBumps()
        material.normal.intensity = 0.6
        root.addChildNode(node(sphere, material))
        return root
    }

    // MARK: Ringed planet

    static func ringedPlanet() -> SCNNode {
        let root = SCNNode()
        let body = SCNNode()
        let sphere = SCNSphere(radius: 0.065)
        sphere.segmentCount = 48
        let material = pbr(.white, rough: 0.7)
        material.diffuse.contents = OrbitTextures.bands()
        body.addChildNode(node(sphere, material))
        let ringMaterial = pbr(UIColor(red: 0.95, green: 0.86, blue: 0.68, alpha: 1), rough: 0.6)
        ringMaterial.diffuse.contents = OrbitTextures.ring()
        ringMaterial.isDoubleSided = true
        ringMaterial.transparency = 0.9
        let ring = node(SCNTube(innerRadius: 0.088, outerRadius: 0.14, height: 0.002), ringMaterial)
        body.addChildNode(ring)
        root.addChildNode(body)
        root.eulerAngles = SCNVector3(0.45, 0, 0.3)
        return root
    }

    // MARK: Airliner

    static func airliner() -> SCNNode {
        let plane = SCNNode()
        let white = pbr(UIColor(white: 0.97, alpha: 1), metal: 0.25, rough: 0.3)
        let violet = pbr(UIColor(red: 0.47, green: 0.3, blue: 0.95, alpha: 1), metal: 0.3, rough: 0.3)
        let grey = pbr(UIColor(white: 0.6, alpha: 1), metal: 0.9, rough: 0.3)

        plane.addChildNode(node(SCNCapsule(capRadius: 0.017, height: 0.17), white))
        // In this frame +y is the nose and +z is up.
        plane.addChildNode(node(SCNBox(width: 0.2, height: 0.04, length: 0.005, chamferRadius: 0.002), white, at: SCNVector3(0, 0.005, -0.004)))
        plane.addChildNode(node(SCNBox(width: 0.07, height: 0.022, length: 0.004, chamferRadius: 0.001), white, at: SCNVector3(0, -0.07, 0.002)))
        plane.addChildNode(node(SCNBox(width: 0.004, height: 0.032, length: 0.04, chamferRadius: 0.001), violet, at: SCNVector3(0, -0.068, 0.025)))
        for side: Float in [-1, 1] {
            plane.addChildNode(node(SCNCylinder(radius: 0.008, height: 0.028), grey, at: SCNVector3(side * 0.045, 0.012, -0.013)))
        }
        plane.addChildNode(node(SCNSphere(radius: 0.004), glow(.systemRed), at: SCNVector3(-0.1, 0.005, -0.004)))
        plane.addChildNode(node(SCNSphere(radius: 0.004), glow(.systemGreen), at: SCNVector3(0.1, 0.005, -0.004)))
        return pointingForward(plane)
    }

    // MARK: Comet

    static func comet() -> SCNNode {
        let comet = SCNNode()
        comet.addChildNode(node(SCNSphere(radius: 0.026), glow(UIColor(red: 0.85, green: 0.97, blue: 1, alpha: 1))))
        let halo = node(SCNSphere(radius: 0.045), glow(UIColor(red: 0.45, green: 0.8, blue: 1, alpha: 1), alpha: 0.35))
        halo.geometry?.firstMaterial?.blendMode = .add
        halo.geometry?.firstMaterial?.writesToDepthBuffer = false
        comet.addChildNode(halo)
        let tail = node(SCNCone(topRadius: 0.03, bottomRadius: 0, height: 0.26), glow(UIColor(red: 0.4, green: 0.78, blue: 1, alpha: 1), alpha: 0.55), at: SCNVector3(0, -0.13, 0))
        tail.geometry?.firstMaterial?.blendMode = .add
        tail.geometry?.firstMaterial?.writesToDepthBuffer = false
        comet.addChildNode(tail)
        halo.runAction(.repeatForever(.sequence([
            .scale(to: 1.15, duration: 0.6),
            .scale(to: 0.92, duration: 0.6),
        ])))
        return pointingForward(comet)
    }

    // MARK: Hot air balloon

    static func balloon() -> SCNNode {
        let root = SCNNode()
        let envelopeMaterial = pbr(.white, rough: 0.55)
        envelopeMaterial.diffuse.contents = OrbitTextures.balloon()
        let envelope = node(SCNSphere(radius: 0.065), envelopeMaterial, at: SCNVector3(0, 0.03, 0))
        envelope.scale = SCNVector3(1, 1.15, 1)
        root.addChildNode(envelope)
        root.addChildNode(node(SCNCone(topRadius: 0.036, bottomRadius: 0.016, height: 0.04), envelopeMaterial, at: SCNVector3(0, -0.045, 0)))
        let rope = pbr(UIColor(white: 0.35, alpha: 1), rough: 0.8)
        for (x, z) in [(Float(-1), Float(-1)), (1, -1), (-1, 1), (1, 1)] {
            root.addChildNode(node(SCNCylinder(radius: 0.0012, height: 0.035), rope, at: SCNVector3(x * 0.012, -0.08, z * 0.012)))
        }
        root.addChildNode(node(SCNBox(width: 0.03, height: 0.022, length: 0.03, chamferRadius: 0.003), pbr(UIColor(red: 0.55, green: 0.36, blue: 0.2, alpha: 1), rough: 0.9), at: SCNVector3(0, -0.105, 0)))
        return root
    }
}

@MainActor
private extension SCNNode {
    func rotatedZ(_ angle: Float) -> SCNNode {
        eulerAngles.z = angle
        return self
    }
}

// MARK: - Generated textures

@MainActor
private enum OrbitTextures {
    static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
    }

    /// A soft sky for reflections on metal and glass.
    static func environment() -> UIImage {
        render(CGSize(width: 256, height: 128)) { ctx in
            let colors = [
                UIColor(red: 0.85, green: 0.9, blue: 1, alpha: 1).cgColor,
                UIColor(red: 0.42, green: 0.5, blue: 0.75, alpha: 1).cgColor,
                UIColor(red: 0.08, green: 0.09, blue: 0.16, alpha: 1).cgColor,
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
            }
        }
    }

    static func solarPanel() -> UIImage {
        render(CGSize(width: 128, height: 64)) { ctx in
            ctx.setFillColor(UIColor(red: 0.1, green: 0.18, blue: 0.5, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
            ctx.setStrokeColor(UIColor(red: 0.6, green: 0.7, blue: 0.95, alpha: 1).cgColor)
            ctx.setLineWidth(1.5)
            for x in stride(from: 0, through: 128, by: 16) {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: 64))
            }
            for y in stride(from: 0, through: 64, by: 16) {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: 128, y: y))
            }
            ctx.strokePath()
        }
    }

    /// Fixed crater layout, so the moon looks the same every time.
    private static let craters: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (40, 40, 14), (120, 70, 20), (200, 36, 10), (230, 90, 16), (80, 96, 9),
        (160, 24, 8), (20, 80, 11), (180, 105, 7), (100, 30, 6), (250, 50, 8),
    ]

    static func moon() -> UIImage {
        render(CGSize(width: 256, height: 128)) { ctx in
            ctx.setFillColor(UIColor(white: 0.74, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            ctx.setFillColor(UIColor(white: 0.6, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 130, y: 40, width: 80, height: 40))
            ctx.fillEllipse(in: CGRect(x: 30, y: 60, width: 60, height: 30))
            for crater in craters {
                ctx.setFillColor(UIColor(white: 0.52, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: crater.x - crater.r, y: crater.y - crater.r, width: crater.r * 2, height: crater.r * 2))
                ctx.setFillColor(UIColor(white: 0.66, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: crater.x - crater.r * 0.7, y: crater.y - crater.r * 0.55, width: crater.r * 1.4, height: crater.r * 1.4))
            }
        }
    }

    /// Normal map with dents where the craters are.
    static func moonBumps() -> UIImage {
        render(CGSize(width: 256, height: 128)) { ctx in
            ctx.setFillColor(UIColor(red: 0.5, green: 0.5, blue: 1, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            for crater in craters {
                ctx.setFillColor(UIColor(red: 0.32, green: 0.36, blue: 0.95, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: crater.x - crater.r, y: crater.y - crater.r, width: crater.r, height: crater.r * 2))
                ctx.setFillColor(UIColor(red: 0.68, green: 0.64, blue: 0.95, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: crater.x, y: crater.y - crater.r, width: crater.r, height: crater.r * 2))
            }
        }
    }

    static func bands() -> UIImage {
        render(CGSize(width: 64, height: 128)) { ctx in
            let colors: [UIColor] = [
                UIColor(red: 0.95, green: 0.78, blue: 0.5, alpha: 1),
                UIColor(red: 0.85, green: 0.55, blue: 0.3, alpha: 1),
                UIColor(red: 0.98, green: 0.88, blue: 0.68, alpha: 1),
                UIColor(red: 0.78, green: 0.45, blue: 0.28, alpha: 1),
            ]
            var y: CGFloat = 0
            var index = 0
            let heights: [CGFloat] = [14, 9, 18, 7, 12, 16, 8, 13, 10, 21]
            while y < 128 {
                let height = heights[index % heights.count]
                ctx.setFillColor(colors[index % colors.count].cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: 64, height: height))
                y += height
                index += 1
            }
        }
    }

    static func ring() -> UIImage {
        render(CGSize(width: 128, height: 16)) { ctx in
            for x in 0..<128 {
                let shade = 0.65 + 0.3 * abs(sin(CGFloat(x) * 0.37))
                ctx.setFillColor(UIColor(red: shade, green: shade * 0.9, blue: shade * 0.72, alpha: 1).cgColor)
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: 16))
            }
        }
    }

    static func balloon() -> UIImage {
        render(CGSize(width: 128, height: 64)) { ctx in
            let colors: [UIColor] = [
                UIColor(red: 0.95, green: 0.25, blue: 0.35, alpha: 1),
                UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1),
                UIColor(red: 0.47, green: 0.3, blue: 0.95, alpha: 1),
                UIColor(white: 0.98, alpha: 1),
            ]
            for index in 0..<8 {
                ctx.setFillColor(colors[index % colors.count].cgColor)
                ctx.fill(CGRect(x: CGFloat(index) * 16, y: 0, width: 16, height: 64))
            }
        }
    }
}
