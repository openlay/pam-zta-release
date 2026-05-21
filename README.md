# pam-zta — Operator Setup Guide

Zero-trust SSH PAM. Short-lived SSH certs minted only after a multi-step
approval flow signed by hardware-backed keys. The system has four roles:

- **OSH SSH clients** — what end users run to start an approved SSH session
- **AppSigner (iOS)** — what approvers (admins) use to authorize requests via Touch ID
- **CA service** — the only component that holds a signing key; mints SSH certs
- **Target SSH hosts** — where users actually log in; `sshd` trusts the CA's
  public key via `TrustedUserCAKeys`

The gateway holds **no signing key**. Root-of-trust lives in the iOS signer's
Secure Enclave + the CA service's signing key.

This release repo contains:

```
.
├── opam.sh                      Operator console — install / update / set-root
├── gateway/                     Cross-compiled control-gateway binaries + config
│   ├── gateway-linux-amd64
│   ├── gateway-linux-arm64
│   ├── gateway-darwin-arm64
│   ├── gateway-windows-amd64.exe
│   └── gateway.example.toml
├── ca/ZTA-CaSetup.exe           Windows CA service installer (NSIS)
├── osh/ZTA-OSHSetup.exe         Windows OSH client installer
└── README.md                    This file
```

---

## Get the release

The release artifacts live at <https://github.com/openlay/pam-zta-release>.
Fetch `opam.sh` and let it download the gateway binary on demand:

```bash
curl -fsSL https://raw.githubusercontent.com/openlay/pam-zta-release/main/opam.sh \
  -o opam.sh && chmod +x opam.sh
sudo ./opam.sh install --domain gw.example.com --tls autocert
```

The CA + OSH installers (`ca/ZTA-CaSetup.exe`, `osh/ZTA-OSHSetup.exe`) can be
downloaded directly from the GitHub release page if you only need them — see
Steps 7 and 12 below.

---

## Quick install (Linux server)

`opam.sh` automates the gateway install end-to-end: provisions the Postgres
user/db, generates the CA token, writes config, installs a systemd unit, starts
the service, and prints an enrollment QR for AppSigner. If the gateway binary
isn't present locally, `opam.sh` fetches it from GitHub on demand.

```bash
# Run on the gateway server
sudo ./opam.sh install --domain gw.example.com --tls autocert

# Or remote from your laptop (SSH; YubiKey-backed keys work via agent)
./opam.sh install -i ~/.ssh/id_ed25519 -o IdentityAgent=none \
    --domain gw.example.com --tls autocert root@gw.example.com
```

After install, `opam` is symlinked into `/usr/local/bin/`:

```bash
opam status                          # service health
opam set-root ~/Downloads/root.cert  # bootstrap root signer (after Step 8)
opam update                          # swap to a newer binary + restart
opam uninstall                       # remove (with confirmation)
```

The CA service, AppSigner (iOS), and OSH client are installed separately —
see Steps 6, 7, and 12 of the manual guide below.

For full control over each piece (custom paths, hand-written config, etc.) or
non-Linux gateway hosts, follow the 15-step manual guide.

---

## Table of contents

