# Omi Desktop Codex Audit

Phase 1 audit only. No source changes are included here. Scope was limited to `desktop/`, with only cursory top-level context outside it.

## A. Repo Map (Cursory)

- `.github/` - monorepo issue and CI workflows; desktop release automation is referenced from `desktop/CLAUDE.md`.
- `app/` - Flutter mobile app; shares Omi backend concepts, device flows, and product data models, but is not part of the macOS build.
- `backend/` - Python/FastAPI cloud services the desktop app calls over HTTPS/WS, including `/v4/listen`, `/v2/voice-message/*`, auth-dependent user data, subscriptions, and payments.
- `docs/` - Mintlify/product developer docs; broader docs are out of scope for this pass unless explicitly approved later.
- `firmware` folders: `omi/` and `omiGlass/` - wearable firmware/hardware projects; desktop relates through BLE device protocols only.
- `mcp/`, `plugins/`, `sdks/`, `web/` - integrations, external SDKs, and web/admin surfaces; useful ecosystem context, no direct desktop build path observed.
- `scripts/` and dot-config folders - repo-level tooling and agent/editor configuration; not modified for this audit.

## B. Desktop Directory Map

```text
desktop/
|-- README.md                         - very short desktop overview and run command; missing most setup/release/testing detail.
|-- CLAUDE.md                         - desktop-specific agent notes, logs, architecture notes, and release pipeline summary.
|-- CHANGELOG.json                    - machine-readable release notes/history.
|-- .env.example                      - Swift app environment example copied into the app bundle by run.sh.
|-- run.sh                            - main local dev runner: starts Rust backend, Auth-Python, optional Cloudflare tunnel, builds/signs/installs/launches the Swift app.
|-- Auth-Python/
|   |-- main.py                       - FastAPI OAuth broker for Google/Apple sign-in and Firebase custom token exchange.
|   |-- .env.example                  - auth service env example.
|   `-- templates/                    - OAuth completion/error pages.
|-- Backend-Rust/
|   |-- Cargo.toml / Cargo.lock       - Rust sidecar/backend crate.
|   |-- run.sh / Dockerfile           - local/container launch helpers.
|   |-- charts/                       - deployment chart material.
|   `-- src/
|       |-- main.rs                   - Axum server entry point and service wiring.
|       |-- config.rs                 - environment-backed configuration.
|       |-- auth.rs                   - Firebase token validation and auth extraction.
|       |-- encryption.rs             - encrypted user data helpers.
|       |-- llm/                      - model routing, prompts, persona, and LLM client code.
|       |-- models/                   - Firestore/API model structs.
|       |-- routes/                   - REST, proxy, auth, appcast/update, TTS, agent, and CRUD routes.
|       `-- services/                 - Firestore, Redis, and integration service clients.
|-- Desktop/
|   |-- Package.swift                 - SwiftPM macOS 14 executable target, dependencies include Firebase, GRDB, Sentry, Sparkle, ONNX Runtime, libwebp.
|   |-- Info.plist                    - bundle metadata, URL scheme, permission usage strings, Sparkle feed/public key.
|   |-- Omi.entitlements              - dev entitlements.
|   |-- Omi-Release.entitlements      - release entitlements.
|   |-- Node.entitlements             - helper/node entitlements.
|   |-- CWebP/                        - system library shim for libwebp.
|   |-- ObjCExceptionCatcher/         - Objective-C exception bridge target.
|   |-- Sources/
|   |   |-- OmiApp.swift              - `@main` SwiftUI app plus `AppDelegate`; menu bar, launch, URL events, Sparkle init, legacy bundle cleanup.
|   |   |-- AppState.swift            - primary app state, recording lifecycle, transcription, device and permission coordination.
|   |   |-- APIClient.swift           - Python and Rust backend HTTP client.
|   |   |-- AuthService.swift         - OAuth flow, Firebase token exchange, local auth persistence.
|   |   |-- TranscriptionService.swift - WebSocket and REST transcription against Python backend.
|   |   |-- ScreenCaptureService.swift - TCC, ScreenCaptureKit, AX window lookup, capture and recovery helpers.
|   |   |-- Bluetooth/                - CoreBluetooth manager, transports, device UUIDs and connection implementations.
|   |   |-- FloatingControlBar/       - menu/floating bar, PTT, screenshots, voice playback, notifications.
|   |   |-- MainWindow/               - SwiftUI app shell and settings/pages.
|   |   |-- ProactiveAssistants/      - focus/insight/task assistants, Gemini proxy client, embedding services.
|   |   |-- Rewind/                   - local timeline database, screenshot indexing, timeline UI.
|   |   |-- WAL/                      - local storage sync and Wi-Fi sync views/services.
|   |   `-- Resources/                - icons, videos, permission GIFs, ONNX VAD model.
|   `-- Tests/                        - Swift unit tests for routing, listen protocol, permissions policy, reentrancy, transcription assignment, settings, etc.
|-- agent/                            - TypeScript local agent runtime built by run.sh.
|-- agent-cloud/                      - cloud agent service package.
|-- pi-mono-extension/                - TypeScript extension package/tests.
|-- demo/                             - Remotion/demo web project.
|-- dmg-assets/                       - DMG background/settings assets.
|-- e2e/                              - desktop exploration/agent-swift guidance and flows.
`-- scripts/                          - small desktop helper scripts.
```

