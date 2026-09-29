// DesignSystem.swift
//
// The app's shared look and feel. It defines all the color themes the user can pick (including
// retro styles such as Moonamp, Terminal and MoonPod), the fonts and colors each theme uses, and
// small building blocks reused across the window, such as sidebar rows, the toolbar at the top
// of each page, the search field and toolbar buttons.

import SwiftUI
import AppKit

// MARK: - Color tokens

enum AppTheme: String, CaseIterable, Identifiable {
    case tokyoNight
    case oneDark
    case monokai
    case nightOwl
    case catppuccin
    case gruvbox
    case solarized
    case nord
    case ayuMirage
    case obsidian
    case neptune
    case moonamp
    case terminal
    case moonPod
    case retroMoonPod
    case paperwhite
    case blueHour
    case lavenderMist
    case monet

    static let storageKey = "appearance_theme"
    static let defaultTheme: AppTheme = .oneDark
    private static var activeTheme: AppTheme = {
        let storedValue = UserDefaults.standard.string(forKey: storageKey) ?? ""
        if storedValue == "arcadeGold" {
            UserDefaults.standard.set(AppTheme.terminal.rawValue, forKey: storageKey)
            return .terminal
        }
        return AppTheme(rawValue: storedValue) ?? defaultTheme
    }()

    var id: String { rawValue }
    var isDefault: Bool { self == Self.defaultTheme }

    var displayName: String {
        switch self {
        case .tokyoNight:  "Tokyo Night"
        case .oneDark:     "Moonlight"
        case .monokai:     "Monokai"
        case .nightOwl:    "Night Owl"
        case .catppuccin:  "Catppuccin"
        case .gruvbox:     "Gruvbox"
        case .solarized:   "Solarized"
        case .nord:        "Nord"
        case .ayuMirage:   "Ayu Mirage"
        case .obsidian:    "Obsidian"
        case .neptune:     "Neptune"
        case .moonamp:     "Moonamp"
        case .terminal:    "Terminal"
        case .moonPod:     "MoonPod"
        case .retroMoonPod: "Retro MoonPod"
        case .paperwhite:  "Paperwhite"
        case .blueHour:    "Blue Hour"
        case .lavenderMist: "Lavender Mist"
        case .monet:       "Monet"
        }
    }

    var subtitle: String {
        switch self {
        case .tokyoNight:  "Navy, electric blue, purple"
        case .oneDark:     "Default, charcoal, balanced color"
        case .monokai:     "Black, neon green, pink, orange"
        case .nightOwl:    "Dark navy, cyan, gold"
        case .catppuccin:  "Soft pastel darks"
        case .gruvbox:     "Warm brown, yellow, green"
        case .solarized:   "Muted blue-green"
        case .nord:        "Icy blue-gray"
        case .ayuMirage:   "Smoky blue-gray, muted orange"
        case .obsidian:    "Neutral dark gray"
        case .neptune:     "Richer deep blue"
        case .moonamp:     "Graphite chrome, green LCD, amber controls"
        case .terminal:    "DOS VGA, ANSI green, box-drawing UI"
        case .moonPod:     "White shell, blue display, graphite controls"
        case .retroMoonPod: "Monochrome LCD, Chicago, slate controls"
        case .paperwhite:  "Near-white, graphite, blue"
        case .blueHour:    "Light blue, navy ink"
        case .lavenderMist: "Light purple, soft slate"
        case .monet:       "Canvas, pond green, iris blue"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .moonPod, .retroMoonPod, .paperwhite, .blueHour, .lavenderMist, .monet:
            .light
        case .tokyoNight, .oneDark, .monokai, .nightOwl, .catppuccin, .gruvbox, .solarized, .nord, .ayuMirage, .obsidian, .neptune, .moonamp, .terminal:
            .dark
        }
    }

    var transportChromeStyle: TransportChromeStyle {
        switch self {
        case .moonamp: .moonamp
        case .terminal: .terminal
        case .moonPod: .moonPod
        case .retroMoonPod: .retroMoonPod
        default: .standard
        }
    }

    var defaultArtworkTreatment: ArtworkTreatment {
        switch self {
        case .terminal: .phosphorGreen
        default: .color
        }
    }

    static var current: AppTheme {
        activeTheme
    }