1. [Architecture](#architecture)
2. [What you need before starting](#what-you-need-before-starting)
3. [Pick a gateway binary](#pick-a-gateway-binary)
4. [Step 1 — Provision PostgreSQL](#step-1--provision-postgresql)
5. [Step 2 — Generate the CA token](#step-2--generate-the-ca-token)
6. [Step 3 — Set up APNs credentials](#step-3--set-up-apns-credentials)
7. [Step 4 — Configure the gateway](#step-4--configure-the-gateway)
8. [Step 5 — Run the gateway](#step-5--run-the-gateway)
9. [Step 6 — Install AppSigner (iOS approver)](#step-6--install-appsigner-ios-approver)
10. [Step 7 — Install and configure the CA service](#step-7--install-and-configure-the-ca-service)
11. [Step 8 — Bootstrap the root signer](#step-8--bootstrap-the-root-signer)
12. [Step 9 — Promote a super_admin](#step-9--promote-a-super_admin-recommended)
13. [Step 10 — Register SSH target servers](#step-10--register-ssh-target-servers)
14. [Step 11 — Create a condition-access rule](#step-11--create-a-condition-access-rule)
15. [Step 12 — Install the OSH client](#step-12--install-the-osh-client-end-users)
16. [Step 13 — End user enrolls](#step-13--end-user-enrolls)
17. [Step 14 — Admin approves the device](#step-14--admin-approves-the-device)
18. [Step 15 — Connect](#step-15--connect)
19. [Operations](#operations)
20. [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌──────────────────┐    HTTPS    ┌──────────────────┐    APNs   ┌──────────────┐
│  OSH SSH client  │────────────>│   Gateway        │──────────>│  AppSigner   │
│                  │<────────────│                  │<──────────│  (iOS)       │
└──────────────────┘  poll cert  └──────────────────┘ approval  └──────────────┘
         │                                 │
         │ SSH                       WebSocket │ ca_sign_request
         │  (with minted cert)              ▼
         ▼                          ┌──────────────────┐
┌──────────────────┐                │   CA service     │  (only holder of the
│  Target host     │                │                  │   SSH signing key)
│  (sshd, trusts   │                └──────────────────┘
│   CA pubkey)     │
└──────────────────┘
```

End-to-end flow when a user runs `osh user@host`:

1. OSH signs an ephemeral pubkey with its hardware device key (Secure Enclave / TPM / Ed25519 file).
2. Gateway matches the request against a **condition rule** and pushes an APNs approval to AppSigner.
3. Approver Touch-ID-signs the response inside Secure Enclave.
4. Gateway forwards the signed approval chain to the CA over WebSocket.
5. CA verifies the chain and returns a short-lived SSH cert.
6. OSH spawns `ssh -tt` with the ephemeral key + cert. All session I/O is recorded
   to `~/.osh/sessions/<request-id>.cast` (asciinema v2).

---

## What you need before starting

- A server with a stable hostname and TLS termination
  (Linux, macOS, or Windows; ports 443 or 80+443 for autocert)
- **PostgreSQL 14+** reachable from the gateway host
- **TLS certificate** (or a public domain to use built-in Let's Encrypt autocert)
- **Apple Developer account** for APNs (.p8 auth key + team_id + key_id + bundle topic)
- **AppSigner** iOS app installed on at least one approver device
  (TestFlight or sideloaded — see Step 6)
- **CA service** installer for the host the CA will run on
  (`ca/ZTA-CaSetup.exe` for Windows; build from source for macOS/Linux)
- **OSH client** for each end user
  (`osh/ZTA-OSHSetup.exe` for Windows; build from source for macOS/Linux)

---

## Pick a gateway binary

| Platform        | File                                    | Architecture          |
|-----------------|-----------------------------------------|-----------------------|
| Linux x86_64    | `gateway/gateway-linux-amd64`           | ELF, statically linked |
| Linux arm64     | `gateway/gateway-linux-arm64`           | ELF, statically linked |
| macOS arm64     | `gateway/gateway-darwin-arm64`          | Mach-O, Apple Silicon |
| Windows x86_64  | `gateway/gateway-windows-amd64.exe`     | PE32+                 |

All binaries are built from the same source with `CGO_ENABLED=0` and stripped
(`-ldflags="-s -w"`). They have no runtime dependencies beyond the operating system.

```bash
# Verify integrity (Linux example)
file gateway/gateway-linux-amd64
# → ELF 64-bit LSB executable, x86-64, statically linked, stripped
```

---

## Step 1 — Provision PostgreSQL

The gateway auto-creates its schema on first start. You only need to give it
a database and credentials.

```sql
-- as postgres superuser:
CREATE USER pamzta WITH PASSWORD 'change-me-strong-password';
CREATE DATABASE pamzta OWNER pamzta;
```

For production, prefer:

- `sslmode=require` or `sslmode=verify-full` in the gateway config
- A managed Postgres instance (RDS, Cloud SQL, Aiven, …)
- Storing the password in a secrets manager and injecting it at process start

Six tables will be created automatically: ledger entries, enrolled devices,
signers, servers, condition rules, and approval requests.

---

## Step 2 — Generate the CA token

The CA service authenticates to the gateway with a shared bearer token.

```bash
openssl rand -hex 32 > ca.token
cat ca.token
# → 64-char hex string, e.g. a3f4...
```

You will paste this **same value** into:

- `gateway.toml` → `[ca] token`
- `ca_service.toml` → `ca_token`

The token is a transport-layer secret only — actual security of issued certs
comes from the per-request approval-chain signatures verified by the CA
against root certs imported during bootstrap.

---

## Step 3 — Set up APNs credentials

APNs is required to push approval requests to AppSigner.

1. Apple Developer Console → **Keys** → **+** → "Apple Push Notifications service (APNs)"
2. Download the resulting `.p8` file (one-time download — keep it safe)
3. Note: **Key ID** (e.g. `P12345ABCD`), **Team ID** (e.g. `ABC123XY`)
4. The **topic** is the iOS bundle ID of your AppSigner build
   (e.g. `com.example.appsigner`)

Save the `.p8` somewhere the gateway can read (mode 0600):

```bash
sudo mkdir -p /etc/pam-zta
sudo install -m 0600 AuthKey_P12345ABCD.p8 /etc/pam-zta/apns.p8
```

Use **`use_sandbox = true`** for TestFlight / development builds of AppSigner,
**`false`** for App Store production builds.

---

## Step 4 — Configure the gateway

Copy `gateway/gateway.example.toml` to `/etc/pam-zta/gateway.toml` (or wherever
you like) and fill in the values from Steps 1-3.

Minimum required fields:

```toml
[server]
listen_addr = ":443"            # OR set autocert_domain instead
tls_cert    = "/etc/pam-zta/server.crt"
tls_key     = "/etc/pam-zta/server.key"

[ca]
token = "PASTE_FROM_STEP_2"

[database]
host     = "127.0.0.1"
user     = "pamzta"
password = "change-me-strong-password"
dbname   = "pamzta"
sslmode  = "require"

[apns]
team_id  = "ABC123XY"
key_id   = "P12345ABCD"
key_path = "/etc/pam-zta/apns.p8"
topic    = "com.example.appsigner"
```

For **Let's Encrypt autocert** instead of a manual cert, replace `[server]` with:

```toml
[server]
autocert_domain    = "gateway.example.com"
autocert_cache_dir = "/var/lib/pam-zta/autocert-cache"
autocert_email     = "ops@example.com"
```

Autocert binds `:80` (HTTP-01 challenge) and `:443` (HTTPS/WSS) — `listen_addr`
is ignored. Make sure DNS points at your server before starting.

See `gateway/gateway.example.toml` for the full annotated schema (includes
optional `[siem]`, `[review]`, `[freeze]`, mTLS, and connection-pool tuning).

Lock down the file:

```bash
sudo chmod 0600 /etc/pam-zta/gateway.toml
sudo chown root:root /etc/pam-zta/gateway.toml
```

---

## Step 5 — Run the gateway

```bash
# Make the binary executable
chmod +x gateway/gateway-linux-amd64
sudo install gateway/gateway-linux-amd64 /opt/pam-zta/bin/gateway

# Run in the foreground for the first start (Ctrl-C to stop)
sudo /opt/pam-zta/bin/gateway -config /etc/pam-zta/gateway.toml
```

Expected log lines on a healthy first start:

```
Loaded config from /etc/pam-zta/gateway.toml
Postgres schema verified
Listening on :443 (TLS)
WebSocket /v1/ca/ws ready (waiting for CA hello)
APNs client initialized (topic com.example.appsigner)
```

Health check from another machine:

```bash
curl -sf https://gateway.example.com/v1/health
# → {"status":"ok"}
```

### systemd unit (Linux)

```ini
# /etc/systemd/system/pam-zta-gateway.service
[Unit]
Description=pam-zta Control Gateway
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=pamzta
Group=pamzta
ExecStart=/opt/pam-zta/bin/gateway -config /etc/pam-zta/gateway.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/pam-zta

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd -r -s /usr/sbin/nologin pamzta
sudo mkdir -p /var/lib/pam-zta && sudo chown pamzta:pamzta /var/lib/pam-zta
sudo systemctl daemon-reload
sudo systemctl enable --now pam-zta-gateway
sudo journalctl -u pam-zta-gateway -f
```

---

## Step 6 — Install AppSigner (iOS approver)

AppSigner is the approval app for admins. It signs approval responses inside
Secure Enclave (P-256, Touch ID required per signature).

Distribution options:

- **TestFlight** — join the public beta: <https://testflight.apple.com/join/efAqUZAk>
- **Ad-hoc / Enterprise** — sideload via Xcode (signer/AppSigner/AppSigner.xcodeproj)

On first launch:

1. Enter the gateway URL (e.g. `https://gateway.example.com` — no path)
2. Tap **Generate Key & Register**
   - Touch ID generates a P-256 key in Secure Enclave
   - App calls `POST /v1/signers/register` with the public key + device metadata
3. The app shows a **4-digit verification code**. Write this down — you will need it
   in Step 8.
4. Status: **Waiting for approval**

Until the first signer is bootstrapped to root (Step 8), the app stays in this
state. That is expected.

---

## Step 7 — Install and configure the CA service

The CA service is the only component holding a signing key. It connects out
to the gateway over WebSocket — the gateway never reaches the CA directly.

### Install

| Platform | Command |
|----------|---------|
| Windows  | Run `ca/ZTA-CaSetup.exe` (NSIS installer, per-user, no UAC) |
| macOS    | From source: `cd ca-service/mac && bash install.sh` |
| Linux    | From source: `cd ca-service/linux && PY=python3.12 bash install.sh` |

### Configure

Edit `ca_service.toml` (location varies — Windows: `%APPDATA%\pam-zta\`,
macOS/Linux: `~/.config/pam-zta/`):

```toml
gateway_ws_url = "wss://gateway.example.com/v1/ca/ws"
ca_id          = "ca-primary"
ca_token       = "PASTE_SAME_TOKEN_FROM_STEP_2"
tls_insecure   = false        # only true for self-signed dev TLS

key_source     = "file"       # or "yubikey"
key_path       = "ca_key.pem" # auto-generated on first run

root_certs_dir = "root_certs"
revoked_path   = "revoked.json"
cert_ttl       = 300
ledger_db_path = "ca_ledger.db"
```

For **YubiKey-backed** signing, set `key_source = "yubikey"` and configure the
PIV slot. PIN can come from the OS keychain, the `CA_YUBIKEY_PIN` env var,
or a one-time GUI prompt.

### Start

| Platform | Command |
|----------|---------|
| Windows  | Auto-started by Settings → Service Auto-Start, or run CAService.exe |
| macOS    | LaunchAgent at `~/Library/LaunchAgents/com.pamzta.ca-service.plist` |
| Linux    | `sudo systemctl enable --now pam-zta-ca` |

On startup:

- If `ca_key.pem` doesn't exist, the CA generates a new Ed25519 key
- The CA dials `gateway_ws_url` with `X-CA-Token` header
- The CA sends a `ca_hello` message with its identity and any root certs
  it has imported (none yet — that comes next)

**Verify** in the gateway logs:

```
CA hello received from ca-primary (fingerprint=...)
```

If you see auth errors, check that `ca_token` matches exactly between
gateway and CA configs.

---

## Step 8 — Bootstrap the root signer

This step turns your first AppSigner device into the **root** of the entire
trust chain. It's a one-time, automatic promotion that fires the first time
a CA presents a root cert whose public key matches a pending signer.

1. **AppSigner → Settings → Generate Root Cert** (Touch ID required)
   - The app exports a `.cert` file containing its Secure Enclave public key
2. **Import into CA service**:
   - Windows GUI: CA Service → **Root Certs** tab → **Import**
   - or: copy the `.cert` file into the `root_certs/` directory under
     `paths.runtime_dir()` (Windows: `%APPDATA%\pam-zta\root_certs\`)
3. The CA reconnects to the gateway and sends a fresh `ca_hello` containing
   the new root cert.
4. The gateway's bootstrap handler:
   - Checks if a `root` signer already exists. If yes, the cert is ignored
     (only one root per system).
   - Otherwise, looks for a pending signer whose public key matches the cert.
   - Auto-promotes that signer: `Role = "root"`, `Approved = true`.
5. **AppSigner status flips to "Approved (root)"**.

**Critical detail**: the public key embedded in the root cert must exactly match
the public key of one pending signer. Both come from the same iOS device, so
this is automatic if you do Steps 6 and 8 on the same physical phone.

---

## Step 9 — Promote a super_admin (recommended)

Best practice: keep the root device offline (in a safe, only used for break-glass).
Promote a `super_admin` signer for daily approvals.

From the **root** AppSigner:

1. **Admin** tab → **Promote signer**
2. Select a pending signer (must already have completed Step 6)
3. Choose role: **super_admin**
4. Touch ID to sign the role-grant cert
5. The promoted signer can now approve other signers, register servers, and create rules

You typically want **two** super_admins for redundancy. The role hierarchy:

```
root → super_admin → admin → user_device
```

`root` can issue any role. `super_admin` issues `admin` + `user_device`.
`admin` issues `user_device` only (and is scoped to assigned server groups).

---

## Step 10 — Register SSH target servers

Tell the gateway about the SSH hosts your users will connect to.

Via AppSigner (super_admin or admin):

1. **Servers** tab → **Add server**
2. Fill in: hostname, IP, port (default 22), group, optional tags
3. Save

Or via API (any approved admin):

```bash
curl -X POST https://gateway.example.com/v1/servers \
  -H "Content-Type: application/json" \
  -H "X-Device-Key-ID: <your-signer-id>" \
  -H "X-Device-Signature: <signature>" \
  -d '{
    "hostname": "app-prod-01.example.com",
    "ip":       "10.0.1.5",
    "port":     22,
    "group_id": "prod-servers"
  }'
```

Target SSH servers do **not** need any special configuration — the OSH client
hands the issued cert directly to standard `sshd`. Make sure `sshd` trusts
the CA's SSH public key in `TrustedUserCAKeys`:

```bash
# On each target host, /etc/ssh/sshd_config:
TrustedUserCAKeys /etc/ssh/pam-zta-ca.pub
# Then restart sshd
```

You can fetch the CA's public key from the CA service GUI (Status tab) or from
`~/.config/pam-zta/ca_key.pem` (extract pubkey with `ssh-keygen -y -f ca_key.pem`).

---

## Step 11 — Create a condition-access rule

A rule is required for any `(device, server, principal)` tuple. Without a
matching rule, requests are denied.

Via AppSigner: **Rules** tab → **New rule**.

Or via API:

```bash
curl -X POST https://gateway.example.com/v1/rules \
  -H "Content-Type: application/json" \
  -H "X-Device-Key-ID: <signer-id>" \
  -H "X-Device-Signature: <signature>" \
  -d '{
    "id":          "rule-prod-ssh",
    "server_id":   "<server-uuid-from-step-10>",
    "device_id":   "*",
    "principal":   "*",
    "action":      "allow",
    "approval_chain": [
      { "tier": "super_admin", "min_approvals": 1, "timeout_seconds": 300 }
    ]
  }'
```

This rule says: any approved device, any principal, may connect to that server
provided one super_admin approves within 5 minutes.

For tighter rules, narrow `device_id` to a specific device, `principal` to a
specific username, and add multiple approval tiers.

---

## Step 12 — Install the OSH client (end users)

Each end user needs OSH on the machine they'll SSH from.

| Platform | Source |
|----------|--------|
| Windows  | `osh/ZTA-OSHSetup.exe` |
| macOS    | Build from `osh/mac/` Xcode project, or `pip install -e osh/shared[mac]` from source |
| Linux    | `go build -o ~/bin/osh ./osh/shared/cmd` from source (no installer yet) |

The Windows installer puts `osh.exe` (CLI) and `OSH.exe` (Tk GUI) on PATH at
`%LOCALAPPDATA%\PamZta\bin`.

---

## Step 13 — End user enrolls

```bash
osh enroll --gateway https://gateway.example.com
```

What happens:

- OSH creates or loads the device hardware key
  - macOS: Secure Enclave P-256 (Touch ID required for each signature)
  - Windows: TPM 2.0 P-256 via NCrypt (key name `PamZta-OSH-DeviceKey`)
  - Linux: Ed25519 file at `~/.osh/device_key`
- Calls `POST /v1/devices/enroll` with public key + hostname + OS metadata
- Prints a **4-digit verification code** and the device_id
- Status: "Waiting for admin approval"

GUI users: launch `OSH.exe`, enter the gateway URL, click **Enroll & Connect**.

---

## Step 14 — Admin approves the device

In AppSigner (super_admin or admin):

1. **Pending Devices** tab → tap the device → enter the 4-digit code from Step 13
2. Touch ID to sign the approval

OSH polls `GET /v1/devices/{id}` every few seconds and unblocks once approved.

---

## Step 15 — Connect

```bash
osh user@app-prod-01.example.com
```

Flow:

1. OSH signs an ephemeral Ed25519 pubkey with the device key
2. Gateway matches the rule from Step 11 and pushes APNs to AppSigner approver(s)
3. Approver gets a notification, opens the app, reviews the request, Touch-IDs to approve
4. Gateway forwards the signed approval chain to the CA
5. CA verifies the chain and returns a short-lived SSH cert
6. OSH spawns `ssh -tt user@app-prod-01.example.com` with the ephemeral key + cert
7. Local TTY enters raw mode; all I/O is recorded to
   `~/.osh/sessions/<request-id>.cast` (asciinema v2 format)

Replay later with:

```bash
asciinema play ~/.osh/sessions/<request-id>.cast
# or
pamctl replay ~/.osh/sessions/<request-id>.cast
```

---

## Operations

| Task | Command |
|------|---------|
| Health check | `curl -sf https://gateway.example.com/v1/health` |
| Tail logs (systemd) | `sudo journalctl -u pam-zta-gateway -f` |
| Soft / hard freeze | AppSigner → Admin → Freeze (incident response — blocks new requests) |
| Unfreeze | AppSigner → Admin → Unfreeze |
| Audit ledger inspect | `pamctl ledger inspect /var/lib/pam-zta/gateway_ledger.db` |
| Audit ledger validate | `pamctl ledger validate /var/lib/pam-zta/gateway_ledger.db` |
| Replay a session | `pamctl replay ~/.osh/sessions/<request-id>.cast` |
| Rotate APNs key | Generate new `.p8` in Apple Developer, swap `key_id` + `key_path`, restart |
| Rotate CA token | Generate new token, update both gateway + CA config, restart both |

---

## Troubleshooting

**`CA hello timeout` or no `CA hello` log line**
- `ca_token` mismatch between `gateway.toml` and `ca_service.toml`
- `gateway_ws_url` wrong (check scheme — `wss://` for TLS) or DNS not resolving
- `tls_insecure = true` on CA but gateway has a valid cert (works, but not recommended)
  or vice versa

**`No pending root signer for cert` (during bootstrap)**
- The root cert imported into the CA was generated by a different iOS device
  than the pending signer. Re-export the root cert from the same AppSigner
  device that registered in Step 6.

**`APNs delivery failed`**
- `team_id`, `key_id`, or `topic` doesn't match Apple Developer console
- `.p8` file path wrong or unreadable by the gateway process
- `use_sandbox` flag wrong: `true` for TestFlight builds, `false` for App Store

**`rule mismatch` when calling `osh user@host`**
- No condition rule matches `(device_id, server_id, principal)`. Check the rule
  in AppSigner; widen `device_id` or `principal` to `*` if testing.

**Postgres errors on startup**
- `connection refused`: Postgres not running or wrong host/port
- `password authentication failed`: check the password in `[database]`
- `database does not exist`: did you run `CREATE DATABASE pamzta` (Step 1)?
- `permission denied for schema public`: grant the `pamzta` user CREATE on the
  database, or make it the owner

**`osh enroll` hangs**
- macOS: Touch ID prompt may have appeared on a different desktop / behind the
  terminal. Click the dock icon for the terminal app or press Esc to try again.
- Windows: TPM provider may be disabled. Check `Get-Tpm` in PowerShell.
- Linux: ensure `~/.osh/` is writable.

**Gateway logs `Postgres schema verified` but I see no tables**
- The schema is in the `public` schema by default. Check `\dt public.*` in psql.
- All 6 tables: `ledger`, `enrolled_devices`, `signers`, `servers`, `condition_rules`,
  `approvals`.

---

For source code, build instructions, and contribution guidelines, see the
upstream repository.
