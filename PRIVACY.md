# Privacy

Moonlight is a local-first music player. Your music, your library and your listening
history stay on your own devices. This page lists everything the app sends over the
network, and why.

## What stays on your device

- **Your music files and artwork.** They are never uploaded anywhere.
- **Your library database**: tracks, albums, playlists, ratings, favorites and play
  counts, stored locally on your Mac or iPhone/iPad.
- **Folder access.** Moonlight only reads the folders you choose to add.

## What leaves your device

### iCloud sync (your private iCloud account)

If you are signed in to iCloud, Moonlight syncs your ratings, favorites, playlists,
play counts and track identities between your devices using Apple's CloudKit. This
data goes to **your own private iCloud database**. Musopen cannot see it. Audio files
and artwork are never synced.

### Anonymous usage statistics (Google Analytics)

Moonlight sends a small number of anonymous events to Google Analytics (via Firebase)
to help us understand how the app is used:

- the app was opened
- playback started (how many tracks were queued and whether shuffle was on)
- a library scan finished (how it was started, and counts of files found, changed, removed,
  missing or with errors)

No music, file names, titles, search terms or personal information are sent. Moonlight
uses the version of Firebase that does not include Google's advertising-identifier
components. Google does receive standard technical information such as an
app-instance ID, device model and OS version.

**This is on by default.** Turn it off at any time in **Settings > Privacy > Google
Analytics**. Builds made from this source code without Musopen's private Firebase
configuration send no analytics at all.

### Internet radio

- **Station directory.** Moonlight ships with a built-in station list that Musopen
  reviews and maintains, originally derived from
  [radio-browser.info](https://www.radio-browser.info/). Browsing and searching it
  happens entirely on your device.
- **Playing a station.** Moonlight connects directly to the broadcaster's stream. The
  broadcaster sees your IP address, like any website does. Moonlight doesn't contact
  any station directory, and doesn't tell anyone else which stations you play.

### Last.fm (only if you connect it)

If you connect a Last.fm account in **Settings > Integrations**, Moonlight sends the
artist, track, album and timing of what you play to Last.fm for scrobbling. Your
Last.fm login is stored in the system Keychain. Nothing is sent to Last.fm unless you
connect an account.

### Feedback form (only if you use it)

If you send feedback from the app, Moonlight sends your message and, if you provide
one, your email address to Musopen at moonlightapp.org so we can reply.

## Questions

Open an issue on GitHub, or use the feedback form in the app.
