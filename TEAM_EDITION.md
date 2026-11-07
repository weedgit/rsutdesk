# Team Edition (LAN only)

An internal, not-for-sale build of RustDesk for one team on one local network.

**Primary goal:** manage your own several computers (and VMware guests) remotely from one main
computer on your LAN, without leaving your seat. **Secondary:** control teammates' computers on
the same network (a small team, ~5–10 people).

- **Desktop app only:** Windows, Ubuntu and macOS, with the Flutter UI.
- **Local network only:** it never contacts an ID, relay, API, account or update server.
- **Access by allowed-IP list, no passwords:** any computer whose IP is on a desktop's allowed
  list gets **full control** of it, with no password and no accept/approve prompts. An IP not on
  the list cannot connect. The allowed-IP list is the single rule.
- **Full remote control:** screen, keyboard, mouse, text and file copy/paste, file transfer.
- **No ID shown:** desktops are identified by name and IP. You can give each one an **alias**.

The switch is `LAN_ONLY` in [libs/base/src/team.rs](libs/base/src/team.rs), and `kTeamLanOnly` in
[flutter/lib/consts.dart](flutter/lib/consts.dart) must match it.

## How it works

| | Stock RustDesk | Team edition |
|---|---|---|
| Finding a desktop | ID via the public/self-hosted ID server | It appears by itself in the **Local network** list (LAN discovery); click refresh if not |
| Identifying a desktop | 9-digit ID | Name (`user@hostname`) and IP, plus an optional **alias**; the ID is hidden |
| Connection | Hole punching or relay | Direct TCP to `IP:21118` |
| Who may connect | Password / click to accept | IP on the desktop's **allowed IP list**, nothing else |
| Permission once connected | Prompts / per-feature approval | **Full** automatically (allowed IP = full permission), no prompts |
| Encryption | Key vouched for by the ID server | Key remembered on first connection (like SSH), every session encrypted |
| Accounts, address book, groups | API server | Removed. Use the **Local network** list |
| Updates | Checks rustdesk.com | Disabled |

An empty allowed IP list lets **nobody** connect. This is on purpose: a new install is closed
until someone adds IPs.

The controlled desktop still shows its running tray icon and a connection-manager window while a
session is active, so whoever is at that machine can see it is being controlled.

On an installed desktop the service starts with Windows and the tray icon starts at login, so the
desktop stays reachable after a reboot; closing the main window only hides it. Tray menu:

- **Open** shows the main window.
- **Pause / Resume**: while paused, the desktop refuses every session and ends the open ones;
  the service keeps running. The tray tooltip says "Paused". The setting survives a reboot.
- **Stop and remove service** uninstalls the service (admin prompt); reinstall to bring it back.

## No internet access

The team edition never talks to the internet, in either direction:

- **Outgoing:** connections go only to LAN addresses (10.x, 172.16-31.x, 192.168.x, 169.254.x,
  IPv6 `fc00::/7` and `fe80::/10`, loopback). A name that resolves to anything else is refused,
  and a configured proxy is never used. Every HTTP request (update checks, accounts, address
  book, audit, recording upload, downloads, avatars) is blocked, and no STUN/NAT probes run.
- **Incoming:** a session from a non-LAN address is refused even if the allowed IP list would
  match it (for example `*` with a port forwarded on the router).
- Help links in the UI (for example "Learn more") still open your browser if you click them;
  RustDesk itself sends nothing.

## Network ports (open them on each desktop's firewall, LAN only)

| Port | Protocol | Purpose |
|---|---|---|
| 21118 | TCP | Remote sessions (direct access) |
| 21119 | UDP | LAN discovery (the Local network tab) |

## Setting up a desktop

1. Install the app, and choose **Install** (Windows) so it runs as a service. Only then can
   you control UAC prompts and the login screen.
2. Open **Settings > Security > Allowed IPs**, or click the pencil next to **Allowed IPs**
   on the home screen. Add the controlling machines' IPs, one per line:
   - one machine: `192.168.1.20`
   - a whole subnet: `192.168.1.0/24`
   - everyone (testing only): `*`
3. The home screen shows **this machine's IP**. Teammates add it to their own lists if they
   need to control this one.

### Scripted setup (many desktops)

On an installed desktop, from an elevated shell:

```bash
rustdesk --option whitelist "192.168.1.0/24,10.0.5.12"
```

To read the current list:

```bash
rustdesk --option whitelist
```

On Windows the binary is `"C:\Program Files\RustDesk\rustdesk.exe"`.

## Connecting