    func persist() {
        Self.activeTheme = self
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    var palette: ThemePalette {
        switch self {
        case .tokyoNight:
            ThemePalette(
                bgBase: "#070818", bgContent: "#090719", bgSidebar: "#0d1028", bgSidebarOpacity: 0.56,
                bgElevated: "#17172c", bgElevated2: "#20203a", bgChrome: "#19152f", transportOpacity: 0.72,
                hover: "#9aa4ff", selected: "#9aa4ff", accent: "#9aa4ff", accentStrong: "#7384ff",
                borderSoft: "#8a93d6", borderMedium: "#9aa4ff", borderStrong: "#b4bcff"
            )
        case .oneDark:
            ThemePalette(
                bgBase: "#1f2329", bgContent: "#282c34", bgSidebar: "#21252b", bgSidebarOpacity: 0.72,
                bgElevated: "#303640", bgElevated2: "#3b4250", bgChrome: "#2c313a", transportOpacity: 0.76,
                hover: "#61afef", selected: "#61afef", accent: "#61afef", accentStrong: "#528bff",
                borderSoft: "#abb2bf", borderMedium: "#abb2bf", borderStrong: "#c8ccd4"
            )
        case .monokai:
            ThemePalette(
                bgBase: "#171812", bgContent: "#202116", bgSidebar: "#1b1c13", bgSidebarOpacity: 0.74,
                bgElevated: "#2c2d20", bgElevated2: "#383926", bgChrome: "#27271b", transportOpacity: 0.78,
                hover: "#a6e22e", selected: "#f92672", accent: "#a6e22e", accentStrong: "#fd971f",
                borderSoft: "#f8f8f2", borderMedium: "#a6e22e", borderStrong: "#f92672"
            )
        case .nightOwl:
            ThemePalette(
                bgBase: "#011627", bgContent: "#061d32", bgSidebar: "#03182a", bgSidebarOpacity: 0.68,
                bgElevated: "#0b2942", bgElevated2: "#123452", bgChrome: "#082238", transportOpacity: 0.74,
                hover: "#7fdbca", selected: "#82aaff", accent: "#7fdbca", accentStrong: "#ecc48d",
                borderSoft: "#5f7e97", borderMedium: "#7fdbca", borderStrong: "#ecc48d"
            )
        case .catppuccin:
            ThemePalette(
                bgBase: "#181825", bgContent: "#1e1e2e", bgSidebar: "#181825", bgSidebarOpacity: 0.72,
                bgElevated: "#313244", bgElevated2: "#45475a", bgChrome: "#242438", transportOpacity: 0.76,
                hover: "#89b4fa", selected: "#cba6f7", accent: "#89b4fa", accentStrong: "#cba6f7",
                borderSoft: "#6c7086", borderMedium: "#89b4fa", borderStrong: "#cba6f7"
            )
        case .gruvbox:
            ThemePalette(
                bgBase: "#1d2021", bgContent: "#282828", bgSidebar: "#24221f", bgSidebarOpacity: 0.72,
                bgElevated: "#32302f", bgElevated2: "#3c3836", bgChrome: "#2f2a25", transportOpacity: 0.78,
                hover: "#b8bb26", selected: "#fabd2f", accent: "#fabd2f", accentStrong: "#b8bb26",
                borderSoft: "#928374", borderMedium: "#d79921", borderStrong: "#b8bb26"
            )
        case .solarized:
            ThemePalette(
                bgBase: "#002b36", bgContent: "#073642", bgSidebar: "#002b36", bgSidebarOpacity: 0.68,
                bgElevated: "#0b4652", bgElevated2: "#15535f", bgChrome: "#06333e", transportOpacity: 0.74,
                hover: "#2aa198", selected: "#268bd2", accent: "#2aa198", accentStrong: "#268bd2",
                borderSoft: "#586e75", borderMedium: "#2aa198", borderStrong: "#93a1a1"
            )
        case .nord:
            ThemePalette(
                bgBase: "#242933", bgContent: "#2e3440", bgSidebar: "#252b36", bgSidebarOpacity: 0.70,
                bgElevated: "#3b4252", bgElevated2: "#434c5e", bgChrome: "#303847", transportOpacity: 0.76,
                hover: "#88c0d0", selected: "#81a1c1", accent: "#88c0d0", accentStrong: "#5e81ac",
                borderSoft: "#4c566a", borderMedium: "#81a1c1", borderStrong: "#8fbcbb"
            )
        case .ayuMirage:
            ThemePalette(
                bgBase: "#171b24", bgContent: "#1f2430", bgSidebar: "#1a1f2a", bgSidebarOpacity: 0.72,
                bgElevated: "#272d3a", bgElevated2: "#343b4a", bgChrome: "#232936", transportOpacity: 0.76,
                hover: "#ffcc66", selected: "#73d0ff", accent: "#ffcc66", accentStrong: "#ffad66",
                borderSoft: "#5c6773", borderMedium: "#73d0ff", borderStrong: "#ffcc66"
            )
        case .obsidian:
            ThemePalette(
                bgBase: "#151515", bgContent: "#1d1d1f", bgSidebar: "#19191b", bgSidebarOpacity: 0.72,
                bgElevated: "#28282b", bgElevated2: "#343438", bgChrome: "#252528", transportOpacity: 0.78,
                hover: "#8a8f98", selected: "#a3a8b0", accent: "#a3a8b0", accentStrong: "#d0d3d8",
                borderSoft: "#6f737a", borderMedium: "#8a8f98", borderStrong: "#d0d3d8"
            )
        case .neptune:
            ThemePalette(
                bgBase: "#03101f", bgContent: "#05172c", bgSidebar: "#061b33", bgSidebarOpacity: 0.58,
                bgElevated: "#0b2340", bgElevated2: "#123052", bgChrome: "#09213d", transportOpacity: 0.72,
                hover: "#4ca7ff", selected: "#4ca7ff", accent: "#4ca7ff", accentStrong: "#1f7fe5",
                borderSoft: "#4b78a5", borderMedium: "#4ca7ff", borderStrong: "#8bc8ff"
            )
        case .moonamp:
            ThemePalette(
                bgBase: "#111322", bgContent: "#090a0f", bgSidebar: "#252942", bgSidebarOpacity: 0.78,
                bgElevated: "#1d2137", bgElevated2: "#303654", bgChrome: "#24283f", transportOpacity: 0.92,
                hover: "#00e25a", selected: "#00e25a", accent: "#00e25a", accentStrong: "#f2a51f",
                borderSoft: "#aeb7d8", borderMedium: "#d8e0f4", borderStrong: "#fff1a8"
            )
        case .terminal:
            ThemePalette(
                bgBase: "#050806", bgContent: "#07100a", bgSidebar: "#050806", bgSidebarOpacity: 0.92,
                bgElevated: "#0b150e", bgElevated2: "#102015", bgChrome: "#08120b", transportOpacity: 1,
                hover: "#33ff66", selected: "#33ff66", accent: "#33ff66", accentStrong: "#b7ffc7",
                borderSoft: "#33ff66", borderMedium: "#20c8ff", borderStrong: "#b7ffc7",
                textBase: "#33ff66",
                textPrimaryOpacity: 0.98,
                textSecondaryOpacity: 0.74,
                textTertiaryOpacity: 0.52,
                textQuaternaryOpacity: 0.32
            )
        case .moonPod:
            ThemePalette(
                bgBase: "#f5f2eb", bgContent: "#eef5f8", bgSidebar: "#d9dde2", bgSidebarOpacity: 0.44,
                bgElevated: "#ffffff", bgElevated2: "#e7ebef", bgChrome: "#f2f0eb", transportOpacity: 0.94,
                hover: "#00a7c8", selected: "#00a7c8", accent: "#00a7c8", accentStrong: "#376b8c",
                borderSoft: "#7b8490", borderMedium: "#5f6c78", borderStrong: "#2f3945",
                textBase: "#1d2730"
            )
        case .retroMoonPod:
            ThemePalette(
                bgBase: "#cbdae7", bgContent: "#cbdae7", bgSidebar: "#cbdae7", bgSidebarOpacity: 1,
                bgElevated: "#cbdae7", bgElevated2: "#cbdae7", bgChrome: "#cbdae7", transportOpacity: 1,
                hover: "#404a89", selected: "#404a89", accent: "#404a89", accentStrong: "#404a89",
                borderSoft: "#404a89", borderMedium: "#404a89", borderStrong: "#404a89",
                textBase: "#404a89",
                textPrimaryOpacity: 1,
                textSecondaryOpacity: 0.86,
                textTertiaryOpacity: 0.72,
                textQuaternaryOpacity: 0.54
            )
        case .paperwhite:
            ThemePalette(
                bgBase: "#f7f7f4", bgContent: "#ffffff", bgSidebar: "#5f6f86", bgSidebarOpacity: 0.22,
                bgElevated: "#f0f2f6", bgElevated2: "#e4e8ef", bgChrome: "#e8ebf2", transportOpacity: 0.72,
                hover: "#2f6feb", selected: "#2f6feb", accent: "#2f6feb", accentStrong: "#174ea6",
                borderSoft: "#3a4658", borderMedium: "#2f6feb", borderStrong: "#174ea6",
                textBase: "#111827"
            )
        case .blueHour:
            ThemePalette(
                bgBase: "#eaf4ff", bgContent: "#f7fbff", bgSidebar: "#2d78ad", bgSidebarOpacity: 0.22,
                bgElevated: "#e3f1ff", bgElevated2: "#cfe5fb", bgChrome: "#d7ebff", transportOpacity: 0.70,
                hover: "#0f6cbd", selected: "#0f6cbd", accent: "#0f6cbd", accentStrong: "#084c8d",
                borderSoft: "#24527a", borderMedium: "#0f6cbd", borderStrong: "#084c8d",
                textBase: "#0b2138"
            )
        case .lavenderMist:
            ThemePalette(
                bgBase: "#f4f0ff", bgContent: "#fbf9ff", bgSidebar: "#7d60b6", bgSidebarOpacity: 0.22,
                bgElevated: "#efe8ff", bgElevated2: "#ded2fb", bgChrome: "#e8ddff", transportOpacity: 0.70,
                hover: "#7c3aed", selected: "#7c3aed", accent: "#7c3aed", accentStrong: "#5b21b6",
                borderSoft: "#5d4b7a", borderMedium: "#7c3aed", borderStrong: "#5b21b6",
                textBase: "#21162f"
            )
        case .monet:
            ThemePalette(
                bgBase: "#f4f0e6", bgContent: "#fbf7ed", bgSidebar: "#8fb7aa", bgSidebarOpacity: 0.24,
                bgElevated: "#fffaf0", bgElevated2: "#e9eee2", bgChrome: "#e8efe8", transportOpacity: 0.74,
                hover: "#5f8fb3", selected: "#5f8fb3", accent: "#5f8fb3", accentStrong: "#c46f7a",
                borderSoft: "#49666a", borderMedium: "#5f8fb3", borderStrong: "#9f5f69",
                textBase: "#1f2f35"
            )
        }
    }
}

enum ThemeFontRole {
    case body
    case caption
    case title
    case brand
    case numeric
    case control
    case icon
    case table
    case sidebar
    case metadata
}

extension AppTheme {
    var isRetroMoonPod: Bool {
        self == .retroMoonPod
    }

