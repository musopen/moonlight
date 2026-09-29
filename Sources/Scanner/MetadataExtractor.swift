// MetadataExtractor.swift
//
// Reads the information stored inside a music file (its "metadata"): title, artist, album,
// composer, genre, year, track and disc numbers, length, audio quality and embedded cover art. It
// tries several reading methods in turn so that as many details as possible are found across
// formats like MP3, AAC, FLAC and WAV.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import SPFKMetadata
import SPFKMetadataC
import UniformTypeIdentifiers

struct ExtractedMetadata {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double?
    var bitRate: Int?
    var sampleRate: Int?
    var channelCount: Int?
    var format: String?
    var artworkData: Data?
}

enum MetadataExtractor {
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "alac", "wav", "aiff", "aif", "m4b"
    ]

    static func extract(from url: URL) async throws -> ExtractedMetadata {
        var meta = ExtractedMetadata()
        meta.format = url.pathExtension.uppercased()

        if url.pathExtension.caseInsensitiveCompare("wav") == .orderedSame,
           let fileDesc = try? await MetaAudioFileDescription(parsing: url) {
            apply(tags: fileDesc.tagProperties.tags, to: &meta)
            apply(audioFormat: fileDesc.audioFormat, to: &meta)
            if let cgImage = fileDesc.imageDescription.cgImage {
                meta.artworkData = cgImageToJPEG(cgImage)
            }
        } else if let tagProperties = try? TagProperties(url: url) {
            apply(tags: tagProperties.tags, to: &meta)
            apply(audioFormat: tagProperties.audioProperties, to: &meta)
        }

        if meta.artworkData == nil,
           let pictureRef = try? TagPictureRef.parsing(url: url) {
            meta.artworkData = cgImageToJPEG(pictureRef.cgImage)
        }

        try await applyAVFallback(from: url, to: &meta)
        return meta
    }

    static func normalizedTagValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.precomposedStringWithCanonicalMapping
    }

    static func parseLeadingInteger(_ value: String?) -> Int? {
        guard let first = normalizedTagValue(value)?.components(separatedBy: "/").first else {
            return nil
        }
        return Int(first.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parseYear(_ value: String?) -> Int? {
        guard let value = normalizedTagValue(value) else { return nil }
        return Int(value.prefix(4))
    }

    private static func apply(tags: TagKeyDictionary, to meta: inout ExtractedMetadata) {
        meta.title       = normalizedTagValue(tags[.title])
        meta.artist      = normalizedTagValue(tags[.artist])
        meta.albumArtist = normalizedTagValue(tags[.albumArtist])
        meta.album       = normalizedTagValue(tags[.album])
        meta.composer    = normalizedTagValue(tags[.composer])
        meta.genre       = normalizedTagValue(tags[.genre])
        meta.year        = parseYear(tags[.date])
        meta.trackNumber = parseLeadingInteger(tags[.trackNumber])
        meta.discNumber  = parseLeadingInteger(tags[.discNumber])
    }

    private static func apply(audioFormat: AudioFormatProperties?, to meta: inout ExtractedMetadata) {
        guard let audioFormat else { return }
        if meta.duration == nil, audioFormat.duration.isFinite, audioFormat.duration > 0 {
            meta.duration = audioFormat.duration
        }
        if meta.bitRate == nil {
            meta.bitRate = audioFormat.bitRate.map(Int.init)
        }
        if meta.sampleRate == nil, audioFormat.sampleRate > 0 {
            meta.sampleRate = Int(audioFormat.sampleRate)
        }
        if meta.channelCount == nil, audioFormat.channelCount > 0 {
            meta.channelCount = Int(audioFormat.channelCount)
        }
    }

    private static func applyAVFallback(from url: URL, to meta: inout ExtractedMetadata) async throws {
        let asset = AVURLAsset(url: url)

        if hasMissingCommonTags(meta), let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if meta.title == nil { meta.title = normalizedTagValue(try? await item.load(.stringValue)) }
                case .commonKeyArtist:
                    if meta.artist == nil { meta.artist = normalizedTagValue(try? await item.load(.stringValue)) }
                case .commonKeyAlbumName:
                    if meta.album == nil { meta.album = normalizedTagValue(try? await item.load(.stringValue)) }
                case .commonKeyArtwork:
                    if meta.artworkData == nil { meta.artworkData = try? await item.load(.dataValue) }
                default:
                    break
                }
            }
        }

        for format in [AVMetadataFormat.id3Metadata, .iTunesMetadata] {
            guard hasMissingExtendedTags(meta) else { break }
            let items = (try? await asset.loadMetadata(for: format)) ?? []
            await applyAVMetadataItems(items, to: &meta)
        }

        if hasMissingExtendedTags(meta),
           let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats where format != .id3Metadata && format != .iTunesMetadata {
                let items = (try? await asset.loadMetadata(for: format)) ?? []
                await applyAVMetadataItems(items, to: &meta)
            }
        }

        if meta.duration == nil, let duration = try? await asset.load(.duration),
           duration.seconds.isFinite, duration.seconds > 0 {
            meta.duration = duration.seconds
        }

        if meta.sampleRate == nil || meta.channelCount == nil,
           let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let desc = try? await audioTrack.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            if meta.sampleRate == nil, asbd.pointee.mSampleRate > 0 {
                meta.sampleRate = Int(asbd.pointee.mSampleRate)
            }
            if meta.channelCount == nil, asbd.pointee.mChannelsPerFrame > 0 {
                meta.channelCount = Int(asbd.pointee.mChannelsPerFrame)
            }
        }
    }

    private static func applyAVMetadataItems(_ items: [AVMetadataItem], to meta: inout ExtractedMetadata) async {
        for item in items {
            let key = metadataKey(for: item)
            switch key {
            case "TPE2", "AART", "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST":
                if meta.albumArtist == nil { meta.albumArtist = normalizedTagValue(try? await item.load(.stringValue)) }
            case "TCOM", "\u{00A9}WRT", "COMPOSER":
                if meta.composer == nil { meta.composer = normalizedTagValue(try? await item.load(.stringValue)) }
            case "TCON", "\u{00A9}GEN", "GENRE":
                if meta.genre == nil { meta.genre = normalizedTagValue(try? await item.load(.stringValue)) }
            case "TDRC", "\u{00A9}DAY", "DATE", "YEAR":
                if meta.year == nil { meta.year = parseYear(try? await item.load(.stringValue)) }
            case "TRCK", "TRKN", "TRACKNUMBER", "TRACK":
                if meta.trackNumber == nil {
                    if let parsed = parseLeadingInteger(try? await item.load(.stringValue)) {
                        meta.trackNumber = parsed
                    } else if let number = try? await item.load(.numberValue), number.intValue > 0 {
                        meta.trackNumber = Int(number.intValue)
                    }
                }
            case "TPOS", "DISK", "DISCNUMBER", "DISC":
                if meta.discNumber == nil {
                    if let parsed = parseLeadingInteger(try? await item.load(.stringValue)) {
                        meta.discNumber = parsed
                    } else if let number = try? await item.load(.numberValue), number.intValue > 0 {
                        meta.discNumber = Int(number.intValue)
                    }
                }
            case "TITLE":
                if meta.title == nil { meta.title = normalizedTagValue(try? await item.load(.stringValue)) }
            case "ARTIST":
                if meta.artist == nil { meta.artist = normalizedTagValue(try? await item.load(.stringValue)) }
            case "ALBUM":
                if meta.album == nil { meta.album = normalizedTagValue(try? await item.load(.stringValue)) }
            default:
                break
            }
        }
    }

    private static func metadataKey(for item: AVMetadataItem) -> String {
        if let string = item.key as? String {
            return string.uppercased()
        }
        return item.identifier?.rawValue.uppercased() ?? ""
    }

    private static func hasMissingCommonTags(_ meta: ExtractedMetadata) -> Bool {
        meta.title == nil || meta.artist == nil || meta.album == nil || meta.artworkData == nil
    }

    private static func hasMissingExtendedTags(_ meta: ExtractedMetadata) -> Bool {
        hasMissingCommonTags(meta)
            || meta.albumArtist == nil
            || meta.composer == nil
            || meta.genre == nil
            || meta.year == nil
            || meta.trackNumber == nil
            || meta.discNumber == nil
    }

    private static func cgImageToJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
