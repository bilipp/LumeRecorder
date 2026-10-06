# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-06

### Added
- HTTP API v1 (`/api/v1`): info, pairing, recordings (list/create/stop/delete),
  signed playback grants, status and device management.
- ffmpeg-based HLS recorder with real-time pacing, retries with backoff and
  discontinuities, graceful SIGINT/SIGTERM/SIGKILL stop and guaranteed
  `#EXT-X-ENDLIST`.
- Restart recovery: running recordings resume, missed ones are marked failed.
- 6-digit rotating pairing code with a global failed-attempt rate limit, and
  per-device bearer tokens stored as SHA-256 hashes.
- Path-signed (HMAC-SHA256) playback URLs that work for in-progress recordings.
- Bonjour discovery: `NetService` on macOS, avahi in the Docker image.
- `LumeRecorderKit`: a zero-dependency Swift client and DTO package for the Lume app.
- Multi-stage Docker image (amd64/arm64), docker-compose example and CI workflow.
- HLS sources with mislabelled subtitle renditions record via `-extension_picky 0`
  (HLS inputs only); sources that fail five quick attempts in a row before any
  media is captured are marked failed (`source_unavailable`).
- The container starts with shared host folders (Docker Desktop, Apple
  `container`) that refuse `chown` on `/data`.