    var isTerminal: Bool {
        self == .terminal
    }

    var usesLimitedMetadataGlyphSet: Bool {
        switch self {
        case .moonamp, .terminal, .retroMoonPod:
            true
        default:
            false
        }
    }

    func displayText(_ text: String) -> String {
        guard usesLimitedMetadataGlyphSet else { return text }
        return text.asciiFoldedForLimitedGlyphFonts
    }

    private static var moonampUIFontName: String? {
        ["LunabitMono-Regular", "Lunabit Mono Regular", "Lunabit Mono"].first {
            NSFont(name: $0, size: 12) != nil
        }
    }

    private static var retroMoonPodUIFontName: String? {
        ["ChicagoFLF", "Chicago FLF", "Chicago", "Monaco", "Geneva"].first {
            NSFont(name: $0, size: 12) != nil
        }
    }

    private static var terminalUIFontName: String? {
        ["LunabitMono-Regular", "Lunabit Mono Regular", "Lunabit Mono"].first {
            NSFont(name: $0, size: 12) != nil
        }
    }

    private static func terminalSize(_ size: CGFloat) -> CGFloat {
        max(8, size.rounded(.toNearestOrAwayFromZero))
    }

    private static func retroMoonPodSize(_ size: CGFloat) -> CGFloat {
        max(8, size.rounded(.toNearestOrAwayFromZero))
    }

