// ThirdPartyAcknowledgements.swift
//
// A fixed list of the outside open-source libraries Moonlight uses, with each one's version,
// license and website. The About and Settings screens read this list to credit those projects and
// show their license texts.

import Foundation

struct ThirdPartyAcknowledgement: Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let license: String
    let homepage: URL
    let files: [String]

    var versionLabel: String {
        version.isEmpty ? license : "\(version) • \(license)"
    }
}

enum ThirdPartyAcknowledgements {
    static let all: [ThirdPartyAcknowledgement] = [
        ThirdPartyAcknowledgement(
            id: "grdb",
            name: "GRDB.swift",
            version: "6.29.3",
            license: "MIT",
            homepage: URL(string: "https://github.com/groue/GRDB.swift")!,
            files: ["GRDB-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "spfk-metadata",
            name: "SPFKMetadata",
            version: "Local package",
            license: "MIT",
            homepage: URL(string: "https://github.com/ryanfrancesconi/spfk-metadata")!,
            files: ["SPFKMetadata-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "spfk-taglib",
            name: "TagLib via spfk-taglib",
            version: "spfk-taglib 1.3.0, TagLib 2.3",
            license: "LGPL 2.1 or MPL 1.1",
            homepage: URL(string: "https://github.com/ryanfrancesconi/spfk-taglib")!,
            files: ["TagLib-LGPL-2.1", "TagLib-MPL-1.1"]
        ),
        ThirdPartyAcknowledgement(
            id: "spfk-audio-base",
            name: "SPFKAudioBase",
            version: "0.0.14",
            license: "MIT",
            homepage: URL(string: "https://github.com/ryanfrancesconi/spfk-audio-base")!,
            files: ["SPFKAudioBase-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "spfk-base",
            name: "SPFKBase",
            version: "0.0.12",
            license: "MIT",
            homepage: URL(string: "https://github.com/ryanfrancesconi/spfk-base")!,
            files: ["SPFKBase-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "spfk-filesystem",
            name: "SPFKFilesystem",
            version: "0.0.8",
            license: "MIT",
            homepage: URL(string: "https://github.com/ryanfrancesconi/spfk-filesystem")!,
            files: ["SPFKFilesystem-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "spfk-metadata-base",
            name: "SPFKMetadataBase",
            version: "0.0.8",
            license: "MIT",
            homepage: URL(string: "https://github.com/ryanfrancesconi/spfk-metadata-base")!,
            files: ["SPFKMetadataBase-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "spfk-utils",
            name: "SPFKUtils (used by SPFKMetadata)",
            version: "0.0.17",
            license: "No license file in resolved checkout",
            homepage: URL(string: "https://github.com/ryanfrancesconi/spfk-utils")!,
            files: ["SPFKUtils-NOTICE"]
        ),
        ThirdPartyAcknowledgement(
            id: "aexml",
            name: "AEXML",
            version: "4.7.0",
            license: "MIT",
            homepage: URL(string: "https://github.com/tadija/AEXML")!,
            files: ["AEXML-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "checksum",
            name: "Checksum",
            version: "1.0.2",
            license: "MIT",
            homepage: URL(string: "https://github.com/rnine/Checksum")!,
            files: ["Checksum-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "flac",
            name: "FLAC binary XCFramework",
            version: "0.2.0",
            license: "BSD 3-Clause",
            homepage: URL(string: "https://github.com/sbooth/flac-binary-xcframework")!,
            files: ["FLAC-BSD-3-Clause"]
        ),
        ThirdPartyAcknowledgement(
            id: "ogg",
            name: "Ogg binary XCFramework",
            version: "0.1.3",
            license: "BSD 3-Clause",
            homepage: URL(string: "https://github.com/sbooth/ogg-binary-xcframework")!,
            files: ["Ogg-BSD-3-Clause"]
        ),
        ThirdPartyAcknowledgement(
            id: "opus",
            name: "Opus binary XCFramework",
            version: "0.3.0",
            license: "BSD 3-Clause",
            homepage: URL(string: "https://github.com/sbooth/opus-binary-xcframework")!,
            files: ["Opus-BSD-3-Clause"]
        ),
        ThirdPartyAcknowledgement(
            id: "vorbis",
            name: "Vorbis binary XCFramework",
            version: "0.1.2",
            license: "BSD 3-Clause",
            homepage: URL(string: "https://github.com/sbooth/vorbis-binary-xcframework")!,
            files: ["Vorbis-BSD-3-Clause"]
        ),
        ThirdPartyAcknowledgement(
            id: "swift-async-algorithms",
            name: "Swift Async Algorithms",
            version: "1.1.5",
            license: "Apache 2.0",
            homepage: URL(string: "https://github.com/apple/swift-async-algorithms")!,
            files: ["SwiftAsyncAlgorithms-Apache-2.0"]
        ),
        ThirdPartyAcknowledgement(
            id: "swift-collections",
            name: "Swift Collections",
            version: "1.6.0",
            license: "Apache 2.0",
            homepage: URL(string: "https://github.com/apple/swift-collections")!,
            files: ["SwiftCollections-Apache-2.0"]
        ),
        ThirdPartyAcknowledgement(
            id: "swift-data-parsing",
            name: "Swift Data Parsing",
            version: "0.1.2",
            license: "MIT",
            homepage: URL(string: "https://github.com/orchetect/swift-data-parsing")!,
            files: ["SwiftDataParsing-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "swift-extensions",
            name: "Swift Extensions",
            version: "2.3.2",
            license: "MIT",
            homepage: URL(string: "https://github.com/orchetect/swift-extensions")!,
            files: ["SwiftExtensions-MIT"]
        ),
        ThirdPartyAcknowledgement(
            id: "swift-numerics",
            name: "Swift Numerics",
            version: "1.1.1",
            license: "Apache 2.0",
            homepage: URL(string: "https://github.com/apple/swift-numerics")!,
            files: ["SwiftNumerics-Apache-2.0"]
        ),
        ThirdPartyAcknowledgement(
            id: "swift-xattr",
            name: "swift-xattr",
            version: "3.0.1",
            license: "ISC",
            homepage: URL(string: "https://github.com/jozefizso/swift-xattr")!,
            files: ["SwiftXattr-ISC"]
        ),
        ThirdPartyAcknowledgement(
            id: "scenes-pexels",
            name: "Now Playing scene videos",
            version: "",
            license: "Pexels License",
            homepage: URL(string: "https://www.pexels.com/license/")!,
            files: ["Scenes-Pexels"]
        ),
        ThirdPartyAcknowledgement(
            id: "radio-browser",
            name: "Radio Browser station directory",
            version: "",
            license: "Community data",
            homepage: URL(string: "https://www.radio-browser.info/")!,
            files: ["RadioBrowser-Data"]
        ),
        ThirdPartyAcknowledgement(
            id: "firebase-analytics",
            name: "Firebase Analytics (Google)",
            version: "12.17.0",
            license: "Apache 2.0; GoogleAppMeasurement under Google terms",
            homepage: URL(string: "https://github.com/firebase/firebase-ios-sdk")!,
            files: ["FirebaseAnalytics-Google"]
        ),
        ThirdPartyAcknowledgement(
            id: "chicagoflf",
            name: "ChicagoFLF font",
            version: "2.0",
            license: "Public domain",
            homepage: URL(string: "https://fontlibrary.org/en/font/chicagoflf")!,
            files: ["ChicagoFLF-Public-Domain"]
        ),
        ThirdPartyAcknowledgement(
            id: "lunabit-mono",
            name: "Lunabit Mono font",
            version: "",
            license: "SIL Open Font License 1.1",
            homepage: URL(string: "https://openfontlicense.org/")!,
            files: ["LunabitMono-OFL-1.1"]
        )
    ]
}
