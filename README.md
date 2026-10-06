# LumeRecorder

A small, self-hosted DVR server for the [Lume](https://github.com/bilipp/Lume)
IPTV app. Lume schedules a recording ("record this programme"); LumeRecorder
runs on an always-on machine (NAS, mini PC, Raspberry Pi, Mac) and records the
stream with ffmpeg to HLS on disk, even when every Apple device is asleep.
Finished and in-progress recordings play back in Lume over short-lived signed
links.

- One ffmpeg process per recording, stream copy (no transcoding), HLS output.
- Automatic retries with `#EXT-X-DISCONTINUITY` when the source drops.
- Survives restarts: running recordings resume, missed ones are marked.
- Pairing with a 6-digit code, per-device bearer tokens (stored hashed).
- Bonjour discovery (`_lume-recorder._tcp`), JSON HTTP API, no database.

> **Your responsibility:** only record content you are entitled to record and
> keep. LumeRecorder ships no channels or streams. It records what your Lume
> app points it at, using your provider credentials, for your private use.

## Quick start (Docker Compose)

```yaml
# docker-compose.yml
services:
  lume-recorder:
    image: ghcr.io/bilipp/lumerecorder:latest
    container_name: lume-recorder
    restart: unless-stopped
    network_mode: host          # needed for Bonjour discovery
    volumes:
      - ./data:/data
```

```bash
docker compose up -d
docker logs lume-recorder | grep "Pairing code"
```

Or build from this checkout: `docker build -t lumerecorder .`

### docker run

```bash
docker build -t lumerecorder .
docker run -d --name lume-recorder --restart unless-stopped \
  --network host -v "$PWD/data:/data" lumerecorder
docker exec lume-recorder lume-recorder pair
```

On Docker Desktop (macOS/Windows) host networking can't carry Bonjour: publish
the port instead (`-p 8090:8090 -e BONJOUR=0`) and add the server in Lume by
address.

### Apple `container` (macOS on Apple silicon)

```bash
container system start
container build -t lumerecorder:dev .
mkdir -p ~/LumeRecorder-data
container run -d --name lume-recorder \
  -p 0.0.0.0:8090:8090 -v ~/LumeRecorder-data:/data \
  -e BONJOUR=0 lumerecorder:dev
container exec lume-recorder lume-recorder pair
```

The container runs in a VM, so Bonjour doesn't reach your network: in Lume use
**Settings → Recording Server → Enter Address Manually** with your Mac's IP and
port 8090.

The server runs as the unprivileged `lume` user. The entrypoint hands `/data`
to that user when it can; shared host folders (Docker Desktop, Apple
`container`) refuse `chown`, in which case it runs as the folder's owner or, if
only root can write there, as root, and says so in the log.

### Without Docker

Needs Swift 6 and ffmpeg (`brew install ffmpeg` / `apt install ffmpeg`):

```bash
swift run -c release lume-recorder --data-dir ./data
```

On macOS this also advertises the server via Bonjour, so the iOS Simulator and
devices on your LAN discover it.

## Pairing

1. Start the server. It logs a code, and logs a new one every 10 minutes:
   `Pairing code: 123 456 (valid 10 min)`
2. Print the current code at any time:
   `docker exec lume-recorder lume-recorder pair` (or `lume-recorder pair --data-dir ./data`).
3. In Lume, pick the discovered server (or enter `host:port`) and type the code.

A code stays valid for its whole 10-minute window, so several devices can pair
with it. After 5 wrong codes within a minute, pairing is locked for that
minute (`429`). Devices can be listed and unpaired from Lume.

## Configuration

Every variable also has a CLI flag on `lume-recorder serve` (e.g. `--port`,
`--data-dir`, `--max-concurrent`); a flag wins over its variable.

| Variable | Default | Meaning |
|----------|---------|---------|
| `PORT` | `8090` | HTTP port |
| `HOST` | `0.0.0.0` | Bind address |
| `DATA_DIR` | `/data` (Docker), `./data` otherwise | State, secrets and recordings |
| `MAX_CONCURRENT` | `4` | Recordings that may run at once (each holds one provider connection) |
| `MIN_FREE_GB` | `2` | Refuse/fail recordings below this much free disk |
| `SERVER_NAME` | hostname | Name shown in Lume and in Bonjour |
| `PUBLIC_URL` | unset | Base URL for playback links when a request carries no `Host` header |
| `FFMPEG_PATH` | `ffmpeg` on `PATH` | ffmpeg executable |
| `LOG_LEVEL` | `info` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` |
| `BONJOUR` | `1` | `0` disables Bonjour (NetService on macOS, avahi in Docker) |
| `TZ` | UTC | Container timezone (log timestamps only; the API is UTC) |

Data layout:

```
DATA_DIR/
├── server.json          server id + playback-signing secret (keep private)
├── recordings.json      recording records, including stream URLs (keep private)
├── devices.json         paired devices (SHA-256 token hashes only)
├── pairing-code.json    current pairing code (read by `lume-recorder pair`)
└── recordings/<id>/     index.m3u8 + a<attempt>_<n>.ts segments
```

Files are written atomically and readable only by the server user (`0600`).

## Bonjour / discovery

The server advertises `_lume-recorder._tcp` with TXT records `id=<server id>`,
`version=<version>`, `api=1`.

- **macOS (`swift run`)**: advertised with `NetService`.
- **Docker on Linux**: the entrypoint starts `avahi-daemon` inside the container.
  This only reaches your LAN with **`network_mode: host`**.
- **Bridge networking, Docker Desktop (macOS/Windows), or VLANs**: multicast
  doesn't leave the container. Set `BONJOUR=0` and enter `host:8090` in Lume.
- **The host already runs avahi-daemon** (common on NAS systems): two mDNS
  responders on one host fight over the hostname. Set `BONJOUR=0` and put this
  file in the host's `/etc/avahi/services/lume-recorder.service`, with the id from
  `docker exec lume-recorder lume-recorder server-id`:

  ```xml
  <?xml version="1.0" standalone='no'?>
  <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
  <service-group>
    <name replace-wildcards="yes">%h</name>
    <service>
      <type>_lume-recorder._tcp</type>
      <port>8090</port>
      <txt-record>id=PASTE-SERVER-ID</txt-record>
      <txt-record>version=0.1.1</txt-record>
      <txt-record>api=1</txt-record>
    </service>
  </service-group>
  ```

## HTTP API (v1)

All JSON; dates are ISO-8601 UTC (fractional seconds optional on input).
Errors always look like `{"error":{"code":"snake_case","message":"…"}}`.
Swift clients should use `LumeRecorderKit` (in `Kit/`), which wraps all of this.

| Method & path | Auth | Purpose |
|---------------|------|---------|
| `GET /api/v1/info` | none | `ServerInfo {id, name, version, apiVersion}` |
| `POST /api/v1/pair` | none | `{code, deviceName}` → `{token, deviceID, server}`; `401 pairing_invalid`, `429 rate_limited` |
| `GET /api/v1/recordings` | bearer | All recordings, newest start first |
| `POST /api/v1/recordings` | bearer | Schedule/start one → `201`. Optional `Idempotency-Key` header: a repeat from the same device returns the original with `200` |
| `POST /api/v1/recordings/{id}/stop` | bearer | Scheduled → `cancelled`; recording → graceful stop → `completed` |
| `DELETE /api/v1/recordings/{id}` | bearer | Stop if needed, delete media and record → `204` |
| `POST /api/v1/recordings/{id}/playback` | bearer | `{url, expiresAt}`: signed HLS link valid 12 h (`409 not_playable` before the first segment) |
| `GET /api/v1/status` | bearer | Active/scheduled counts, disk space, `maxConcurrent` |
| `GET /api/v1/devices` | bearer | Paired devices |
| `DELETE /api/v1/devices/{id}` | bearer | Unpair (your own device too) → `204` |
| `GET /play/{id}/{expiry}/{sig}/{file}` | signature | `index.m3u8` / `*.ts`. Works while recording |

Create body: `{streamURL, title, channelName?, channelLogoURL?,
programmeDescription?, start, end, sourceRef?}`. Rules: http/https stream URL,
`end > start`, `end` in the future, at most 12 h. A `start` in the past starts
immediately. If that would exceed `MAX_CONCURRENT` you get `409
concurrency_limit`, and low disk gives `507 insufficient_storage`. A scheduled
recording that hits either limit at its start time becomes `failed` with that
`failureReason`.

`Recording.status` is `scheduled`, `recording`, `completed`, `failed` or
`cancelled`. Clients must tolerate unknown future values. The stream URL is
never returned by the API or written to the log.

Bearer auth: `Authorization: Bearer <token>`. Playback links carry their HMAC
in the **path** (`/play/<id>/<expiry>/<hmac>/index.m3u8`). That way the
playlist's relative segment URIs inherit the signature, and players need no
headers.

## Recording behaviour

- ffmpeg reads the source in real time (`-readrate 1`, with a 10 s initial
  burst where supported), so a "live" channel that is really a file is recorded
  at wall-clock pace rather than slurped.
- If ffmpeg exits before the end, the recorder retries with backoff from 2 s up
  to 30 s. Each attempt appends to the same playlist behind a discontinuity.
- At the end, or on stop, ffmpeg gets SIGINT (then SIGTERM/SIGKILL after 10 s).
  The playlist always ends with `#EXT-X-ENDLIST`.
- A recording that captured nothing becomes `failed` with
  `no_segments: <last ffmpeg lines>`, URLs redacted. If the source refuses to
  open five times in a row (each attempt dying within 2 s) before anything was
  captured, the recorder stops early with `source_unavailable: <last ffmpeg
  lines>`.
- On restart, running recordings resume as a new attempt. Ones that ended while
  the server was down become `completed` (if media exists) or `failed`.
  Scheduled ones whose window passed become `failed` (`missed`).
- `docker stop` (SIGTERM) stops ffmpeg cleanly and keeps the rows `recording`,
  so they resume when the container is back.

## Development

```bash
swift build && swift test           # server (Swift Testing + HummingbirdTesting)
(cd Kit && swift test)              # client kit
```

The real-ffmpeg integration test is skipped when ffmpeg isn't installed. See
`AGENTS.md` for architecture and invariants.

## License

AGPL-3.0. See [LICENSE](LICENSE).