    private static func moonPodFontName(
        for role: ThemeFontRole,
        weight: Font.Weight
    ) -> String? {
        let prefersMedium = role == .title
            || role == .brand
            || role == .control
            || role == .sidebar
            || weight == .medium
            || weight == .semibold
            || weight == .bold
            || weight == .heavy
            || weight == .black

        let candidates = prefersMedium
            ? ["HelveticaNeue-Medium", "Helvetica Neue Medium", "Helvetica-Medium", "HelveticaNeue", "Helvetica Neue", "Helvetica", "SFProText-Medium", "SF Pro Text Medium", "NimbusSans-Regular", "Nimbus Sans"]
            : ["HelveticaNeue", "Helvetica Neue", "Helvetica", "SFProText-Regular", "SF Pro Text", "NimbusSans-Regular", "Nimbus Sans"]

        return candidates.first { NSFont(name: $0, size: 12) != nil }
    }

    private static func moonPodFontName(
        for role: ThemeFontRole,
        weight: NSFont.Weight
    ) -> String? {
        let prefersMedium = role == .title
            || role == .brand
            || role == .control
            || role == .sidebar
            || weight.rawValue >= NSFont.Weight.medium.rawValue

        let candidates = prefersMedium
            ? ["HelveticaNeue-Medium", "Helvetica Neue Medium", "Helvetica-Medium", "HelveticaNeue", "Helvetica Neue", "Helvetica", "SFProText-Medium", "SF Pro Text Medium", "NimbusSans-Regular", "Nimbus Sans"]
            : ["HelveticaNeue", "Helvetica Neue", "Helvetica", "SFProText-Regular", "SF Pro Text", "NimbusSans-Regular", "Nimbus Sans"]

        return candidates.first { NSFont(name: $0, size: 12) != nil }
    }

    func font(
        _ role: ThemeFontRole = .body,
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        if self == .retroMoonPod {
            let pixelSize = Self.retroMoonPodSize(size)
            switch role {
            case .icon:
                return .system(size: pixelSize, weight: weight, design: design)
            case .body, .caption, .title, .brand, .numeric, .control, .table, .sidebar, .metadata:
                if let fontName = Self.retroMoonPodUIFontName {
                    return .custom(fontName, size: pixelSize)
                }
                return role == .numeric
                    ? .system(size: pixelSize, weight: weight, design: .monospaced).monospacedDigit()
                    : .system(size: pixelSize, weight: weight, design: .default)
            }
        }

        if self == .moonPod {
            switch role {
            case .icon:
                return .system(size: size, weight: weight, design: design)
            case .numeric:
                return .system(size: size, weight: weight, design: .default).monospacedDigit()
            case .title, .brand, .control, .sidebar, .body, .caption, .table, .metadata:
                if let fontName = Self.moonPodFontName(for: role, weight: weight) {
                    return .custom(fontName, size: size)
                }
                return .system(size: size, weight: weight, design: .default)
            }
        }

        if self == .terminal {
            let pixelSize = Self.terminalSize(size)
            switch role {
            case .icon:
                return .system(size: pixelSize, weight: weight, design: design)
            case .brand, .numeric, .control, .title, .body, .caption, .table, .sidebar, .metadata:
                if let fontName = Self.terminalUIFontName {
                    return .custom(fontName, size: pixelSize)
                }
                return .system(size: pixelSize, weight: weight, design: .monospaced)
            }
        }

        guard self == .moonamp else {
            return .system(size: size, weight: weight, design: design)
        }

        switch role {
        case .brand:
            if let fontName = Self.moonampUIFontName {
                return .custom(fontName, size: size)
            }
            return .system(size: size, weight: .bold, design: .monospaced)
        case .icon:
            return .system(size: size, weight: weight, design: design)
        case .numeric, .control, .title, .body, .caption, .table, .sidebar, .metadata:
            if let fontName = Self.moonampUIFontName {
                return .custom(fontName, size: size)
            }
            return .system(size: size, weight: weight, design: .monospaced)
        }
    }

