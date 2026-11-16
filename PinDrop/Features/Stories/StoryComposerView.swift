import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Effects

/// The photo effects of the story editor (swipe on the photo or pick one below).
enum StoryEffect: String, CaseIterable, Identifiable, Sendable {
    case original
    case vivid
    case sunset
    case ice
    case neon
    case dream
    case glitch
    case film
    case vintage
    case noir

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .original: "story.effect.original"
        case .vivid: "story.effect.vivid"
        case .sunset: "story.effect.sunset"
        case .ice: "story.effect.ice"
        case .neon: "story.effect.neon"
        case .dream: "story.effect.dream"
        case .glitch: "story.effect.glitch"
        case .film: "story.effect.film"
        case .vintage: "story.effect.vintage"
        case .noir: "story.effect.noir"
        }
    }

    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Applies the effect off the main thread.
    nonisolated static func render(_ effect: StoryEffect, on image: UIImage) async -> UIImage {
        effect.apply(to: image) ?? image
    }

    nonisolated func apply(to image: UIImage) -> UIImage? {
        guard self != .original else { return image }
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage).oriented(CGImagePropertyOrientation(image.imageOrientation))
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1_000
        guard let output = filtered(input, unit: unit)?.cropped(to: extent),
              let result = Self.context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: result)
    }

    /// The effect on a Core Image frame (video frames use this too).
    nonisolated func applyCI(_ input: CIImage) -> CIImage {
        guard self != .original else { return input }
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1_000
        return filtered(input, unit: unit)?.cropped(to: extent) ?? input
    }

    nonisolated private func filtered(_ input: CIImage, unit: CGFloat) -> CIImage? {
        switch self {
        case .original:
            return input
        case .vivid:
            let controls = CIFilter.colorControls()
            controls.inputImage = input
            controls.saturation = 1.35
            controls.contrast = 1.1
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = controls.outputImage
            vibrance.amount = 0.6
            return vibrance.outputImage
        case .sunset:
            return colorMatrix(input, r: (1.12, 0.04), g: (0.98, 0.01), b: (0.78, -0.02))
                .flatMap { vignette($0, intensity: 0.6, radius: 1.6) }
        case .ice:
            let controls = CIFilter.colorControls()
            controls.inputImage = colorMatrix(input, r: (0.86, 0), g: (1.0, 0.02), b: (1.16, 0.05))
            controls.saturation = 0.85
            controls.brightness = 0.02
            return controls.outputImage
        case .neon:
            let controls = CIFilter.colorControls()
            controls.inputImage = input
            controls.saturation = 1.8
            controls.contrast = 1.2
            let bloom = CIFilter.bloom()
            bloom.inputImage = controls.outputImage
            bloom.radius = Float(14 * unit)
            bloom.intensity = 0.9
            return bloom.outputImage.flatMap { colorMatrix($0, r: (1.05, 0.03), g: (0.9, 0), b: (1.15, 0.06)) }
        case .dream:
            let bloom = CIFilter.bloom()
            bloom.inputImage = input
            bloom.radius = Float(26 * unit)
            bloom.intensity = 1.0
            let controls = CIFilter.colorControls()
            controls.inputImage = bloom.outputImage
            controls.brightness = 0.04
            controls.saturation = 1.1
            return controls.outputImage.flatMap { colorMatrix($0, r: (1.04, 0.05), g: (0.96, 0.02), b: (1.04, 0.07)) }
        case .glitch:
            // Red and blue channels pulled apart, plus thin scan lines.
            let shift = 9 * unit
            guard let red = colorMatrix(input, r: (1, 0), g: (0, 0), b: (0, 0))?.transformed(by: CGAffineTransform(translationX: shift, y: 0)),
                  let green = colorMatrix(input, r: (0, 0), g: (1, 0), b: (0, 0)),
                  let blue = colorMatrix(input, r: (0, 0), g: (0, 0), b: (1, 0))?.transformed(by: CGAffineTransform(translationX: -shift, y: shift * 0.4)) else { return nil }
            let add1 = CIFilter.additionCompositing()
            add1.inputImage = red
            add1.backgroundImage = green
            let add2 = CIFilter.additionCompositing()
            add2.inputImage = blue
            add2.backgroundImage = add1.outputImage
            let lines = CIFilter.stripesGenerator()
            lines.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.18)
            lines.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            lines.width = Float(2 * unit)
            let rotate = lines.outputImage?.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = rotate
            over.backgroundImage = add2.outputImage
            let controls = CIFilter.colorControls()
            controls.inputImage = over.outputImage
            controls.contrast = 1.15
            controls.saturation = 1.2
            return controls.outputImage
        case .film:
            let fade = CIFilter.photoEffectFade()
            fade.inputImage = input
            let noise = CIFilter.randomGenerator().outputImage?
                .transformed(by: CGAffineTransform(scaleX: max(1, unit), y: max(1, unit)))
            let grain = noise.flatMap { colorMatrixAlpha($0, alpha: 0.07) }
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = grain
            over.backgroundImage = fade.outputImage
            return over.outputImage.flatMap { vignette($0, intensity: 0.8, radius: 1.4) }
        case .vintage:
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = input
            sepia.intensity = 0.55
            let controls = CIFilter.colorControls()
            controls.inputImage = sepia.outputImage
            controls.contrast = 0.92
            controls.brightness = 0.03
            return controls.outputImage.flatMap { vignette($0, intensity: 1.1, radius: 1.5) }
        case .noir:
            let noir = CIFilter.photoEffectNoir()
            noir.inputImage = input
            let controls = CIFilter.colorControls()
            controls.inputImage = noir.outputImage
            controls.contrast = 1.15
            return controls.outputImage
        }
    }

    nonisolated private func colorMatrix(_ image: CIImage, r: (CGFloat, CGFloat), g: (CGFloat, CGFloat), b: (CGFloat, CGFloat)) -> CIImage? {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: r.0, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: g.0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: b.0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: r.1, y: g.1, z: b.1, w: 0)
        return matrix.outputImage
    }

    /// Grey noise with a low alpha, to lay over the photo as film grain.
    nonisolated private func colorMatrixAlpha(_ image: CIImage, alpha: CGFloat) -> CIImage? {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        return matrix.outputImage
    }

    nonisolated private func vignette(_ image: CIImage, intensity: Float, radius: Float) -> CIImage? {
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = intensity
        filter.radius = radius
        return filter.outputImage
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Layers

/// Something placed on the story: a text, the place sticker or the time sticker.
struct StoryLayer: Identifiable {
    enum Kind: Hashable {
        case text
        case location
        case time
    }

    enum TextStyle: Int, CaseIterable, Hashable {
        case classic
        case pill
        case neon
        case typewriter

        var icon: String {
            switch self {
            case .classic: "textformat"
            case .pill: "capsule.fill"
            case .neon: "sparkles"
            case .typewriter: "keyboard"
            }
        }
    }

    static let colors: [Color] = [
        .white, .black, Color(hex: 0xA855F7), Color(hex: 0xEC4899), Color(hex: 0xF43F5E),
        Color(hex: 0xF59E0B), Color(hex: 0xFACC15), Color(hex: 0x10B981), Color(hex: 0x38BDF8)
    ]

    let id = UUID()
    var kind: Kind
    var text: String
    var style: TextStyle = .classic
    var colorIndex = 0
    /// Center of the layer, 0...1 on both axes of the story.
    var center = CGPoint(x: 0.5, y: 0.45)
    var scale: CGFloat = 1
    var rotation: Angle = .zero
    /// Look of the stickers (tap to change).
    var variant = 0

    var color: Color { Self.colors[colorIndex % Self.colors.count] }
}

/// Draws one layer. `unit` is the story width divided by 360, so the editor and the
/// exported picture look the same.
struct StoryLayerView: View {
    let layer: StoryLayer
    let unit: CGFloat

    var body: some View {
        switch layer.kind {
        case .text:
            textView
        case .location:
            sticker(icon: "mappin.circle.fill", iconColor: Theme.emeraldLight)
        case .time:
            sticker(icon: "clock.fill", iconColor: Color(hex: 0xFACC15))
        }
    }

    @ViewBuilder
    private var textView: some View {
        let contrast: Color = layer.colorIndex == 0 ? .black : .white
        switch layer.style {
        case .classic:
            Text(verbatim: layer.text)
                .font(.system(size: 30 * unit, weight: .heavy, design: .rounded))
                .foregroundStyle(layer.color)
                .multilineTextAlignment(.center)
                .shadow(color: Color.black.opacity(layer.colorIndex == 1 ? 0 : 0.45), radius: 6 * unit, y: 2 * unit)
        case .pill:
            Text(verbatim: layer.text)
                .font(.system(size: 26 * unit, weight: .bold, design: .rounded))
                .foregroundStyle(layer.colorIndex == 0 ? Color.black : Color.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16 * unit)
                .padding(.vertical, 9 * unit)
                .background(layer.colorIndex == 0 ? Color.white : layer.color, in: RoundedRectangle(cornerRadius: 14 * unit, style: .continuous))
        case .neon:
            Text(verbatim: layer.text)
                .font(.system(size: 32 * unit, weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .shadow(color: neonColor, radius: 4 * unit)
                .shadow(color: neonColor, radius: 12 * unit)
                .shadow(color: neonColor.opacity(0.8), radius: 24 * unit)
        case .typewriter:
            Text(verbatim: layer.text)
                .font(.system(size: 22 * unit, weight: .semibold, design: .monospaced))
                .foregroundStyle(layer.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10 * unit)
                .padding(.vertical, 6 * unit)
                .background(contrast.opacity(0.85))
        }
    }

    private var neonColor: Color {
        layer.colorIndex <= 1 ? Color(hex: 0xA855F7) : layer.color
    }

    @ViewBuilder
    private func sticker(icon: String, iconColor: Color) -> some View {
        let label = HStack(spacing: 6 * unit) {
            Image(systemName: icon)
                .foregroundStyle(layer.variant == 1 ? Color(hex: 0x7C3AED) : iconColor)
            Text(verbatim: layer.text.uppercased())
                .lineLimit(1)
        }
        .font(.system(size: 17 * unit, weight: .heavy, design: .rounded))
        .padding(.horizontal, 14 * unit)
        .padding(.vertical, 9 * unit)

        switch layer.variant % 3 {
        case 1:
            label
                .foregroundStyle(Color(hex: 0x7C3AED))
                .background(Color.white, in: Capsule())
                .shadow(color: Color.black.opacity(0.25), radius: 8 * unit, y: 3 * unit)
        case 2:
            label
                .foregroundStyle(Color.white)
                .background(StoryRingStyle.linear, in: Capsule())
                .shadow(color: Color(hex: 0xEC4899).opacity(0.4), radius: 10 * unit, y: 3 * unit)
        default:
            label
                .foregroundStyle(Color.white)
                .background(Color.black.opacity(0.45), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1 * unit) }
        }
    }
}

/// The story itself: photo with its effect and every layer. Used on screen and for the export.
struct StoryCanvas: View {
    /// `nil` draws only the layers on a transparent background (laid over videos).
    let image: UIImage?
    let layers: [StoryLayer]
    let size: CGSize

    var body: some View {
        let unit = size.width / 360
        ZStack {
            if let image {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.clear
            }
            ForEach(layers) { layer in
                StoryLayerView(layer: layer, unit: unit)
                    .frame(maxWidth: size.width * 0.9)
                    .scaleEffect(layer.scale)
                    .rotationEffect(layer.rotation)
                    .position(x: layer.center.x * size.width, y: layer.center.y * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - Editor

/// Full screen story editor: effects, texts and stickers, all optional.
struct StoryComposerView: View {
    static let exportSize = CGSize(width: 360, height: 640)

    let shot: CapturedShot
    let onRetake: () -> Void
    let onPublished: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(LocationService.self) private var locationService

    @State private var effect: StoryEffect = .original
    @State private var filteredImage: UIImage?
    @State private var thumbnails: [StoryEffect: UIImage] = [:]
    @State private var layers: [StoryLayer] = []
    @State private var placeName: String?
    @State private var editingID: UUID?
    @State private var editText = ""
    @State private var editStyle: StoryLayer.TextStyle = .classic
    @State private var editColor = 0
    @State private var draggingID: UUID?
    @State private var isOverTrash = false
    @State private var gestureStart: StoryLayer?
    @State private var effectBanner: StoryEffect?
    @State private var isPublishing = false
    @State private var videoComposition: AVVideoComposition?
    @State private var errorMessage: String?
    @FocusState private var isTextFocused: Bool

    private var displayImage: UIImage { filteredImage ?? shot.previewImage }
    private var isEditing: Bool { editingID != nil }

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = canvasSize(in: proxy.size)
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 10) {
                    canvas(size: canvasSize)
                        .overlay(alignment: .top) { topBar.padding(12) }
                        .overlay(alignment: .trailing) {
                            if !isEditing && draggingID == nil {
                                toolColumn.padding(.trailing, 10)
                            }
                        }
                        .overlay(alignment: .bottom) { trash.padding(.bottom, 18) }
                        .overlay {
                            if let effectBanner {
                                Text(effectBanner.title)
                                    .font(Theme.rounded(.title2, weight: .heavy))
                                    .foregroundStyle(Color.white)
                                    .shadow(color: Color.black.opacity(0.5), radius: 8)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                    .allowsHitTesting(false)
                            }
                        }
                    if !isEditing {
                        effectStrip
                        publishBar
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)

                if isEditing {
                    textEditor
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .animation(Theme.spring, value: isEditing)
        .animation(Theme.spring, value: draggingID)
        .task {
            if let location = shot.location {
                placeName = await locationService.placeName(for: location)
            }
        }
        .task {
            await makeThumbnails()
        }
        .task(id: effect) {
            let image = shot.previewImage
            let rendered = await StoryEffect.render(effect, on: image)
            filteredImage = rendered
            if let video = shot.videoURL {
                videoComposition = await VideoTools.previewComposition(for: video, effect: effect)
            }
        }
    }

    private func canvasSize(in size: CGSize) -> CGSize {
        let maxHeight = size.height - 190
        let width = min(size.width - 8, maxHeight * 9 / 16)
        return CGSize(width: width, height: width * 16 / 9)
    }

    // MARK: Canvas

    private func canvas(size: CGSize) -> some View {
        ZStack {
            Color.black
            Image(uiImage: displayImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    if let video = shot.videoURL {
                        LoopingVideoView(url: video, composition: videoComposition, compositionID: videoComposition == nil ? "original" : effect.rawValue)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(swipeGesture)
                .onTapGesture {
                    guard !isEditing else { return }
                    startEditing(nil)
                }
            ForEach(layers) { layer in
                StoryLayerView(layer: layer, unit: size.width / 360)
                    .frame(maxWidth: size.width * 0.9)
                    .scaleEffect(layer.scale * (draggingID == layer.id && isOverTrash ? 0.5 : 1))
                    .rotationEffect(layer.rotation)
                    .opacity(editingID == layer.id ? 0 : 1)
                    .position(x: layer.center.x * size.width, y: layer.center.y * size.height)
                    .gesture(layerGesture(layer.id, size: size))
                    .onTapGesture {
                        tap(layer)
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var topBar: some View {
        HStack {
            Button {
                HapticManager.shared.tap()
                onRetake()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(Text("post.retake"))
            Spacer()
        }
        .opacity(isEditing || draggingID != nil ? 0 : 1)
    }

    private var toolColumn: some View {
        VStack(spacing: 14) {
            toolButton("textformat", label: "story.tool.text") {
                startEditing(nil)
            }
            if let placeName {
                toolButton("mappin.and.ellipse", label: "story.tool.place", isOn: layers.contains { $0.kind == .location }) {
                    toggleSticker(.location, text: placeName)
                }
            }
            toolButton("clock", label: "story.tool.time", isOn: layers.contains { $0.kind == .time }) {
                toggleSticker(.time, text: shot.capturedAt.formatted(date: .omitted, time: .shortened))
            }
            toolButton("wand.and.stars", label: "story.tool.random") {
                randomEffect()
            }
        }
    }

    private func toolButton(_ icon: String, label: LocalizedStringKey, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.selection()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(isOn ? Color.black : Color.white)
                .frame(width: 44, height: 44)
                .background(isOn ? Color.white : Color.black.opacity(0.35), in: Circle())
                .shadow(color: Color.black.opacity(0.3), radius: 6)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private var trash: some View {
        if draggingID != nil {
            Image(systemName: "trash")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(isOverTrash ? Color.white : Color.white.opacity(0.9))
                .frame(width: isOverTrash ? 60 : 48, height: isOverTrash ? 60 : 48)
                .background(isOverTrash ? Theme.danger : Color.black.opacity(0.45), in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5) }
                .transition(.scale.combined(with: .opacity))
                .animation(Theme.spring, value: isOverTrash)
        }
    }

    // MARK: Effects strip

    private var effectStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(StoryEffect.allCases) { item in
                        Button {
                            select(item)
                        } label: {
                            VStack(spacing: 5) {
                                Group {
                                    if let thumb = thumbnails[item] {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Color.white.opacity(0.08)
                                    }
                                }
                                .frame(width: 54, height: 54)
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(effect == item ? AnyShapeStyle(StoryRingStyle.angular) : AnyShapeStyle(Color.white.opacity(0.2)), lineWidth: effect == item ? 3 : 1)
                                }
                                Text(item.title)
                                    .font(Theme.rounded(.caption2, weight: .bold))
                                    .foregroundStyle(effect == item ? Color.white : Color.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                            .frame(width: 62)
                        }
                        .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
                        .id(item)
                    }
                }
                .padding(.horizontal, 14)
            }
            .onChange(of: effect) { _, value in
                withAnimation(Theme.spring) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private var publishBar: some View {
        HStack(spacing: 10) {
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(Theme.text(.caption, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                publish()
            } label: {
                HStack(spacing: 8) {
                    AvatarBadge(user: appState.currentUser, size: 28)
                        .padding(2)
                        .overlay { Circle().strokeBorder(StoryRingStyle.angular, lineWidth: 2) }
                    Text("story.yours")
                        .font(Theme.rounded(.subheadline, weight: .bold))
                    if isPublishing {
                        ProgressView().tint(Color.black)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .heavy))
                    }
                }
                .foregroundStyle(Color.black)
                .padding(.leading, 6)
                .padding(.trailing, 16)
                .padding(.vertical, 6)
                .background(Color.white, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
            .disabled(isPublishing)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Text editor

    private var textEditor: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { finishEditing() }
            VStack(spacing: 16) {
                HStack {
                    HStack(spacing: 8) {
                        ForEach(StoryLayer.TextStyle.allCases, id: \.self) { style in
                            Button {
                                HapticManager.shared.selection()
                                editStyle = style
                            } label: {
                                Image(systemName: style.icon)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(editStyle == style ? Color.black : Color.white)
                                    .frame(width: 38, height: 38)
                                    .background(editStyle == style ? Color.white : Color.white.opacity(0.15), in: Circle())
                            }
                        }
                    }
                    Spacer()
                    Button {
                        finishEditing()
                    } label: {
                        Text("common.done")
                            .font(Theme.rounded(.headline, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                TextField("", text: $editText, prompt: Text("story.text.placeholder").foregroundStyle(Color.white.opacity(0.5)), axis: .vertical)
                    .font(.system(size: 30, weight: .heavy, design: editStyle == .typewriter ? .monospaced : .rounded))
                    .foregroundStyle(editStyle == .pill && editColor == 0 ? Color.white : StoryLayer.colors[editColor])
                    .multilineTextAlignment(.center)
                    .lineLimit(1...6)
                    .focused($isTextFocused)
                    .padding(.horizontal, 28)
                    .shadow(color: Color.black.opacity(0.4), radius: 6)

                Spacer()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(StoryLayer.colors.indices, id: \.self) { index in
                            Button {
                                HapticManager.shared.selection()
                                editColor = index
                            } label: {
                                Circle()
                                    .fill(StoryLayer.colors[index])
                                    .frame(width: 30, height: 30)
                                    .overlay { Circle().strokeBorder(Color.white, lineWidth: editColor == index ? 3 : 1.5) }
                                    .scaleEffect(editColor == index ? 1.15 : 1)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                }
                .padding(.bottom, 10)
            }
        }
        .onAppear { isTextFocused = true }
    }

    // MARK: Gestures

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !isEditing, abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 50 else { return }
                let all = StoryEffect.allCases
                guard let index = all.firstIndex(of: effect) else { return }
                let next = value.translation.width < 0 ? min(all.count - 1, index + 1) : max(0, index - 1)
                select(all[next])
            }
    }

    private func layerGesture(_ id: UUID, size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
                if gestureStart?.id != id { gestureStart = layers[index] }
                if draggingID != id { draggingID = id }
                guard let start = gestureStart else { return }
                let x = start.center.x + value.translation.width / size.width
                let y = start.center.y + value.translation.height / size.height
                layers[index].center = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
                let over = y > 0.86 && abs(x - 0.5) < 0.18
                if over != isOverTrash {
                    isOverTrash = over
                    HapticManager.shared.selection()
                }
            }
            .onEnded { _ in
                if isOverTrash {
                    HapticManager.shared.tap()
                    withAnimation(Theme.spring) { layers.removeAll { $0.id == id } }
                }
                isOverTrash = false
                draggingID = nil
                gestureStart = nil
            }
        let pinch = MagnifyGesture()
            .onChanged { value in
                guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
                if gestureStart?.id != id { gestureStart = layers[index] }
                guard let start = gestureStart else { return }
                layers[index].scale = min(4, max(0.4, start.scale * value.magnification))
            }
            .onEnded { _ in gestureStart = nil }
        let rotate = RotateGesture()
            .onChanged { value in
                guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
                if gestureStart?.id != id { gestureStart = layers[index] }
                guard let start = gestureStart else { return }
                layers[index].rotation = .degrees(start.rotation.degrees + value.rotation.degrees)
            }
            .onEnded { _ in gestureStart = nil }
        return drag.simultaneously(with: pinch.simultaneously(with: rotate))
    }

    // MARK: Actions

    private func select(_ value: StoryEffect) {
        guard value != effect else { return }
        HapticManager.shared.selection()
        effect = value
        withAnimation(.easeOut(duration: 0.15)) { effectBanner = value }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if effectBanner == value {
                withAnimation(.easeOut(duration: 0.3)) { effectBanner = nil }
            }
        }
    }

    private func randomEffect() {
        let options = StoryEffect.allCases.filter { $0 != effect && $0 != .original }
        if let pick = options.randomElement() {
            select(pick)
        }
    }

    private func tap(_ layer: StoryLayer) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        if layer.kind == .text {
            startEditing(layer)
        } else {
            HapticManager.shared.selection()
            layers[index].variant = (layers[index].variant + 1) % 3
        }
    }

    private func toggleSticker(_ kind: StoryLayer.Kind, text: String) {
        if layers.contains(where: { $0.kind == kind }) {
            withAnimation(Theme.spring) { layers.removeAll { $0.kind == kind } }
        } else {
            var layer = StoryLayer(kind: kind, text: text)
            layer.center = CGPoint(x: 0.5, y: kind == .location ? 0.7 : 0.18)
            withAnimation(Theme.spring) { layers.append(layer) }
        }
    }

    private func startEditing(_ layer: StoryLayer?) {
        HapticManager.shared.selection()
        if let layer {
            editingID = layer.id
            editText = layer.text
            editStyle = layer.style
            editColor = layer.colorIndex
        } else {
            let new = StoryLayer(kind: .text, text: "", style: editStyle, colorIndex: editColor)
            layers.append(new)
            editingID = new.id
            editText = ""
        }
    }

    private func finishEditing() {
        guard let id = editingID, let index = layers.firstIndex(where: { $0.id == id }) else {
            editingID = nil
            return
        }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            layers.remove(at: index)
        } else {
            layers[index].text = text
            layers[index].style = editStyle
            layers[index].colorIndex = editColor
        }
        isTextFocused = false
        editingID = nil
    }

    private func makeThumbnails() async {
        guard let small = ImageCompressor.downsampleImage(shot.previewImage, maxPixelSize: 160) else { return }
        for item in StoryEffect.allCases {
            let rendered = await StoryEffect.render(item, on: small)
            thumbnails[item] = rendered
        }
    }

    private func publish() {
        guard !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        if let video = shot.videoURL {
            publishVideo(video)
            return
        }
        let renderer = ImageRenderer(content: StoryCanvas(image: displayImage, layers: layers, size: Self.exportSize))
        renderer.scale = 3
        guard let data = renderer.uiImage?.jpegData(compressionQuality: 0.85) else {
            isPublishing = false
            errorMessage = String(localized: "toast.error.title")
            return
        }
        let tag = layers.contains { $0.kind == .location } ? placeName : nil
        Task {
            do {
                try await appState.social.publishStory(photo: data, overlayText: "", overlayY: 0.5, locationTag: tag)
                HapticManager.shared.success()
                appState.showToast(.success, title: String(localized: "story.published.title"), subtitle: String(localized: "story.published.subtitle"))
                isPublishing = false
                onPublished()
            } catch {
                HapticManager.shared.error()
                errorMessage = error.localizedDescription
                isPublishing = false
            }
        }
    }
}

extension StoryComposerView {
    /// Video stories: effect and layers are burned into a 9:16 clip, its first frame is the photo.
    private func publishVideo(_ video: URL) {
        let overlayRenderer = ImageRenderer(content: StoryCanvas(image: nil, layers: layers, size: Self.exportSize))
        overlayRenderer.scale = 2
        overlayRenderer.isOpaque = false
        let overlay = layers.isEmpty ? nil : overlayRenderer.uiImage
        let chosenEffect = effect
        let tag = layers.contains { $0.kind == .location } ? placeName : nil
        Task {
            do {
                let exported = try await VideoTools.exportStory(video: video, effect: chosenEffect, overlay: overlay)
                guard let poster = await VideoTools.posterJPEG(for: exported) else { throw CameraError.captureFailed }
                try await appState.social.publishStory(photo: poster, video: exported, overlayText: "", overlayY: 0.5, locationTag: tag)
                HapticManager.shared.success()
                appState.showToast(.success, title: String(localized: "story.published.title"), subtitle: String(localized: "story.published.subtitle"))
                isPublishing = false
                onPublished()
            } catch {
                HapticManager.shared.error()
                errorMessage = error.localizedDescription
                isPublishing = false
            }
        }
    }
}

extension ImageCompressor {
    /// A small copy of an image, for previews.
    static func downsampleImage(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let factor = min(1, maxPixelSize / longest)
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