Entry points and boundaries:

- Swift entry point is `Desktop/Sources/OmiApp.swift` using SwiftUI `@main`; there is an `AppDelegate`, no separate `SceneDelegate`.
- Rust entry point is `Backend-Rust/src/main.rs`; it exposes Axum HTTP routes and uses Firestore/Redis/external services.
- Swift <-> Rust bridge: no direct FFI found. The Swift app talks to the Rust backend over HTTP using `OMI_API_URL`; it talks to Python cloud/backend transcription using `OMI_PYTHON_API_URL`; it talks to Auth-Python using `OMI_AUTH_URL`. C/ObjC bridges are limited to libwebp and Objective-C exception handling.
- Auto-update is Sparkle 2: Swift dependency in `Desktop/Package.swift`, feed/public key in `Desktop/Info.plist`, runtime channel handling in `AppBuild.swift`/`UpdaterViewModel.swift`, and appcast/release registration routes in `Backend-Rust/src/routes/updates.rs`.
- Build/packaging path is mostly `run.sh` for dev and the documented GitHub Actions -> Codemagic -> DMG/Sparkle/GCS/Firestore pipeline in `desktop/CLAUDE.md`.

## C. Bugs & Issues

| severity | path:line | category | description | proposed fix | rough effort |
|---|---:|---|---|---|---|
| high | `desktop/run.sh:216-220`, `desktop/run.sh:288-290` | dev networking | Cloudflare tunnel starts before `BACKEND_PORT` is initialized, so it defaults to `localhost:8080` while the Rust backend default is `10201`. Tunnel-based dev runs can publish a dead backend URL. | Initialize/export `BACKEND_PORT="${PORT:-10201}"` before tunnel startup, or use `${PORT:-10201}` directly when creating the tunnel. | S |
| medium | `desktop/run.sh:151-158`, `desktop/run.sh:365-375`, `desktop/run.sh:762-765` | dev process management | Auth-Python is started inside a background subshell that backgrounds `uvicorn`; `AUTH_PID=$!` captures the wrapper subshell, not the uvicorn process. Cleanup and `wait` can leave the auth service running or report a stale PID. | Start uvicorn as the single background process after sourcing env, or write the child PID to a temp file and have cleanup kill that PID. | S |
| low | `desktop/run.sh:716-718` | LaunchServices / packaging | Stale DMG app registrations are unregistered only when the path is not a directory: `[ -d "$stale" ] || lsregister -u "$stale"`. Real stale app bundles are skipped. | Change the condition to unregister when the directory exists. | S |
| medium | `desktop/Desktop/Sources/FloatingControlBar/FloatingControlBarWindow.swift:47-49`, `desktop/Desktop/Sources/FloatingControlBar/FloatingControlBarWindow.swift:353-374`, `desktop/Desktop/Sources/FloatingControlBar/FloatingControlBarWindow.swift:1790-1794` | UI race / PTT | `resignKeyAnimationToken` exists and `cancelPendingDismiss()` increments it, but `closeAIConversation()` completion blocks never capture/check the token. A stale close completion can still collapse/hide the bar during a rapid new PTT session. | Capture the current token in `closeAIConversation()` and guard both delayed completions on token equality before mutating frame, hover suppression, or visibility. | S/M |
| high | `desktop/Desktop/Sources/OmiApp.swift:1124-1134`, `desktop/Desktop/Sources/AuthService.swift:511-529` | security / auth logging | OAuth callback URLs are logged verbatim in both AppDelegate and AuthService, including `code` and `state` query values. These short-lived secrets end up in macOS Console/log files. | Log only scheme/host/path and a redacted query summary; never log authorization codes or full callback URLs. | S |
| high | `desktop/Desktop/Sources/AuthService.swift:73-82`, `desktop/Desktop/Sources/AuthService.swift:782-807` | security / token storage | Firebase ID and refresh tokens are persisted in `UserDefaults`. The comment says this supports ad-hoc dev signing, but the code path is not limited to dev builds. Refresh tokens should not be stored in plaintext preferences. | Move token persistence to Keychain for signed builds; if a dev fallback is required, gate it clearly to non-production and document the behavior. | M |
| high | `desktop/Desktop/Sources/Bluetooth/Transports/BleTransport.swift:124-141`, `desktop/Desktop/Sources/Bluetooth/Transports/BleTransport.swift:260-288` | BLE / async hangs | CoreBluetooth connect, service discovery, read, and write-with-response operations use continuations without timeouts. If the delegate callback never arrives, `DeviceProvider.isConnecting` or the caller can hang indefinitely. | Wrap these awaits in a shared timeout helper that resumes/clears continuations and cancels/disconnects as appropriate. | M |
| medium | `desktop/Desktop/Sources/Bluetooth/Transports/BleTransport.swift:40-92`, `desktop/Desktop/Sources/Bluetooth/Transports/BleTransport.swift:115-119` | BLE / memory leak | Only the first block observer token is retained and removed. The disconnect and failed-to-connect observers are not stored, and `removeObserver(self)` does not remove block observers. | Store all observer tokens in an array and remove each token in `deinit`/dispose. | S |
| medium | `desktop/Desktop/Sources/Providers/DeviceProvider.swift:228-239`, `desktop/Desktop/Sources/Providers/DeviceProvider.swift:681-705` | BLE state machine | `DeviceProvider` implements `DeviceConnectionDelegate`, but new connections are never assigned `connection.delegate = self`. Fall detection and delegate-driven unexpected-disconnect handling are effectively dead paths. | Set the delegate before connecting/storing the active connection and clear it on disconnect/unpair. | S |
| low | `desktop/Desktop/Sources/Bluetooth/Transports/BleTransport.swift:199-203`, `desktop/Desktop/Sources/Bluetooth/Transports/BleTransport.swift:427-432` | BLE health checks | `readRSSIAsync()` triggers `readRSSI()` then immediately returns `0`, so `ping()` succeeds for any `.connected` peripheral without waiting for the delegate result or error. | Implement RSSI as a delegate-backed continuation with timeout, or remove RSSI from connection verification and use a real characteristic probe. | M |
| medium | `desktop/Desktop/Sources/ScreenCaptureService.swift:205-218` | TCC permissions | `requestAllScreenCapturePermissions()` calls asynchronous LaunchServices registration and immediately calls `CGRequestScreenCaptureAccess()`. The comment says registration must precede the TCC prompt, but the code can race and prompt against stale registration. | Use the synchronous registration helper before `CGRequestScreenCaptureAccess()`, or make this flow async and await registration completion. | S |
| medium | `desktop/Desktop/Sources/OmiApp.swift:1211-1231` | safety / packaging | Legacy bundle cleanup finds old app paths, then force-terminates every running app with production bundle id `com.omi.computer-macos`, not only the app at the old path. This can terminate an unrelated production instance. | Filter running apps by `bundleURL?.path == oldPath` before terminating; never terminate by bundle id alone. | S |
| medium | `desktop/Backend-Rust/src/main.rs:141-153` | Rust startup / panic | On Firestore initialization failure, startup logs "using placeholder" but retries the same fallible constructor and unwraps it. Invalid credentials/config will panic anyway. | Replace the fallback with an explicit fatal error/early return, or create a real degraded placeholder if supported. Avoid `unwrap()` on the repeated initialization. | S |
| medium | `desktop/Backend-Rust/src/services/firestore.rs:1621-1626`, `desktop/Backend-Rust/src/services/firestore.rs:1693-1698`, `desktop/Backend-Rust/src/services/firestore.rs:1762-1766`, `desktop/Backend-Rust/src/services/firestore.rs:6461`, `desktop/Backend-Rust/src/services/firestore.rs:7656-7661`, `desktop/Backend-Rust/src/services/firestore.rs:7752`, `desktop/Backend-Rust/src/services/firestore.rs:9459-9481` | persistence / unhandled results | Several bulk Firestore mutations ignore request errors and response status with `let _ = ...send().await` or ignored service results. Callers can receive success/counts after partial or total write failure. | Check status for each write and return the first error, or collect partial failures and surface them to the route. | M |
| medium | `desktop/Backend-Rust/src/routes/updates.rs:70-100`, `desktop/Backend-Rust/src/routes/updates.rs:103-108` | auto-update / XML generation | Sparkle appcast XML is assembled with raw release fields and changelog strings. Release metadata containing XML/HTML control characters can break the appcast and block updates. | Escape XML attributes/text and sanitize CDATA boundaries, or use an XML writer/serializer. | S/M |
| medium | `desktop/Auth-Python/main.py:307-317`, `desktop/Auth-Python/main.py:349-358` | auth networking | FastAPI async handlers call blocking `requests.post()` without a timeout for Apple/Google token exchange. A provider hang can block the worker and stall sign-in. | Use `httpx.AsyncClient` with explicit connect/read timeout, or run blocking calls in a thread with timeout. | S/M |
| low | `desktop/run.sh:58-64` | security / configuration | `--yolo` mode hardcodes a Firebase API key in the runner. Firebase web API keys are often public identifiers, but this is production credential-like config embedded in a dev script and should be intentional/documented. | Move it to `.env`/backend config or document why this public key is safe to embed. | S |
| medium | `desktop/Desktop/Sources/APIClient.swift:119-170`, `desktop/Desktop/Sources/APIClient.swift:340-360` | Swift force unwrap / networking | Core request helpers and several ad hoc API calls force-unwrap URLs built from environment-derived bases and interpolated path/query values. Invalid `OMI_*_API_URL` or unescaped IDs can crash instead of surfacing an API error. | Add a URL construction helper that validates base URLs and percent-encodes path/query values; throw `APIError.invalidURL` instead of force-unwrapping. | M |