    func nsFont(
        _ role: ThemeFontRole = .body,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        monospacedDigit: Bool = false
    ) -> NSFont {
        if self == .retroMoonPod {
            let pixelSize = Self.retroMoonPodSize(size)
            if role == .icon {
                return .systemFont(ofSize: pixelSize, weight: weight)
            }
            if let fontName = Self.retroMoonPodUIFontName,
               let font = NSFont(name: fontName, size: pixelSize) {
                return font
            }
            return monospacedDigit || role == .numeric
                ? .monospacedDigitSystemFont(ofSize: pixelSize, weight: weight)
                : .systemFont(ofSize: pixelSize, weight: weight)
        }

        if self == .moonPod {
            if role == .icon {
                return .systemFont(ofSize: size, weight: weight)
            }
            if monospacedDigit || role == .numeric {
                return .monospacedDigitSystemFont(ofSize: size, weight: weight)
            }
            if let fontName = Self.moonPodFontName(for: role, weight: weight),
               let font = NSFont(name: fontName, size: size) {
                return font
            }
            return .systemFont(ofSize: size, weight: weight)
        }

        if self == .terminal {
            let pixelSize = Self.terminalSize(size)
            if role == .icon {
                return .systemFont(ofSize: pixelSize, weight: weight)
            }
            if let fontName = Self.terminalUIFontName,
               let font = NSFont(name: fontName, size: pixelSize) {
                return font
            }
            return monospacedDigit || role == .numeric
                ? .monospacedDigitSystemFont(ofSize: pixelSize, weight: weight)
                : .monospacedSystemFont(ofSize: pixelSize, weight: weight)
        }

        guard self == .moonamp else {
            return monospacedDigit
                ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                : .systemFont(ofSize: size, weight: weight)
        }

        if role == .brand,
           let fontName = Self.moonampUIFontName,
           let font = NSFont(name: fontName, size: size) {
            return font
        }

        if monospacedDigit || role == .numeric || role == .control || role == .caption || role == .body || role == .title || role == .table || role == .sidebar || role == .metadata {
            if let fontName = Self.moonampUIFontName,
               let font = NSFont(name: fontName, size: size) {
                return font
            }
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }

        return .systemFont(ofSize: size, weight: weight)
    }
}

private extension String {
    var asciiFoldedForLimitedGlyphFonts: String {
        let expanded = map { character -> String in
            switch character {
            case "Æ": "AE"
            case "æ": "ae"
            case "Œ": "OE"
            case "œ": "oe"
            case "ß": "ss"
            case "Ø": "O"
            case "ø": "o"
            case "Ð", "Đ": "D"
            case "ð", "đ": "d"
            case "Þ": "Th"
            case "þ": "th"
            case "Ł": "L"
            case "ł": "l"
            default: String(character)
            }
        }.joined()

        let folded = expanded.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        let normalized = folded.map { character -> String in
            switch character {
            case "‘", "’", "‚", "‛": "'"
            case "“", "”", "„", "‟": "\""
            case "–", "—", "−": "-"
            case "…": "..."
            case "•", "·": "*"
            default: String(character)
            }
        }.joined()

        return normalized.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value >= 32 && scalar.value <= 126 {
                result.unicodeScalars.append(scalar)
            } else if scalar == "\n" || scalar == "\t" {
                result.append(" ")
            }
        }
    }
}

enum TransportChromeStyle {
    case standard
    case moonamp
    case terminal
    case moonPod
    case retroMoonPod
}

struct ScanlineOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.black.opacity(0.30))
                )
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

enum ArtworkTreatment {
    case color
    case phosphorGreen
    case monochrome
}

struct ArtworkTreatmentModifier: ViewModifier {
    let treatment: ArtworkTreatment

    func body(content: Content) -> some View {
        switch treatment {
        case .color:
            AnyView(content)
        case .phosphorGreen:
            AnyView(
                content
                    .saturation(0)
                    .colorMultiply(Color(hex: "#33ff66"))
                    .overlay(ScanlineOverlay())
            )
        case .monochrome:
            AnyView(content.saturation(0))
        }
    }
}

extension View {
    func artworkTreatment(_ treatment: ArtworkTreatment) -> some View {
        modifier(ArtworkTreatmentModifier(treatment: treatment))
    }
}

struct TerminalVignetteOverlay: View {
    var body: some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.55), location: 1.0)
            ]),
            center: .center,
            startRadius: 0,
            endRadius: 600
        )
        .allowsHitTesting(false)
    }
}

struct ThemePalette {
    let bgBase: Color
    let bgContent: Color
    let bgSidebar: Color
    let bgSidebarSheen: Color
    let bgElevated: Color
    let bgElevated2: Color
    let bgChrome: Color
    let bgHover: Color
    let bgSelected: Color
    let bgSelectedActive: Color
    let borderSoft: Color
    let borderMedium: Color
    let borderStrong: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textQuaternary: Color
    let dAccent: Color
    let dAccentStrong: Color
    let bgTransport: Color
    let windowMiniBackground: NSColor
    let windowLibraryBackground: NSColor
    let nsBgContent: NSColor
    let nsBgChrome: NSColor
    let nsBgHover: NSColor
    let nsBgSelectedActive: NSColor
    let nsBorderSoft: NSColor
    let nsAccent: NSColor
    let nsTextPrimary: NSColor
    let nsTextSecondary: NSColor
    let nsTextTertiary: NSColor
    let swatches: [Color]

