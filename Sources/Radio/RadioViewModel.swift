// RadioViewModel.swift
//
// Supplies the data and actions behind the radio screen in the Mac app: browsing and searching
// stations, filtering by country, quality or popularity, managing favorites, and starting playback
// of a chosen station. It reads from the built-in station list and the user's saved favorites, and
// plays each station from the address in that list without asking any online directory.

import Combine
import Foundation

@MainActor
final class RadioViewModel: ObservableObject {
    enum Screen: Equatable {
        case browse
        case results
    }

    @Published private(set) var screen: Screen = .browse
    @Published var query = ""
    @Published private(set) var selectedTag: String?
    @Published private(set) var selectedLabel = "All Stations"
    @Published var selectedCountryCode = ""
    @Published var minimumBitrate = 0
    @Published var popularOnly = false

    @Published private(set) var stations: [RadioStation] = []
    @Published private(set) var favorites: [RadioStation] = []
    @Published private(set) var favoriteUUIDs: Set<String> = []
    @Published private(set) var unresolvedFavorites: [UnresolvedRadioFavorite] = []
    @Published private(set) var mapStations: [RadioStation] = []
    @Published private(set) var countries: [RadioCountry] = []

    @Published private(set) var isPreparingDirectory = false
    @Published private(set) var isLoadingResults = false
    @Published private(set) var directoryError: String?
    @Published var notice: String?

    private var catalog: ReviewedRadioCatalog?
    private var userState: RadioUserState?
    private var didPrepare = false
    private var searchTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    init() {
        do {
            let openedCatalog = try ReviewedRadioCatalog()
            let openedState = try RadioUserState(catalog: openedCatalog)
            catalog = openedCatalog
            userState = openedState
        } catch {
            catalog = nil
            userState = nil
            directoryError = "Moonlight couldn’t open the radio directory. \(error.localizedDescription)"
        }
    }

    init(catalog: ReviewedRadioCatalog, userState: RadioUserState) {
        self.catalog = catalog
        self.userState = userState
    }

    deinit {
        searchTask?.cancel()
        resultsTask?.cancel()
    }

    var resultsHeading: String {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? selectedLabel : "Results for “\(search)”"
    }

    func prepareDirectory() async {
        guard !didPrepare else { return }
        didPrepare = true
        guard catalog != nil, userState != nil else { return }

        isPreparingDirectory = true
        directoryError = nil
        do {
            try await reloadBrowseData()
        } catch {
            directoryError = "Moonlight couldn’t prepare Live Radio. \(error.localizedDescription)"
        }
        isPreparingDirectory = false
    }

    func retryPreparingDirectory() async {
        if catalog == nil || userState == nil {
            do {
                let openedCatalog = try ReviewedRadioCatalog()
                let openedState = try RadioUserState(catalog: openedCatalog)
                catalog = openedCatalog
                userState = openedState
            } catch {
                directoryError = "Moonlight couldn’t open the radio directory. \(error.localizedDescription)"
                return
            }
        }
        didPrepare = false
        await prepareDirectory()
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            selectedTag = nil
            selectedLabel = "Search"
            screen = .results
            await loadResults()
        }
    }

    func submitSearch() async {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectedTag = nil
        selectedLabel = "Search"
        screen = .results
        await loadResults()
    }

    func openResults(tag: String?, label: String) async {
        searchTask?.cancel()
        query = ""
        selectedTag = tag
        selectedLabel = label
        selectedCountryCode = ""
        minimumBitrate = 0
        popularOnly = false
        screen = .results
        await loadResults()
    }

    func openCountry(code: String, label: String) async {
        searchTask?.cancel()
        query = ""
        selectedTag = nil
        selectedLabel = label
        selectedCountryCode = code
        minimumBitrate = 0
        popularOnly = false
        screen = .results
        await loadResults()
    }

    func returnToBrowse() {
        resultsTask?.cancel()
        query = ""
        screen = .browse
        stations = []
    }

    func applyFilters() async {
        guard screen == .results else { return }
        await loadResults()
    }

    func clearFilters() async {
        selectedCountryCode = ""
        minimumBitrate = 0
        popularOnly = false
        await loadResults()
    }

    func toggleFavorite(_ station: RadioStation) async {
        guard let userState, let channelID = station.channelID else { return }
        let wasFavorite = favoriteUUIDs.contains(channelID)
        do {
            try await Task.detached(priority: .userInitiated) {
                if wasFavorite {
                    try userState.removeFavorite(channelID: channelID)
                } else {
                    try userState.addFavorite(station)
                }
            }.value
            try await reloadFavorites()
        } catch {
            notice = "Moonlight couldn’t update that favorite. \(error.localizedDescription)"
        }
    }

    func removeUnresolvedFavorite(_ stationUUID: String) async {
        guard let userState else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                try userState.removeUnresolvedFavorite(stationUUID: stationUUID)
            }.value
            unresolvedFavorites = try userState.unresolvedFavorites()
        } catch {
            notice = "Moonlight couldn’t remove that saved station. \(error.localizedDescription)"
        }
    }

    func play(_ station: RadioStation, using controller: PlaybackController) {
        if controller.currentRadioStation?.stationUUID == station.stationUUID {
            controller.togglePlayPause()
            return
        }

        guard let streamURL = RadioWebURL.validated(station.streamURL) else {
            notice = "“\(station.name)” couldn’t start playing because its stream address isn’t valid."
            return
        }
        controller.playRadio(station: station, streamURL: streamURL)
    }

    private func loadResults() async {
        guard let catalog else { return }
        resultsTask?.cancel()
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTag = selectedTag
        let countryCode = selectedCountryCode
        let bitrate = minimumBitrate
        let popularOnly = popularOnly

        isLoadingResults = true
        resultsTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try catalog.fetchStations(
                        search: search.isEmpty ? selectedTag : search,
                        countryCode: countryCode.isEmpty ? nil : countryCode,
                        minimumBitrate: bitrate,
                        popularOnly: popularOnly,
                        limit: 200
                    )
                }.value
                guard !Task.isCancelled, let self else { return }
                stations = result
                isLoadingResults = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                stations = []
                isLoadingResults = false
                notice = "Moonlight couldn’t search the radio directory. \(error.localizedDescription)"
            }
        }
        await resultsTask?.value
    }

    private func reloadBrowseData() async throws {
        guard let catalog, let userState else { return }
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try BrowseSnapshot(
                favorites: userState.favoriteStations(),
                unresolvedFavorites: userState.unresolvedFavorites(),
                mapStations: [],
                countries: catalog.fetchCountries(limit: 60)
            )
        }.value
        favorites = snapshot.favorites
        unresolvedFavorites = snapshot.unresolvedFavorites
        favoriteUUIDs = try userState.favoriteChannelIDs()
        mapStations = snapshot.mapStations
        countries = snapshot.countries
    }

    private func reloadFavorites() async throws {
        guard let userState else { return }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try userState.favoriteStations()
        }.value
        favorites = loaded
        favoriteUUIDs = try userState.favoriteChannelIDs()
    }
}

private struct BrowseSnapshot: Sendable {
    let favorites: [RadioStation]
    let unresolvedFavorites: [UnresolvedRadioFavorite]
    let mapStations: [RadioStation]
    let countries: [RadioCountry]
}
