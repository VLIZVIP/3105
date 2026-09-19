import SwiftUI
import ImageIO

enum AppAppearanceKeys {
    static let accent = "inject.appearance.accent"
    static let font = "appearance.font"
    static let background = "inject.appearance.background"
}

enum AppAccentChoice: String, CaseIterable, Identifiable {
    case neonBlue, neonRed, neonGreen, purple, electricBlue, emerald, orange

    var id: String { rawValue }
    var titleKey: String { "appearance.accent.\(rawValue)" }

    var marker: String {
        switch self {
        case .neonBlue: return "🔵"
        case .neonRed: return "🔴"
        case .neonGreen: return "🟢"
        case .purple: return "🟣"
        case .electricBlue: return "🔵"
        case .emerald: return "🟢"
        case .orange: return "🟠"
        }
    }

    var color: Color {
        switch self {
        case .neonBlue: return Color(red: 0.00, green: 0.62, blue: 1.00)
        case .neonRed: return Color(red: 1.00, green: 0.04, blue: 0.18)
        case .neonGreen: return Color(red: 0.10, green: 1.00, blue: 0.42)
        case .purple: return Color(red: 0.58, green: 0.28, blue: 0.98)
        case .electricBlue: return Color(red: 0.10, green: 0.52, blue: 1.00)
        case .emerald: return Color(red: 0.05, green: 0.78, blue: 0.48)
        case .orange: return Color(red: 1.00, green: 0.48, blue: 0.16)
        }
    }
}

enum AppFontChoice: String, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced

    var id: String { rawValue }
    var titleKey: String { "appearance.font.\(rawValue)" }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

enum AppBackgroundChoice: String, CaseIterable, Identifiable {
    case system, neonNight, pureBlack, crimson, midnight

    var id: String { rawValue }
    var titleKey: String { "appearance.background.\(rawValue)" }

    var color: Color {
        switch self {
        case .system: return Color(uiColor: .systemBackground)
        case .neonNight: return Color(red: 0.01, green: 0.012, blue: 0.035)
        case .pureBlack: return .black
        case .crimson: return Color(red: 0.105, green: 0.018, blue: 0.025)
        case .midnight: return Color(red: 0.025, green: 0.035, blue: 0.075)
        }
    }

    var preferredColorScheme: ColorScheme? {
        self == .system ? nil : .dark
    }
}

enum AppTheme {
    static let neonBlue = Color(red: 0.00, green: 0.62, blue: 1.00)
    static let neonRed = Color(red: 1.00, green: 0.04, blue: 0.18)
    static let neonGreen = Color(red: 0.10, green: 1.00, blue: 0.42)

    static var accent: Color {
        let raw = UserDefaults.standard.string(forKey: AppAppearanceKeys.accent)
            ?? AppAccentChoice.neonBlue.rawValue
        return (AppAccentChoice(rawValue: raw) ?? .neonBlue).color
    }

    static var pageBackground: Color {
        let raw = UserDefaults.standard.string(forKey: AppAppearanceKeys.background)
            ?? AppBackgroundChoice.neonNight.rawValue
        return (AppBackgroundChoice(rawValue: raw) ?? .neonNight).color
    }
    static let consoleBackground = Color(red: 0.018, green: 0.02, blue: 0.045)
    static let pageInset: CGFloat = 16
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = UIImage(named: "BrandLogo")
                ?? UIImage(named: "AppIcon60x60")
                ?? Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
                ?? UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct AnimatedBrandGIF: UIViewRepresentable {
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = contentMode
        imageView.clipsToBounds = true
        imageView.image = Self.animatedImage
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode
        if uiView.image == nil { uiView.image = Self.animatedImage }
    }

    private static let animatedImage: UIImage? = {
        guard let data = NSDataAsset(name: "BrandAnimation")?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(named: "BrandLogo")
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return UIImage(named: "BrandLogo") }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        frames.reserveCapacity(count)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                index,
                thumbnailOptions as CFDictionary
            ) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            duration += frameDuration(source: source, index: index)
        }

        guard !frames.isEmpty else { return UIImage(named: "BrandLogo") }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }()

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.08
        }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return max(unclamped ?? clamped ?? 0.08, 0.02)
    }
}
