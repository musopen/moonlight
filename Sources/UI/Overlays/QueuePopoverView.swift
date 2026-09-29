// QueuePopoverView.swift
//
// A small pop-up list titled "Up Next" that opens from the list button in the playback bar. It
// shows the songs in the play queue, scrolled to the current one, which has a speaker icon beside
// it. Double-clicking a song jumps straight to it; songs whose files are missing are dimmed and
// cannot be played.

import SwiftUI

struct QueuePopoverView: View {
    @EnvironmentObject var controller: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next")
                .font(.headline)
                .padding()
            Divider()
            if controller.queue.isEmpty {
                Text("Nothing is queued.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                queueList
            }
        }
        .frame(width: 300, height: 400)
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(controller.queue, id: \.dbId) { track in
                    HStack {
                        if controller.currentTrack?.hasSameIdentity(as: track) == true {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        VStack(alignment: .leading) {
                            Text(track.displayTitle).lineLimit(1)
                            Text(track.displayArtist)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(track.durationFormatted)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .opacity(track.isAvailable ? 1 : 0.5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard track.isAvailable else { return }
                        controller.play(track: track, in: controller.queue)
                    }
                }
            }
            .listStyle(.plain)
            .onAppear {
                if let current = controller.currentTrack {
                    proxy.scrollTo(current.dbId, anchor: .center)
                }
            }
        }
    }
}
