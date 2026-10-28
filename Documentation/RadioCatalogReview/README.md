# Radio catalog follow-up, October 27, 2026

This review follows the snapshot included in Mac version 1.4.2, build
202610270643. These changes require a subsequent build. They do not change the
build already submitted to Apple.

The starting catalog had 41,821 channels and 44,726 stream records. The reviewed
catalog has 41,764 channel identities, of which 41,743 have an eligible stream.
All 44,726 stream IDs and station UUIDs remain available for favorite migration.

## Results

- Reviewed all 45 exact shared-stream groups. No stream URL is shared by distinct
  eligible channels after the changes.
- Merged 57 additional duplicate records. This includes bitrate-labelled KFJC
  and StreamingSoundtracks copies found during playlist checks, and three
  Breakz endpoints whose simultaneous 256 KiB samples were byte-identical.
- Repaired Rockland Ludwigshafen and Omroep Tilburg links. Removed the incorrectly
  attached Peppermint alternate from ffn 80er without merging those two stations.
- Withheld 33 stream records, leaving 21 station identities temporarily unavailable.
  These include obsolete themed feeds that resolve to other channels, an Oasis
  feed identifying as KCHS 101.9, unverified regional mappings, and a TuneIn
  announcement presented as Ukulele Island. They remain recorded with reasons.
- Checked all 22 default URLs containing `.pls`. Each returned audio, rather than
  a playlist. Fourteen now use checked direct endpoints or omit unnecessary query
  suffixes. Eight retain their working audio URLs. Live response bitrate and codec
  metadata were corrected where available. A filename suffix alone is not a
  reliable playlist test.
- Assigned 258 previously missing country codes using broadcaster-owned websites
  with verifiable location or transmission-area evidence. Another seven unknown
  identities disappear through confirmed merges. There are 744 country codes
  still unknown. Hosting platforms, server locations, language and country-code
  domain suffixes alone were not used to guess a station's country.

## Decisions and evidence

[Shared-stream decisions](shared-stream-decisions.csv) records each original
conflict, its resolution and a source link. [Stream checks](stream-checks.json)
records bounded HTTP audio and playlist probes, response metadata and short byte
prefixes. Full audio and scraped pages are not included.

[Playlist decisions](playlist-decisions.csv) records all 22 checked URLs and any
replacement. [Stream repairs](stream-repairs.csv) records the two wrong-station
links replaced. [Withheld streams](withheld-streams.csv) records each excluded
stream and reason. [Aliases](new-channel-aliases.csv) records every merge.
[Breakz comparison](breakz-comparison.json) records hashes and matching windows.

[Country additions](country-additions.csv) records assignments against the starting
identities, including identities subsequently merged. Sources include broadcaster
legal addresses in Berlin, Halle, Dresden, Stuttgart, Bad Vilbel and Belgrade,
and explicitly identified German transmission areas. Generic directory and
stream-host domains were excluded. Existing incorrect country labels on duplicate
records are superseded by their retained, verified station identity.

## Playback and saved stations

Schema version 2 adds `stream_exclusions`, with a reason and source URL per stream,
and `country_sources` for surviving country assignments. A station without an
eligible stream does not appear in browsing or country counts. Excluded streams
cannot become defaults, alternates or bitrate-filter matches. Defaults prefer the
highest listed bitrate among eligible streams; only live checks establish actual
current bitrate.

Old channel aliases are flattened to their surviving identity. Withheld favorites
stay saved and appear in the existing unavailable-stations section. They can be
removed by the user, or return automatically when a future catalog restores a
verified stream for the same identity. No favorite is silently redirected to a
known wrong station merely to eliminate a shared URL.
