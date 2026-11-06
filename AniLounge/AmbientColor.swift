import SwiftUI
import CoreImage
import AniCore

/// Average colour of an artwork, pulled to a calm, dark tone so text on top stays readable.
/// Netflix and Disney+ tint the top of the screen with the artwork this way.
@MainActor enum AmbientColor {
    private static var cache: [URL: Color] = [:]
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    static func color(for url: URL?) async -> Color? {
        guard let url else { return nil }
        if let cached = cache[url] { return cached }
        guard let image = await CoverLoader.image(for: url), let color = average(image) else { return nil }
        cache[url] = color
        return color
    }
    static func color(for anime: Anime) async -> Color? {
        if let backdrop = await AniClient.shared.backdrop(for: anime), let color = await color(for: backdrop) { return color }
        return await color(for: await AniClient.shared.cover(for: anime))
    }
    private static func average(_ image: UIImage) -> Color? {
        guard let input = CIImage(image: image),
              let output = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)])?.outputImage
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Keep the hue, give grey art a little colour, and never get bright enough to fight the text.
        return Color(hue: Double(hue), saturation: Double(min(0.75, max(0.35, saturation * 1.4))), brightness: Double(min(0.42, max(0.24, brightness))))
    }
}
