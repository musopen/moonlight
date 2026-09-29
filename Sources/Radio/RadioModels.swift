// RadioModels.swift
//
// Defines the basic pieces of radio information used throughout the app: a station (name, stream
// address, country, audio quality, logo, and so on), a country with its station count, and
// summaries of how many stations were added, updated or removed when a list was loaded.

import Foundation
import GRDB

struct RadioStation: Equatable, Identifiable, Sendable {
    let id: Int64
    let stationUUID: String
    let changeUUID: String
    let name: String
    let streamURL: String
    let tags: [String]
    let countryCode: String?
    let country: String?
    let codec: String?
    let bitrate: Int
    let votes: Int
    let clickCount: Int
    let isPopular: Bool
    let lastCheckOK: Bool
    let latitude: Double?
    let longitude: Double?
    let channelID: String?
    let callSign: String?
    let frequency: String?
    let city: String?
    let region: String?
    let organizationName: String?
    let homepageURL: String?
    let logoURL: String?
    let alternateStreamURLs: [String]

    init(
        id: Int64,
        stationUUID: String,
        changeUUID: String,
        name: String,
        streamURL: String,
        tags: [String],
        countryCode: String?,
        country: String?,
        codec: String?,
        bitrate: Int,
        votes: Int,
        clickCount: Int,
        isPopular: Bool,
        lastCheckOK: Bool,
        latitude: Double?,
        longitude: Double?,
        channelID: String? = nil,
        callSign: String? = nil,
        frequency: String? = nil,
        city: String? = nil,
        region: String? = nil,
        organizationName: String? = nil,
        homepageURL: String? = nil,
        logoURL: String? = nil,
        alternateStreamURLs: [String] = []
    ) {
        self.id = id
        self.stationUUID = stationUUID
        self.changeUUID = changeUUID
        self.name = name
        self.streamURL = streamURL
        self.tags = tags
        self.countryCode = countryCode
        self.country = country
        self.codec = codec
        self.bitrate = bitrate
        self.votes = votes
        self.clickCount = clickCount
        self.isPopular = isPopular
        self.lastCheckOK = lastCheckOK
        self.latitude = latitude
        self.longitude = longitude
        self.channelID = channelID
        self.callSign = callSign
        self.frequency = frequency
        self.city = city
        self.region = region
        self.organizationName = organizationName
        self.homepageURL = homepageURL
        self.logoURL = logoURL
        self.alternateStreamURLs = alternateStreamURLs
    }

    init(row: Row) {
        id = row["id"]
        stationUUID = row["stationuuid"]
        changeUUID = row["changeuuid"]
        name = row["name"]
        streamURL = row["stream_url"]
        countryCode = row["countrycode"]
        country = row["country"]
        codec = row["codec"]
        bitrate = row["bitrate"]
        votes = row["votes"]
        clickCount = row["clickcount"]
        isPopular = row["is_popular"]
        lastCheckOK = row["lastcheckok"]
        latitude = row["geo_lat"]
        longitude = row["geo_long"]
        channelID = nil
        callSign = nil
        frequency = nil
        city = nil
        region = nil
        organizationName = nil
        homepageURL = nil
        logoURL = nil
        alternateStreamURLs = []
        let separator = Character(UnicodeScalar(31))
        let rawTags: String = row["tags"]
        tags = rawTags.split(separator: separator).map(String.init).sorted()
    }
}

struct RadioCountry: Equatable, Identifiable, Sendable {
    let countryCode: String
    let name: String
    let stationCount: Int

    var id: String { countryCode }
}

struct RadioImportSummary: Equatable, Sendable {
    let inserted: Int
    let prunedStaleFailures: Int
    let skippedInvalid: Int
}

struct RadioRefreshSummary: Equatable, Sendable {
    let inserted: Int
    let updated: Int
    let deleted: Int
    let skipped: Int
    let refreshedVolatileFields: Int
    let prunedStaleFailures: Int
    let skippedInvalid: Int
}

/// Station data comes from an outside directory, so only web links are ever opened or played.
enum RadioWebURL {
    static func validated(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}