## D. Documentation Gaps

- `desktop/README.md` is not complete enough for a new desktop contributor. It lacks concrete prerequisites, install steps, `.env` setup, Swift+Rust+Auth-Python process model, code signing setup, common `run.sh` modes, signed DMG flow, Sparkle/local appcast testing, TCC reset commands, log locations, and troubleshooting.
- No `desktop/ARCHITECTURE.md` exists. The desktop process model should be documented explicitly: Swift host app, Rust HTTP backend, Auth-Python OAuth broker, TypeScript agent runtime, BLE device flow, Python cloud endpoints, Sparkle update flow, and permission/TCC model.
- Swift <-> Rust boundary docs are missing. The code appears to use HTTP/local service boundaries, not FFI. That should be documented so future contributors do not hunt for a non-existent FFI layer.
- `.env.example` files are not fully aligned with code reads:
  - `Backend-Rust/src/llm/model_qos.rs:23` reads `OMI_MODEL_TIER`, but `Backend-Rust/.env.example` does not list it.
  - `Backend-Rust/src/routes/updates.rs:260` and `:342` read `RELEASE_SECRET`, but `Backend-Rust/.env.example` does not list it.
  - `Auth-Python/main.py:38` reads `FIREBASE_CREDENTIALS_JSON`, but `Auth-Python/.env.example` does not list it.
  - `desktop/.env.example` describes `DEEPGRAM_API_KEY` as required for real-time transcription, but inspected Swift transcription routes through the Python backend using Firebase auth. The doc should clarify when this key is actually needed.
