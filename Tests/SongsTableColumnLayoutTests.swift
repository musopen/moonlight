import XCTest
@testable import Moonlight

final class SongsTableColumnLayoutTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        userDefaultsSuiteName = "SongsTableColumnLayoutTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        userDefaults = nil
        userDefaultsSuiteName = nil
        super.tearDown()
    }

    func testDefaultLayoutContainsRequiredColumnsAndWidths() {
        let layout = SongsTableColumnLayout.defaultLayout

        XCTAssertEqual(layout.columns.map(\.id), SongsTableColumnLayout.definitions.map(\.id))
        XCTAssertTrue(layout.visibleColumns.contains(where: { $0.id == .title }))
        XCTAssertTrue(layout.visibleColumns.contains(where: { $0.id == .artwork }))
        XCTAssertTrue(layout.visibleColumns.contains(where: { $0.id == .duration }))
        XCTAssertTrue(layout.visibleColumns.contains(where: { $0.id == .favorite }))
        XCTAssertFalse(layout.visibleColumns.contains(where: { $0.id == .rating }))

        let title = layout.columns.first { $0.id == .title }
        XCTAssertEqual(title?.width, SongsTableColumnLayout.definition(for: .title).defaultWidth)
    }

    func testLayoutPersistsVisibilityAndWidths() {
        var layout = SongsTableColumnLayout.defaultLayout
        layout.setVisibility(true, for: .composer)
        layout.setVisibility(false, for: .artist)
        layout.setWidth(244, for: .album)
        layout.moveColumn(.duration, toVisiblePositionOf: .title)

        layout.save(userDefaults: userDefaults)
        let reloaded = SongsTableColumnLayout.load(userDefaults: userDefaults)

        XCTAssertTrue(reloaded.columns.first { $0.id == .composer }?.isVisible == true)
        XCTAssertTrue(reloaded.columns.first { $0.id == .artist }?.isVisible == false)
        XCTAssertEqual(reloaded.columns.first { $0.id == .album }?.width, 244)
        XCTAssertEqual(reloaded.visibleColumns.map(\.id), [.artwork, .duration, .title, .album, .albumArtist, .composer, .favorite])
    }

    func testInvalidPersistedDataFallsBackToDefaults() {
        userDefaults.set(Data("not-json".utf8), forKey: SongsTableColumnLayout.storageKey)

        let layout = SongsTableColumnLayout.load(userDefaults: userDefaults)

        XCTAssertEqual(layout, SongsTableColumnLayout.defaultLayout)
    }

    func testFavoriteDefaultMigrationRunsOnceAndThenRespectsUserVisibility() {
        var legacyLayout = SongsTableColumnLayout.defaultLayout
        legacyLayout.setVisibility(false, for: .favorite)
        legacyLayout.save(userDefaults: userDefaults)

        var migratedLayout = SongsTableColumnLayout.load(userDefaults: userDefaults)
        XCTAssertTrue(migratedLayout.visibleColumns.contains(where: { $0.id == .favorite }))

        migratedLayout.setVisibility(false, for: .favorite)
        migratedLayout.save(userDefaults: userDefaults)

        let reloaded = SongsTableColumnLayout.load(userDefaults: userDefaults)
        XCTAssertFalse(reloaded.visibleColumns.contains(where: { $0.id == .favorite }))
    }

    func testMissingColumnsAreRestoredWhenLoadingPersistedLayout() {
        let partial = SongsTableColumnLayout(columns: [
            SongsTableColumn(id: .title, width: 180, isVisible: true)
        ])

        partial.save(userDefaults: userDefaults)
        let reloaded = SongsTableColumnLayout.load(userDefaults: userDefaults)

        XCTAssertEqual(reloaded.columns.first?.id, .title)
        XCTAssertEqual(Set(reloaded.columns.map(\.id)), Set(SongsTableColumnLayout.definitions.map(\.id)))
        XCTAssertEqual(reloaded.columns.first { $0.id == .title }?.width, 180)
        XCTAssertEqual(reloaded.columns.first { $0.id == .favorite }?.isVisible, true)
        XCTAssertEqual(reloaded.columns.first { $0.id == .rating }?.isVisible, false)
    }

    func testRequiredTitleColumnCannotBeHidden() {
        var layout = SongsTableColumnLayout.defaultLayout

        layout.setVisibility(false, for: .title)

        XCTAssertTrue(layout.columns.first { $0.id == .title }?.isVisible == true)
    }

    func testColumnWidthsClampToMinimums() {
        var layout = SongsTableColumnLayout.defaultLayout

        layout.setWidth(1, for: .title)

        XCTAssertEqual(layout.columns.first { $0.id == .title }?.width, SongsTableColumnLayout.definition(for: .title).minimumWidth)
    }

    func testMoveColumnReordersVisibleColumns() {
        var layout = SongsTableColumnLayout.defaultLayout

        layout.moveColumn(.duration, toVisiblePositionOf: .title)
        XCTAssertEqual(layout.visibleColumns.map(\.id), [.artwork, .duration, .title, .artist, .album, .albumArtist, .favorite])

        layout.moveColumn(.albumArtist, toVisiblePositionOf: .artwork)
        XCTAssertEqual(layout.visibleColumns.map(\.id), [.albumArtist, .artwork, .duration, .title, .artist, .album, .favorite])
    }

    func testMoveColumnIgnoresHiddenColumns() {
        var layout = SongsTableColumnLayout.defaultLayout

        layout.moveColumn(.composer, toVisiblePositionOf: .title)

        XCTAssertEqual(layout.visibleColumns.map(\.id), SongsTableColumnLayout.defaultLayout.visibleColumns.map(\.id))
    }

    func testColumnValueFormatterFormatsTrackMetadata() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let track = Track(
            dbId: 1,
            fileURL: "file:///Music/Test.m4a",
            fileSize: nil,
            fileModifiedAt: nil,
            title: "Prelude",
            artist: "Performer",
            albumArtist: "Album Performer",
            album: "Works",
            composer: "Composer",
            genre: "Classical",
            year: 2024,
            trackNumber: 3,
            discNumber: 1,
            duration: 125,
            bitRate: 256_000,
            sampleRate: 44_100,
            channelCount: 2,
            format: "m4a",
            isFavorite: true,
            rating: 4,
            playCount: 7,
            lastPlayedAt: date,
            dateAdded: date,
            artworkId: nil,
            albumId: nil,
            artistId: nil
        )

        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .title), "Prelude")
        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .duration), "2:05")
        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .bitRate), "256 kbps")
        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .sampleRate), "44.1 kHz")
        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .format), "M4A")
        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .favorite), "Favorite")
        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .rating), "4 of 5 stars")
        XCTAssertEqual(SongsTableColumnValueFormatter.string(for: track, columnID: .playCount), "7")
    }

    @MainActor
    func testRatingCellActionDoesNotChangeSelectionOrInvokePlayback() {
        var selectedIDs: Set<Int64> = [10, 11]
        var playedTrackID: Int64?
        var ratedValue: Int?
        let cell = SongsRatingCellView(identifier: .init("rating-test"))
        cell.configure(rating: 2, isSelected: true) { ratedValue = $0 }

        cell.performRatingAction(4)

        XCTAssertEqual(ratedValue, 4)
        XCTAssertEqual(selectedIDs, Set([10, 11]))
        XCTAssertNil(playedTrackID)
        XCTAssertEqual(
            SongsTableInteraction.targetTrackIDs(clickedTrackID: 10, selectedTrackIDs: selectedIDs),
            [10, 11]
        )
        XCTAssertEqual(
            SongsTableInteraction.targetTrackIDs(clickedTrackID: 12, selectedTrackIDs: selectedIDs),
            [12]
        )
        _ = playedTrackID
        _ = selectedIDs
    }

    @MainActor
    func testRatingCellClearsRatingWhenSelectedStarIsClicked() {
        var ratedValue: Int? = 99
        let cell = SongsRatingCellView(identifier: .init("rating-clear-test"))
        cell.configure(rating: 3, isSelected: true) { ratedValue = $0 }

        cell.performRatingAction(3)

        XCTAssertNil(ratedValue)
    }

    func testRatingHoverPreviewsTheHoveredStarCount() {
        XCTAssertEqual(SongsRatingAppearance.displayedRating(currentRating: nil, hoveredRating: 3), 3)
        XCTAssertEqual(SongsRatingAppearance.displayedRating(currentRating: 5, hoveredRating: 2), 2)
        XCTAssertEqual(SongsRatingAppearance.displayedRating(currentRating: 4, hoveredRating: nil), 4)
    }

    @MainActor
    func testFavoriteCellActionDoesNotChangeSelectionOrInvokePlayback() {
        let selectedIDs: Set<Int64> = [10, 11]
        var playedTrackID: Int64?
        var favoriteValue: Bool?
        let cell = SongsFavoriteCellView(identifier: .init("favorite-test"))
        cell.configure(isFavorite: false, isSelected: true) { favoriteValue = $0 }

        cell.performToggleAction()

        XCTAssertEqual(favoriteValue, true)
        XCTAssertEqual(selectedIDs, Set([10, 11]))
        XCTAssertNil(playedTrackID)
        XCTAssertEqual(
            SongsTableInteraction.targetTrackIDs(clickedTrackID: 10, selectedTrackIDs: selectedIDs),
            [10, 11]
        )
        _ = playedTrackID
    }

}