There is no "Control Remote Desktop" box to type into. Every desktop that is running and has your
IP on its allowed list **appears on its own** in the **Local network** list. If one is missing,
click **refresh**. Double-click a card to connect — no password, no prompts.

- **Name and IP** identify each card. The ID is not shown.
- **Alias:** right-click a card → **Rename** to give a computer a memorable name (e.g. `Build-PC`,
  `Office-VM`). The alias replaces the name on the card.
- A desktop never lists **itself**.

### Encryption

Every session is end-to-end encrypted, with the same encryption stock RustDesk uses. Without an ID
server to vouch for a desktop's key, the controller remembers each desktop's key the first time
it connects (trust on first use, like SSH) and checks it on every later connection.

- **Security key changed:** shown when a desktop presents a different key than last time. Expected
  after RustDesk was reinstalled or its settings were reset on that desktop: click **Continue** to
  trust the new key. If nothing like that happened, click **Disconnect**: another device may be
  pretending to be that desktop.
- **Insecure connection:** the desktop runs an older build that cannot encrypt. Update it.
- Remembered keys live in `team_known_keys.toml` in the RustDesk config folder (one line per
  desktop, keyed by the name or IP you connected with). Delete a line to forget that key.
- Update **every** desktop: both sides need this build for sessions to be encrypted.

The main window shows only the **Local network** list (Recent and Favorites are removed), the
service **Start/Stop** control, this machine's **IP**, and its **Allowed IPs**.

## Per-OS notes

- **Windows:** install it as a service (step 1) to control elevated windows and the login screen.
- **Windows with a VPN/proxy (Astrill etc.):** works. Some VPNs install an old Winsock "LSP"
  that crashes apps using modern async sockets. Astrill's `ASProxy64.dll` does, and it also
  crashes Cursor and VS Code. RustDesk now creates its sockets on Windows' base provider, so
  no LSP is in their path. See [src/platform/windows_lsp_bypass.rs](src/platform/windows_lsp_bypass.rs).
  The log line `LSP bypass: ...` shows which LSPs were skipped. Side effect: RustDesk's own
  traffic does not go through such a proxy, which is what you want on a LAN.
- **macOS:** grant **Screen Recording** and **Accessibility** in System Settings > Privacy &
  Security. Unsigned builds may lose these grants after each rebuild. Signing with an Apple
  Developer ID avoids that.
- **Ubuntu:** an **X11** session works best. On Wayland, screen capture goes through a portal
  that asks for permission each time, so unattended access is limited. Choose "Ubuntu on Xorg"
  at login, or build with the `drm` feature.
- **File copy/paste:** works on all three. Linux and macOS need the `unix-file-copy-paste`
  feature, which `build.py --flutter --unix-file-copy-paste` turns on.

## Building

Only the Flutter UI is supported. A build without it stops with a clear error.

Prerequisites: Rust, [vcpkg](https://github.com/microsoft/vcpkg) with `VCPKG_ROOT` set (libvpx,
libyuv, opus, aom), the Flutter SDK and `flutter_rust_bridge_codegen`. See the upstream
[build docs](https://rustdesk.com/docs/en/dev/build/).

```bash
python3 build.py --flutter --hwcodec --unix-file-copy-paste
```

Run the policy unit tests (no vcpkg needed):

```bash
cargo test -p base team
```

## Settings and UI changes

- **Service Start/Stop** moved from Settings to the **main window**.
- **Theme:** Light / Dark / **System** on one row; default is **Dark**.
- **Language:** removed — English only.
- **Recording** and **Printer** features removed.
- **No accept/approve/password prompts** on connect; the allowed-IP list is the only gate.
- **Local network** is the only peer tab (Recent, Favorites, Address book and Groups removed).

## What was removed

- Android and iOS projects and build scripts, plus the F-Droid metadata (`fastlane/`).
- The account, address book and device-group panels; the ID/relay/proxy/WebSocket settings;
  password and 2FA settings; the "request approval" menu; the update check; language selection;
  recording; remote printing; the "Control Remote Desktop" ID input; the Recent and Favorites
  tabs; and all per-connection accept/confirm dialogs. The code stays where removing it would
  mean large rewrites, but it is switched off at the entry points. Search for `LAN_ONLY` /
  `kTeamLanOnly` (and `TEAM_HIDDEN_UI` in [src/common.rs](src/common.rs)) to find each switch.

## License

RustDesk is AGPL-3.0. Internal team use is fine. If you ever give the app to anyone outside
the team, you must also offer them this source code.