    init(bgBase: String, bgContent: String, bgSidebar: String, bgSidebarOpacity: Double,
         bgElevated: String, bgElevated2: String, bgChrome: String, transportOpacity: Double,
         hover: String, selected: String, accent: String, accentStrong: String,
         borderSoft: String, borderMedium: String, borderStrong: String,
         textBase: String = "#ffffff",
         textPrimaryOpacity: Double = 0.96,
         textSecondaryOpacity: Double = 0.66,
         textTertiaryOpacity: Double = 0.46,
         textQuaternaryOpacity: Double = 0.30) {
        let isLight = textBase != "#ffffff"
        self.bgBase = Color(hex: bgBase)
        self.bgContent = Color(hex: bgContent)
        self.bgSidebar = Color(hex: bgSidebar).opacity(isLight ? bgSidebarOpacity : bgSidebarOpacity * 0.52)
        self.bgSidebarSheen = Color(hex: isLight ? "#ffffff" : "#cfd7ff").opacity(isLight ? 0.04 : 0.08)
        self.bgElevated = Color(hex: bgElevated)
        self.bgElevated2 = Color(hex: bgElevated2)
        self.bgChrome = Color(hex: bgChrome)
        self.bgTransport = Color(hex: bgChrome).opacity(transportOpacity)
        self.bgHover = Color(hex: hover).opacity(0.08)
        self.bgSelected = Color(hex: selected).opacity(0.11)
        self.bgSelectedActive = Color(hex: selected).opacity(0.16)
        self.borderSoft = Color(hex: borderSoft).opacity(0.12)
        self.borderMedium = Color(hex: borderMedium).opacity(0.18)
        self.borderStrong = Color(hex: borderStrong).opacity(0.25)
        self.textPrimary = Color(hex: textBase).opacity(textPrimaryOpacity)
        self.textSecondary = Color(hex: textBase).opacity(textSecondaryOpacity)
        self.textTertiary = Color(hex: textBase).opacity(textTertiaryOpacity)
        self.textQuaternary = Color(hex: textBase).opacity(textQuaternaryOpacity)
        self.dAccent = Color(hex: accent)
        self.dAccentStrong = Color(hex: accentStrong)
        self.windowMiniBackground = NSColor(hex: bgBase)
        self.windowLibraryBackground = NSColor(hex: bgChrome)
        self.nsBgContent = NSColor(hex: bgContent)
        self.nsBgChrome = NSColor(hex: bgChrome)
        self.nsBgHover = NSColor(hex: hover).withAlphaComponent(0.08)
        self.nsBgSelectedActive = NSColor(hex: selected).withAlphaComponent(0.16)
        self.nsBorderSoft = NSColor(hex: borderSoft).withAlphaComponent(0.12)
        self.nsAccent = NSColor(hex: accent)
        self.nsTextPrimary = NSColor(hex: textBase).withAlphaComponent(textPrimaryOpacity)
        self.nsTextSecondary = NSColor(hex: textBase).withAlphaComponent(textSecondaryOpacity)
        self.nsTextTertiary = NSColor(hex: textBase).withAlphaComponent(textTertiaryOpacity)
        self.swatches = [Color(hex: bgBase), Color(hex: bgContent), Color(hex: bgChrome), Color(hex: accent), Color(hex: accentStrong)]
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xff) / 255
        let g = Double((rgb >>  8) & 0xff) / 255
        let b = Double( rgb        & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }

    private static var themePalette: ThemePalette { AppTheme.current.palette }

    // Backgrounds
    static var bgBase: Color { themePalette.bgBase }
    static var bgContent: Color { themePalette.bgContent }
    static var bgSidebar: Color { themePalette.bgSidebar }
    static var bgSidebarSheen: Color { themePalette.bgSidebarSheen }
    static var bgElevated: Color { themePalette.bgElevated }
    static var bgElevated2: Color { themePalette.bgElevated2 }
    static var bgChrome: Color { themePalette.bgChrome }
    static var bgTransport: Color { themePalette.bgTransport }
    static var bgHover: Color { themePalette.bgHover }
    static var bgSelected: Color { themePalette.bgSelected }
    static var bgSelectedActive: Color { themePalette.bgSelectedActive }

    // Borders
    static var borderSoft: Color { themePalette.borderSoft }
    static var borderMedium: Color { themePalette.borderMedium }
    static var borderStrong: Color { themePalette.borderStrong }

    // Text
    static var textPrimary: Color { themePalette.textPrimary }
    static var textSecondary: Color { themePalette.textSecondary }
    static var textTertiary: Color { themePalette.textTertiary }
    static var textQuaternary: Color { themePalette.textQuaternary }

    // Accent
    static var dAccent: Color { themePalette.dAccent }
    static var dAccentStrong: Color { themePalette.dAccentStrong }
}

extension NSColor {
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

// MARK: - Dimension tokens

enum DS {
    static let sidebarWidth:        CGFloat = 232
    static let transportHeight:     CGFloat = 76
    static let toolbarHeight:       CGFloat = 56
    static let windowChromeHeight:  CGFloat = toolbarHeight
    static let windowButtonReserveWidth: CGFloat = 86
    static let rowHeight:           CGFloat = 26
    static let albumArtTransport:   CGFloat = 48
    static let radiusCard:          CGFloat = 6
    static let radiusControl:       CGFloat = 6
}

// MARK: - VU meter (inline bars, no badge backdrop)

struct VUMeterInline: View {
    var color: Color = Color.dAccent
    @State private var phase: Double = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2, height: barHeight(i))
            }
        }
        .frame(width: 12, height: 11)
        .onReceive(timer) { _ in phase += 0.15 }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let offsets: [Double] = [0, 0.9, 0.45]
        let h = (sin(phase + offsets[i]) + 1) / 2
        return max(2, h * 9)
    }
}

// MARK: - Sidebar row

struct SidebarRow: View {
    let icon: String
    let label: String
    let isActive: Bool
    var count: Int? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isRetroMoonPod = AppTheme.current.isRetroMoonPod
        let isTerminal = AppTheme.current.isTerminal