- Auto-update documentation is split between code and `desktop/CLAUDE.md`. `README.md` should include the practical path: Sparkle public key/appcast URL, release registration endpoint, `RELEASE_SECRET`, GCS/Firestore release metadata, local appcast testing, quarantine/xattr recovery, and channel promotion.
- TCC/permission testing docs are missing from user-facing desktop docs. Add exact reset commands for ScreenCapture, Microphone, Accessibility/AX, Notifications where applicable, plus the bundle-id caveat for named dev builds.
- Swift file-level documentation is inconsistent on high-risk files. Candidates for concise file/type headers: `OmiApp.swift`, `AppState.swift`, `APIClient.swift`, `AuthService.swift`, `TranscriptionService.swift`, `ScreenCaptureService.swift`, `FloatingControlBarWindow.swift`, `PushToTalkManager.swift`, `BluetoothManager.swift`, `DeviceProvider.swift`, `Chat/AgentBridge.swift`, and the Rewind database/indexer files.
- Rust public API documentation is thin outside a few comments. Add Rustdoc to public route constructors/handlers, public models, `AppState`, Firestore service methods that define persistence contracts, and update/appcast release types.
- `CHANGELOG.md` does not exist; only `CHANGELOG.json` does. Phase 2 should either add a human-readable desktop changelog entry or document that `CHANGELOG.json` is the canonical changelog and update it according to the repo's release tooling.
