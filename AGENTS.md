# LumeRecorder: Agent Guide

A self-hosted DVR server for the Lume IPTV app (`bilipp/Lume`). Lume sends
"record this stream from A to B". The server records it with ffmpeg to HLS
and later hands out signed playback URLs.

## Layout

```
Package.swift                 server package (RecorderCore + lume-recorder)
Kit/                          LumeRecorderKit: wire DTOs + async client, ZERO deps
  Sources/LumeRecorderKit/    Models, Coding (shared JSON coders), Client, Error
  Tests/                      Codable round-trips, normalizedBaseURL, client w/ URLProtocol stub
Sources/RecorderCore/
  RecorderConfig.swift        env/CLI config, version
  RecorderServices.swift      object graph (store, scheduler, pairing, signer)
  RecorderServer.swift        Hummingbird app + ServiceLifecycle services
  Storage/                    RecorderStore actor (JSON files), AtomicFile
  Recording/                  RecordingScheduler actor, ffmpeg process + args, HLS helpers, disk space
  Security/                   PairingManager, PlaybackSigner, Secrets, Redactor
  HTTP/                       Routes, request context, bearer auth, JSON errors
  Discovery/                  NetService advertiser (macOS only)
Sources/lume-recorder/        CLI: serve (default) | pair | server-id
Tests/RecorderCoreTests/      Swift Testing: store, scheduler (fake launcher), recovery,
                              pairing, signing, routes (HummingbirdTesting), real ffmpeg
docker/entrypoint.sh          avahi service file + avahi-daemon, then drop to `lume`
```

## How a recording flows

1. `POST /api/v1/recordings` → `RecordingScheduler.create`: validate,
   deduplicate on (device, `Idempotency-Key`), admit (concurrency + disk) if it
   starts now, persist, start a job task.
2. The job sleeps until `start`. A scheduled job is admitted at that moment or
   fails with `concurrency_limit` / `insufficient_storage`.
3. `recordLoop` launches one ffmpeg per attempt through `RecordingProcessLauncher`.
   An end timer sends SIGINT → (10 s) SIGTERM → (3 s) SIGKILL. A stop or
   delete request waits for the exit, so it sends SIGTERM after 1 s instead.
   If ffmpeg exits
   early it backs off (2 s → 30 s, reset after a 60 s attempt) and starts attempt
   n+1. ffmpeg's `append_list` adds the `#EXT-X-DISCONTINUITY`. Five attempts
   in a row that exit within 2 s while nothing has been captured yet end the
   loop: the recording fails as `source_unavailable: <redacted stderr tail>`.
4. `finalize`: append `#EXT-X-ENDLIST` if missing, then `completed` if any
   segment exists, else `failed` (`no_segments: <redacted stderr tail>`).
5. Shutdown (SIGTERM/SIGINT) stops ffmpeg but doesn't finalize. `recover()` at
   the next start resumes future-ending `recording` rows as a new attempt.

Tests drive all of this with `FakeLauncher`/`FakeProcess`. Keep the scheduler
talking only to the `RecordingProcess` protocol.

## Invariants (do not break)

- **Never log or return stream URLs.** They carry provider credentials. The
  URL goes into `RecordingRecord` (disk, `0600`) and the ffmpeg argv, and
  nowhere else. Anything derived from ffmpeg output passes through
  `Redactor.redact(_:streamURL:)` before it reaches a log or `failureReason`.
  `Recording` (the public DTO) has no stream URL field. Keep it that way.
- **Playback signatures live in the path**: `/play/{id}/{expiry}/{hmac}/{file}`.
  Relative segment URIs in `index.m3u8` must inherit the signature, so never
  move it to a query string. HMAC-SHA256 over `"{lowercased id}:{expiry}"` with
  the secret from `server.json`. File names are whitelisted
  (`[A-Za-z0-9_-]+.(m3u8|ts)`) and resolved inside the recording directory.
- **Tokens are stored only as SHA-256 hashes** (`devices.json`).
- **State writes are atomic** (temp file + `rename`) and go through the single
  `RecorderStore` actor. Don't write those JSON files from anywhere else.
- **The Kit has zero dependencies** (Foundation only, FoundationNetworking on
  Linux). The Lume app links it as a local package. A dependency there lands in
  the app's graph. Everything public is `Sendable`, with no actor isolation.
- **API changes go through Kit + server in lockstep.** DTOs are defined once in
  the Kit and used by the server. Both sides build their coders from
  `LumeRecorderCoding`. Additive changes (new optional fields, new
  `RecordingStatus` raw values, which old clients decode as `.unknown`) keep
  `apiVersion` 1. Anything breaking bumps `LumeRecorderAPI.version`, gets a new
  path prefix and a CHANGELOG entry. The client rejects servers whose
  `apiVersion` differs.
- **The client never retries POST/DELETE.** Idempotency keys exist so the app
  can retry safely itself.
- A recording holds a concurrency slot from admission to finalization,
  including retry backoff.

## ffmpeg notes

- Args live in `FFmpegArguments.make`. Optional input flags (`-readrate`,
  `-readrate_initial_burst`, `-readrate_catchup`) are detected once from
  `ffmpeg -h long`. Ubuntu noble's ffmpeg 6.1 lacks `-readrate_catchup`.
- `-extension_picky 0` (detected from `ffmpeg -h demuxer=hls`) lets HLS masters
  whose WebVTT subtitle rendition is packaged as `.mp4` open. It is an HLS
  demuxer option: any other input fails with "Option extension_picky not
  found". So it is passed only when `RecordingAttemptSpec.hlsInput` is set:
  from the URL (`.m3u8`/`.m3u`) at first, then flipped by the scheduler when
  stderr shows the extension mismatch (on) or the unknown option (off).
- No explicit `-map`: `-map 0:v? -map 0:a?` copies every variant of an HLS
  master playlist. Default selection picks the best video + audio. Subtitles and
  data are dropped (`-sn -dn`) because some (WebVTT) can't be stream-copied into
  MPEG-TS.
- ffmpeg is spawned with SIGINT/SIGTERM unblocked (`withStopSignalsUnblocked`).
  A child inherits its spawning thread's signal mask, and on Linux the Swift
  executor's threads block both. ffmpeg never unblocks them, so it ignored
  every graceful stop and died to SIGKILL. `aRequestedStopEndsFFmpegOnSIGINT`
  (Linux CI) guards this. macOS never showed it.
- The working directory is the recording directory. Playlist and segment names
  are relative so `index.m3u8` references `a<attempt>_%05d.ts` plainly.

## Build & test

```bash
swift build && swift test
(cd Kit && swift test)
xcodebuild build -scheme LumeRecorderKit -destination 'generic/platform=tvOS'   # from Kit/
docker build -t lumerecorder .
```

Swift 6 language mode everywhere. Keep the build warning-free.