        Button(action: action) {
            HStack(spacing: isRetroMoonPod ? 6 : (isTerminal ? 6 : 8)) {
                Image(systemName: icon)
                    .frame(width: isRetroMoonPod ? 13 : 16, height: isRetroMoonPod ? 13 : 16)
                    .font(AppTheme.current.font(.icon, size: isRetroMoonPod ? 11 : 13, weight: .regular))
                    .foregroundStyle(isActive && isRetroMoonPod ? Color.bgContent : (isActive ? Color.dAccent : Color.textTertiary))

                Text(label)
                    .font(AppTheme.current.font(.sidebar, size: isRetroMoonPod ? 12 : (isTerminal ? 12 : 13), weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive && isRetroMoonPod ? Color.bgContent : (isActive ? (isTerminal ? Color.dAccentStrong : Color.textPrimary) : Color.textSecondary))
                    .lineLimit(1)

                Spacer()

                if let count {
                    Text("\(count)")
                        .font(AppTheme.current.font(.numeric, size: isRetroMoonPod ? 10 : 11))
                        .foregroundStyle(isActive && isRetroMoonPod ? Color.bgContent.opacity(0.86) : (isActive && isTerminal ? Color(hex: "#20c8ff") : Color.textTertiary))
                }
            }
            .frame(height: isRetroMoonPod ? 23 : DS.rowHeight)
            .padding(.horizontal, isRetroMoonPod ? 8 : (isTerminal ? 7 : 10))
            .background(
                RoundedRectangle(cornerRadius: (isRetroMoonPod || isTerminal) ? 1 : DS.radiusControl)
                    .fill(isActive ? (isRetroMoonPod ? Color.dAccent : (isTerminal ? Color.dAccent.opacity(0.14) : Color.bgSelectedActive)) : (isHovered ? Color.bgHover : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: (isRetroMoonPod || isTerminal) ? 1 : DS.radiusControl)
                            .strokeBorder(isActive && isTerminal ? Color.dAccent.opacity(0.84) : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - NSVisualEffectView wrappers

/// Sidebar vibrancy: blurs the desktop behind the window (.behindWindow).
struct SidebarVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = (AppTheme.current.isRetroMoonPod || AppTheme.current.isTerminal) ? .contentBackground : (AppTheme.current.colorScheme == .light ? .hudWindow : .sidebar)
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = (AppTheme.current.isRetroMoonPod || AppTheme.current.isTerminal) ? .contentBackground : (AppTheme.current.colorScheme == .light ? .hudWindow : .sidebar)
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

/// Transport bar vibrancy: blurs content within the window (.withinWindow).
struct TransportVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = (AppTheme.current.isRetroMoonPod || AppTheme.current.isTerminal) ? .contentBackground : .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = (AppTheme.current.isRetroMoonPod || AppTheme.current.isTerminal) ? .contentBackground : .hudWindow
    }
}

// MARK: - Sidebar section header

struct SidebarSectionHeader: View {
    let title: String
    var onImport: (() -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    var onCollapse: (() -> Void)? = nil

    var body: some View {
        let isRetroMoonPod = AppTheme.current.isRetroMoonPod
        let isTerminal = AppTheme.current.isTerminal

        HStack {
            Text(isTerminal ? "[\(title.uppercased())]" : title.uppercased())
                .font(AppTheme.current.font(.sidebar, size: isRetroMoonPod ? 10 : 11, weight: .medium))
                .kerning((isRetroMoonPod || isTerminal) ? 0 : 0.8)
                .foregroundStyle(Color.textTertiary)
            Spacer()
            if let onImport {
                Button(action: onImport) {
                    Image(systemName: "square.and.arrow.down")
                        .font(AppTheme.current.font(.icon, size: 11, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Import Playlists…")
            }
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(AppTheme.current.font(.icon, size: 11, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            } else if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.leading")
                        .font(AppTheme.current.font(.icon, size: 12, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse Sidebar")
            }
        }
        .padding(.leading, isRetroMoonPod ? 10 : 14)
        .padding(.trailing, isRetroMoonPod ? 10 : 12)
        .padding(.top, isRetroMoonPod ? 10 : 14)
        .padding(.bottom, isRetroMoonPod ? 3 : 4)
    }
}

// MARK: - Content toolbar

struct ContentToolbarView: View {
    @EnvironmentObject private var appState: AppState

    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        let isRetroMoonPod = AppTheme.current.isRetroMoonPod
        let isTerminal = AppTheme.current.isTerminal

        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.bgChrome.opacity((isRetroMoonPod || isTerminal) ? 1 : 0.72))
                .background {
                    if !isRetroMoonPod && !isTerminal {
                        Rectangle().fill(.ultraThinMaterial)
                    }
                }
            windowDragOverlay

            HStack(alignment: .center, spacing: 12) {
                if appState.isSidebarCollapsed {
                    ToolbarSidebarToggleButton()
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(AppTheme.current.font(.title, size: isRetroMoonPod ? 15 : (isTerminal ? 16 : 17), weight: .semibold))
                        .tracking((isRetroMoonPod || isTerminal) ? 0 : -0.2)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppTheme.current.font(.caption, size: isRetroMoonPod ? 10 : 11.5, weight: .medium))
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let trailing {
                    trailing
                }

                ToolbarSearchField(text: $appState.searchText)
            }
            .padding(.leading, appState.isSidebarCollapsed ? DS.windowButtonReserveWidth : 24)
            .padding(.trailing, 24)
            .frame(height: DS.toolbarHeight)

            Rectangle()
                .fill(Color.borderSoft)
                .frame(height: (isRetroMoonPod || isTerminal) ? 1 : 0.5)
        }
        .frame(height: DS.windowChromeHeight)
    }

    private var windowDragOverlay: some View {
        WindowDragRegion()
            .frame(maxWidth: .infinity)
            .frame(height: DS.toolbarHeight)
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableHeaderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableHeaderView: NSView {
        // WindowModeWindowConfigurator owns window dragging. Changing that setting
        // while this view attaches can reenter SwiftUI's window drag observation.
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct ToolbarSidebarToggleButton: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false

    var body: some View {
        Button {
            appState.setSidebarCollapsed(false)
        } label: {
            Image(systemName: "sidebar.leading")
                .font(AppTheme.current.font(.icon, size: 13, weight: .medium))
                .foregroundStyle(isHovered ? Color.textPrimary : Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusControl)
                        .fill(isHovered ? Color.bgHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Expand Sidebar")
    }
}

// MARK: - Toolbar search field

struct ToolbarSearchField: View {
    @Binding var text: String

    var body: some View {
        let isRetroMoonPod = AppTheme.current.isRetroMoonPod
        let isTerminal = AppTheme.current.isTerminal

        HStack(spacing: 6) {
            if isTerminal {
                Text("SEARCH>")
                    .font(AppTheme.current.font(.control, size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: "#20c8ff"))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(AppTheme.current.font(.icon, size: 12))
                    .foregroundStyle(Color.textTertiary)
            }

            DeferredFocusTextField("Search", text: $text)
                .frame(height: 16)
                .frame(maxWidth: .infinity)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTheme.current.font(.icon, size: 11))
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: isRetroMoonPod ? 206 : (isTerminal ? 238 : 220), height: isRetroMoonPod ? 22 : 24)
        .padding(.horizontal, isRetroMoonPod ? 6 : 8)
        .background(
            RoundedRectangle(cornerRadius: (isRetroMoonPod || isTerminal) ? 1 : DS.radiusControl)
                .fill(Color.bgChrome.opacity((isRetroMoonPod || isTerminal) ? 1 : 0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: (isRetroMoonPod || isTerminal) ? 1 : DS.radiusControl)
                        .strokeBorder(isTerminal ? Color.dAccent.opacity(0.72) : Color.borderSoft, lineWidth: (isRetroMoonPod || isTerminal) ? 1 : 0.5)
                )
        )
    }
}

private struct DeferredFocusTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = ClickFocusedTextField()
        textField.delegate = context.coordinator
        context.coordinator.install(for: textField)
        textField.stringValue = text
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = AppTheme.current.nsFont(.control, size: 12)
        textField.textColor = AppTheme.current.palette.nsTextPrimary
        textField.configureAsMusicSearchField()
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: AppTheme.current.nsFont(.control, size: 12),
                .foregroundColor: AppTheme.current.palette.nsTextTertiary
            ]
        )
        textField.cell?.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async {
            textField.resignIfFirstResponder()
        }
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.textColor = AppTheme.current.palette.nsTextPrimary
        nsView.font = AppTheme.current.nsFont(.control, size: 12)
        nsView.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: AppTheme.current.nsFont(.control, size: 12),
                .foregroundColor: AppTheme.current.palette.nsTextTertiary
            ]
        )
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        private weak var textField: NSTextField?
        private var outsideClickMonitor: Any?

        init(text: Binding<String>) {
            self._text = text
        }

        func install(for textField: NSTextField) {
            self.textField = textField
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.resignFocusIfClickIsOutside(event)
                return event
            }
        }

        func dismantle() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
            outsideClickMonitor = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            (textField.currentEditor() as? NSTextView)?.configureAsMusicSearchFieldEditor()
        }

        private func resignFocusIfClickIsOutside(_ event: NSEvent) {
            guard
                let textField,
                let window = textField.window,
                event.window === window,
                textField.isFirstResponder
            else { return }

            let clickPoint = textField.convert(event.locationInWindow, from: nil)
            if !textField.bounds.contains(clickPoint) {
                textField.resignIfFirstResponder()
            }
        }
    }
}

private final class ClickFocusedTextField: NSTextField {
    private var acceptsMouseFocus = false

    override var acceptsFirstResponder: Bool {
        acceptsMouseFocus
    }

    override func mouseDown(with event: NSEvent) {
        acceptsMouseFocus = true
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in
            self?.acceptsMouseFocus = false
        }
    }
}

private extension NSTextField {
    func configureAsMusicSearchField() {
        contentType = nil
    }

    var isFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        return firstResponder === self || firstResponder === currentEditor()
    }

    func resignIfFirstResponder() {
        guard isFirstResponder else { return }
        window?.makeFirstResponder(nil)
    }
}

extension NSTextView {
    func configureAsMusicSearchFieldEditor() {
        contentType = nil
        enabledTextCheckingTypes = 0
        isAutomaticTextCompletionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
    }
}

// MARK: - Toolbar icon button

struct ToolbarIconButton: View {
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AppTheme.current.font(.icon, size: 13, weight: .regular))
                .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusControl)
                        .fill(isActive ? Color.bgSelectedActive : (isHovered ? Color.bgHover : .clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
