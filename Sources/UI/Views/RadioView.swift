// RadioView.swift
//
// The Live Radio page for internet radio stations from the catalog bundled with Moonlight. Users
// can search stations, browse by genre or on a world map, filter by country and sound quality,
// save favorite stations, and see details for each one. Right-clicking a station (or the button in
// its details) opens a pre-filled form for reporting a problem with it.

import SwiftUI

struct RadioView: View {
    @EnvironmentObject private var controller: PlaybackController
    @StateObject private var model = RadioViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ContentToolbarView(
                title: "Live Radio",
                trailing: AnyView(EmptyView())
            )

            Group {
                if model.isPreparingDirectory && model.mapStations.isEmpty {
                    RadioDirectoryLoadingView()
                } else if let error = model.directoryError, model.mapStations.isEmpty {
                    RadioDirectoryErrorView(error: error) {
                        Task { await model.retryPreparingDirectory() }
                    }
                } else if model.screen == .browse {
                    RadioBrowseView(model: model)
                } else {
                    RadioResultsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgContent)
        }
        .task { await model.prepareDirectory() }
        .alert("Live Radio", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

}

private struct RadioDirectoryLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing Live Radio…")
                .font(AppTheme.current.font(.body, size: 14, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Text("Opening the reviewed radio catalog bundled with Moonlight.")
                .font(AppTheme.current.font(.caption, size: 12))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RadioDirectoryErrorView: View {
    let error: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Live Radio Is Unavailable", systemImage: "radio")
        } description: {
            Text(error)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

private struct RadioBrowseView: View {
    @ObservedObject var model: RadioViewModel
    @EnvironmentObject private var controller: PlaybackController
    @EnvironmentObject private var appState: AppState

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                if !model.favorites.isEmpty {
                    favoritesSection
                        .padding(.top, 24)
                }

                if !model.unresolvedFavorites.isEmpty {
                    unresolvedSection
                        .padding(.top, 24)
                }

                genresSection
                    .padding(.top, 24)

                if !model.mapStations.isEmpty {
                    mapSection
                        .padding(.top, 30)
                }
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(AppTheme.current.font(.icon, size: 13))
                .foregroundStyle(Color.textTertiary)

            TextField("Search stations by name…", text: $model.query)
                .textFieldStyle(.plain)
                .font(AppTheme.current.font(.body, size: 14.5))
                .foregroundStyle(Color.textPrimary)
                .onSubmit { Task { await model.submitSearch() } }
                .onChange(of: model.query) { _, _ in model.scheduleSearch() }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTheme.current.font(.icon, size: 13))
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 560, minHeight: 44)
        .background(Color.black.opacity(AppTheme.current.colorScheme == .dark ? 0.20 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.borderSoft, lineWidth: 0.5)
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RadioSectionLabel(title: "Favorites")
                .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(model.favorites) { station in
                        RadioFavoriteBookmark(
                            station: station,
                            isCurrent: controller.currentRadioStation?.stationUUID == station.stationUUID,
                            isPlaying: controller.isPlaying,
                            onReportProblem: reportAction(for: station, appState: appState)
                        ) {
                            model.play(station, using: controller)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var genresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RadioSectionLabel(title: "Browse countries")

            LazyVGrid(columns: columns, spacing: 10) {
                RadioGenreTile(label: "All Stations", muted: true) {
                    Task { await model.openResults(tag: nil, label: "All Stations") }
                }

                ForEach(model.countries.prefix(18)) { country in
                    RadioGenreTile(label: country.name, muted: false) {
                        Task { await model.openCountry(code: country.countryCode, label: country.name) }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var unresolvedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RadioSectionLabel(title: "Saved stations unavailable in this catalog")
            ForEach(model.unresolvedFavorites) { favorite in
                HStack(spacing: 12) {
                    Text(favorite.name ?? favorite.stationUUID)
                        .font(AppTheme.current.font(.caption, size: 12))
                        .foregroundStyle(Color.textSecondary)
                    Spacer(minLength: 8)
                    Button("Remove") {
                        Task { await model.removeUnresolvedFavorite(favorite.stationUUID) }
                    }
                    .buttonStyle(.borderless)
                    .font(AppTheme.current.font(.caption, size: 12))
                    .help("Remove this old saved station")
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                RadioSectionLabel(title: "Station Map")
                Text("\(model.mapStations.count) popular music stations · drag to pan · double-click to zoom")
                    .font(AppTheme.current.font(.caption, size: 11))
                    .foregroundStyle(Color.textQuaternary)
            }

            RadioStationMapView(
                stations: model.mapStations,
                currentStationUUID: controller.currentRadioStation?.stationUUID
            ) { station in
                model.play(station, using: controller)
            }
            .frame(height: 290)
        }
        .padding(.horizontal, 24)
    }
}

private struct RadioSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(AppTheme.current.font(.metadata, size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Color.textTertiary)
    }
}

private struct RadioGenreTile: View {
    let label: String
    let muted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(AppTheme.current.font(.body, size: 13.5, weight: .medium))
                .foregroundStyle(muted ? Color.textSecondary : Color.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(isHovered ? Color.bgElevated2 : Color.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.borderSoft, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct RadioFavoriteBookmark: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    let onReportProblem: (() -> Void)?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(badgeColor.opacity(isCurrent ? 0.34 : 0.20))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(badgeColor.opacity(isCurrent ? 0.90 : 0.42), lineWidth: isCurrent ? 1.2 : 0.75)

                    if isCurrent && isPlaying {
                        VUMeterInline(color: badgeColor)
                    } else if isHovered {
                        Image(systemName: "play.fill")
                            .font(AppTheme.current.font(.icon, size: 14, weight: .semibold))
                            .foregroundStyle(badgeColor)
                    } else {
                        Text(callSign)
                            .font(AppTheme.current.font(.metadata, size: 13, weight: .bold))
                            .foregroundStyle(badgeColor)
                    }
                }
                .frame(width: 64, height: 42)

                Text(station.name)
                    .font(AppTheme.current.font(.caption, size: 11.5))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .frame(width: 86)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(station.name)
        .contextMenu { ReportStationProblemButton(action: onReportProblem) }
    }

    private var badgeColor: Color {
        let hash = station.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.92)
    }

    private var callSign: String {
        let words = station.name
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if let match = words.first(where: { word in
            (3...6).contains(word.count)
                && word.rangeOfCharacter(from: .letters) != nil
                && word == word.uppercased()
        }) {
            return String(match.prefix(4))
        }
        let compact = station.name.filter { $0.isLetter || $0.isNumber }
        return String(compact.prefix(4)).uppercased()
    }
}

private struct RadioResultsView: View {
    @ObservedObject var model: RadioViewModel
    @EnvironmentObject private var controller: PlaybackController
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            resultHeader

            if model.isLoadingResults {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading stations…")
                        .foregroundStyle(Color.textTertiary)
                }
                .font(AppTheme.current.font(.body, size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.stations.isEmpty {
                ContentUnavailableView(
                    "No Stations Found",
                    systemImage: "radio",
                    description: Text("Try another name, country, or quality filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                stationList
            }
        }
    }

    private var resultHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.returnToBrowse()
            } label: {
                Label("Browse", systemImage: "chevron.left")
                    .font(AppTheme.current.font(.body, size: 12.5))
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)

            HStack(alignment: .center) {
                Text(model.resultsHeading)
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .tracking(-0.4)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Spacer()

                RadioFiltersButton(model: model)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var stationList: some View {
        VStack(spacing: 0) {
            RadioStationHeaderRow()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.stations) { station in
                        RadioStationRow(
                            station: station,
                            isCurrent: controller.currentRadioStation?.stationUUID == station.stationUUID,
                            isPlaying: controller.isPlaying,
                            isFavorite: model.favoriteUUIDs.contains(station.channelID ?? station.stationUUID),
                            onPlay: { model.play(station, using: controller) },
                            onReportProblem: reportAction(for: station, appState: appState),
                            onToggleFavorite: { Task { await model.toggleFavorite(station) } }
                        )
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct RadioFiltersButton: View {
    @ObservedObject var model: RadioViewModel
    @State private var showingFilters = false

    private var hasActiveFilters: Bool {
        !model.selectedCountryCode.isEmpty || model.minimumBitrate > 0 || model.popularOnly
    }

    var body: some View {
        Button {
            showingFilters.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text("Filters")
            }
            .font(AppTheme.current.font(.body, size: 12, weight: .medium))
            .foregroundStyle(hasActiveFilters ? Color.dAccent : Color.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.bgElevated, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.borderSoft, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("FILTERS")
                    .font(AppTheme.current.font(.metadata, size: 10.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Color.textTertiary)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Country")
                        .font(AppTheme.current.font(.caption, size: 11.5))
                        .foregroundStyle(Color.textSecondary)
                    Picker("Country", selection: $model.selectedCountryCode) {
                        Text("Any Country").tag("")
                        ForEach(model.countries) { country in
                            Text("\(country.name) (\(country.stationCount.formatted()))")
                                .tag(country.countryCode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .onChange(of: model.selectedCountryCode) { _, _ in
                        Task { await model.applyFilters() }
                    }
                }

                Toggle("Popular stations only", isOn: $model.popularOnly)
                    .toggleStyle(.checkbox)
                    .font(AppTheme.current.font(.caption, size: 11.5))
                    .foregroundStyle(Color.textSecondary)
                    .onChange(of: model.popularOnly) { _, _ in
                        Task { await model.applyFilters() }
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Quality")
                        .font(AppTheme.current.font(.caption, size: 11.5))
                        .foregroundStyle(Color.textSecondary)
                    Picker("Quality", selection: $model.minimumBitrate) {
                        Text("Any Quality").tag(0)
                        Text("128+ kbps").tag(128)
                        Text("192+ kbps").tag(192)
                        Text("256+ kbps").tag(256)
                        Text("320+ kbps").tag(320)
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .onChange(of: model.minimumBitrate) { _, _ in
                        Task { await model.applyFilters() }
                    }
                }

                if hasActiveFilters {
                    Button("Clear Filters") {
                        Task { await model.clearFilters() }
                    }
                    .buttonStyle(.plain)
                    .font(AppTheme.current.font(.caption, size: 11.5, weight: .medium))
                    .foregroundStyle(Color.dAccent)
                }
            }
            .padding(16)
        }
    }
}

private struct RadioStationHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Station").frame(maxWidth: .infinity, alignment: .leading)
            Text("Popular").frame(width: 60, alignment: .center)
            Text("Country").frame(width: 90, alignment: .leading)
            Text("Genre").frame(width: 150, alignment: .leading)
            Text("Quality").frame(width: 92, alignment: .leading)
            Color.clear.frame(width: 28)
        }
        .font(AppTheme.current.font(.metadata, size: 10.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .frame(height: 27)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderSoft).frame(height: 0.5)
        }
    }
}

private struct RadioStationRow: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    let isFavorite: Bool
    let onPlay: () -> Void
    let onReportProblem: (() -> Void)?
    let onToggleFavorite: () -> Void

    @State private var isHovered = false
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                Group {
                    if isCurrent && isPlaying {
                        VUMeterInline(color: Color.dAccent)
                    } else {
                        Image(systemName: isHovered ? "play.fill" : "radio")
                            .font(AppTheme.current.font(.icon, size: 12))
                            .foregroundStyle(isCurrent ? Color.dAccent : Color.textTertiary)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isCurrent && isPlaying ? "Pause" : "Play")
            .padding(.trailing, 9)

            HStack(spacing: 12) {
                Text(station.name)
                    .font(AppTheme.current.font(.body, size: 12.5, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(isCurrent ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "star.fill")
                    .font(AppTheme.current.font(.icon, size: 8.5, weight: .medium))
                    .foregroundStyle(station.isPopular ? Color.textTertiary : Color.clear)
                    .frame(width: 60, alignment: .center)
                    .accessibilityHidden(!station.isPopular)
                    .accessibilityLabel("Popular station")

                Text(station.countryCode ?? station.country ?? "Unknown")
                    .frame(width: 90, alignment: .leading)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)

                Text(station.tags.prefix(2).joined(separator: ", "))
                    .frame(width: 150, alignment: .leading)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)

                Text(qualityText)
                    .frame(width: 92, alignment: .leading)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onPlay)

            Button {
                showDetails = true
            } label: {
                Image(systemName: "info.circle")
                    .font(AppTheme.current.font(.icon, size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Station details")
            .popover(isPresented: $showDetails) {
                RadioStationDetailsView(station: station, onReportProblem: onReportProblem.map { report in
                    {
                        showDetails = false
                        report()
                    }
                })
            }

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(AppTheme.current.font(.icon, size: 12))
                    .foregroundStyle(isFavorite ? Color.dAccent : Color.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove Favorite" : "Add Favorite")
            .padding(.leading, 12)
        }
        .font(AppTheme.current.font(.body, size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(isCurrent ? Color.bgSelectedActive : (isHovered ? Color.bgHover : Color.clear))
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.borderSoft.opacity(0.6)).frame(height: 0.5)
        }
        .contextMenu { ReportStationProblemButton(action: onReportProblem) }
    }

    private var qualityText: String {
        [
            station.codec?.uppercased(),
            station.bitrate > 0 ? "\(station.bitrate)kbps" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

/// Opens the feedback form pre-filled for this station, or nil when this build has no feedback
/// address (other people's builds), so the option is hidden rather than leading to a disabled form.
@MainActor
private func reportAction(for station: RadioStation, appState: AppState) -> (() -> Void)? {
    guard ContactService.isConfigured else { return nil }
    return { appState.showContactFeedback(topic: .radioStation(station)) }
}

private struct ReportStationProblemButton: View {
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button("Report a Problem…", action: action)
        }
    }
}

private struct RadioStationDetailsView: View {
    let station: RadioStation
    var onReportProblem: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(station.name).font(.headline)
            detail("Call sign", station.callSign)
            detail("Frequency", station.frequency)
            detail("Organization", station.organizationName)
            detail("Location", [station.city, station.region, station.country].compactMap { $0 }.joined(separator: ", "))
            detail("Format", [station.codec, station.bitrate > 0 ? "\(station.bitrate) kbps" : nil].compactMap { $0 }.joined(separator: " · "))
            if let url = RadioWebURL.validated(station.homepageURL) {
                Link("Station website", destination: url)
            }
            if !station.alternateStreamURLs.isEmpty {
                Text("\(station.alternateStreamURLs.count) healthy alternate stream\(station.alternateStreamURLs.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            if let onReportProblem {
                Button("Report a Problem…", action: onReportProblem)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(18)
        .frame(width: 310, alignment: .leading)
    }

    @ViewBuilder private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                Text(value)
            }
            .font(.caption)
        }
    }
}
