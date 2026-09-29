// Artwork.swift
//
// Describes a piece of cover art as stored in the music library database, kept in a small and a
// large size along with its main color. It also turns the stored image data into pictures the app
// can display, shrinking them when a smaller size is needed.

import Foundation
import GRDB
import AppKit
import ImageIO

struct Artwork: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "artwork"

    var id: Int64?
    var sourceURL: String?
    var dataSmall: Data?
    var dataLarge: Data?
    var dominantColorHex: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceURL = "source_url"
        case dataSmall = "data_small"
        case dataLarge = "data_large"
        case dominantColorHex = "dominant_color_hex"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var imageSmall: NSImage? { dataSmall.flatMap { Self.image(from: $0) } }
    var imageLarge: NSImage? { dataLarge.flatMap { Self.image(from: $0) } }

    func image(large: Bool, maxPixelSize: Int? = nil) -> NSImage? {
        let data = large ? dataLarge : dataSmall
        return data.flatMap { Self.image(from: $0, maxPixelSize: maxPixelSize) }
    }

    static func image(from data: Data, maxPixelSize: Int? = nil) -> NSImage? {
        guard let maxPixelSize else { return NSImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
