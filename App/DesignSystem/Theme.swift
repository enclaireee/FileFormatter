import SwiftUI

/// Small, deliberate visual vocabulary for the app. Everything is built from system
/// colours and type so it still feels like a Mac utility, not a skin.
enum Theme {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    enum Radius {
        static let xs: CGFloat = 5
        static let sm: CGFloat = 7
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
    }

    enum Tone: Equatable {
        case neutral
        case accent
        case info
        case success
        case warning
        case danger
    }

    enum Palette {
        static let canvas = Color(nsColor: .windowBackgroundColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let sunken = Color(nsColor: .underPageBackgroundColor)
        static let hairline = Color(nsColor: .separatorColor)
        static let muted = Color(nsColor: .secondaryLabelColor)
        static let faint = Color(nsColor: .tertiaryLabelColor)
        static let accent = Color.accentColor
        static let info = Color.blue
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red

        static func color(for tone: Tone) -> Color {
            switch tone {
            case .neutral: muted
            case .accent: accent
            case .info: info
            case .success: success
            case .warning: warning
            case .danger: danger
            }
        }

        static func fill(for tone: Tone) -> Color {
            tone == .neutral ? Color.primary.opacity(0.06) : color(for: tone).opacity(0.12)
        }
    }

    enum Text {
        static let pageTitle = Font.title2.weight(.semibold)
        static let panelTitle = Font.title3.weight(.semibold)
        static let sectionTitle = Font.headline
        static let body = Font.callout
        static let caption = Font.caption
        static let micro = Font.caption2
    }
}

/// A quiet status capsule. Colour is only used when it carries meaning.
struct Badge: View {
    let text: String
    var systemImage: String?
    var tone: Theme.Tone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tone == .neutral ? Theme.Palette.muted : Theme.Palette.color(for: tone))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.Palette.fill(for: tone), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A tinted rounded-square glyph, used instead of bare icons in lists and headers.
struct IconTile: View {
    let systemImage: String
    var tone: Theme.Tone = .neutral
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(tone == .neutral ? Theme.Palette.muted : Theme.Palette.color(for: tone))
            .frame(width: size, height: size)
            .background(
                Theme.Palette.fill(for: tone),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// Shared page heading: one title, one supporting line, one action cluster.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Text.pageTitle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Text.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Space.md)
            trailing
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, 18)
        .padding(.bottom, Theme.Space.md)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// The one empty/absent state used across the app. Centered, generous, with a real action.
struct EmptyStatePanel<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    var tone: Theme.Tone = .accent
    private let actions: Actions

    init(
        systemImage: String,
        title: String,
        message: String,
        tone: Theme.Tone = .accent,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            IconTile(systemImage: systemImage, tone: tone, size: 56)
            VStack(spacing: 6) {
                Text(title)
                    .font(Theme.Text.panelTitle)
                Text(message)
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}

extension EmptyStatePanel where Actions == EmptyView {
    init(systemImage: String, title: String, message: String, tone: Theme.Tone = .accent) {
        self.init(systemImage: systemImage, title: title, message: message, tone: tone) { EmptyView() }
    }
}

/// A hairline that reads correctly on both light and dark window backgrounds.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline.opacity(0.55))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
