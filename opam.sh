#!/usr/bin/env bash
# opam — pam-zta operator console
#
# Single-script installer/updater for the control gateway. Runs locally on
# the target Linux server, or remotely from your laptop via SSH.
#
# Source: https://github.com/openlay/pam-zta-release
# Script-only fast path:
#   curl -fsSL https://raw.githubusercontent.com/openlay/pam-zta-release/main/opam.sh \
#     -o opam.sh && chmod +x opam.sh
#   sudo ./opam.sh install --domain gw.example.com --tls autocert
# (binaries are auto-fetched on demand if not already present locally)
#
# Usage:
#   ./opam.sh install [OPTIONS] [user@host]
#   ./opam.sh update  [OPTIONS] [user@host]
#   ./opam.sh set-root <cert-file>
#   ./opam.sh status
#   ./opam.sh uninstall
#
# Run with no arguments or --help for full options.

set -euo pipefail

# ---------- constants ----------
SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
RELEASE_DIR=$(dirname "$SCRIPT_PATH")
GATEWAY_DIR=$RELEASE_DIR/gateway

# GitHub fetch fallback. Override with OPAM_RELEASE_REF=tag-or-branch.
RELEASE_REPO=${OPAM_RELEASE_REPO:-openlay/pam-zta-release}
RELEASE_REF=${OPAM_RELEASE_REF:-main}
RELEASE_BASE_URL="https://raw.githubusercontent.com/$RELEASE_REPO/$RELEASE_REF"

INSTALL_PREFIX=/opt/pam-zta
BIN_DIR=$INSTALL_PREFIX/bin
DATA_DIR=/var/lib/pam-zta
CONFIG_DIR=/etc/pam-zta
LOG_DIR=/var/log/pam-zta
SYMLINK=/usr/local/bin/opam
SYSTEMD_UNIT=/etc/systemd/system/pam-zta-gateway.service
SERVICE_USER=pamzta
GATEWAY_PORT=${GATEWAY_PORT:-443}

# ---------- colors / logging ----------
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[36m'; BOLD=$'\e[1m'; NC=$'\e[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
log()  { printf '%s==>%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s !!%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s !!%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

confirm() {
  local prompt=$1 ans
  read -r -p "$prompt [y/N]: " ans
  [[ ${ans,,} == y || ${ans,,} == yes ]]
}

prompt_default() {
  local prompt=$1 default=${2:-} ans
  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " ans
    echo "${ans:-$default}"
  else
    read -r -p "$prompt: " ans
    echo "$ans"
  fi
}

# ---------- usage ----------
usage() {
  cat <<EOF
${BOLD}opam${NC} — pam-zta operator console

${BOLD}USAGE${NC}
  opam install [OPTIONS] [user@host]    Install / re-install the gateway
  opam update  [OPTIONS] [user@host]    Update binary + restart service
  opam set-root <cert-file>             Import root cert into local CA
  opam status                            Show gateway service status
  opam uninstall                         Remove gateway (asks confirmation)

${BOLD}REMOTE MODE${NC} (when user@host is given)
  -i KEY        SSH identity file
  -o OPTION     Extra ssh -o option (repeatable)
                e.g. -o IdentityAgent=none -o ProxyJump=bastion
  YubiKey-backed SSH keys work via ssh-agent (no special flag needed).

${BOLD}INSTALL OPTIONS${NC}
  --domain D                 Public hostname for the gateway (required)
  --tls autocert|manual|self-signed
                             TLS strategy (default: prompts)
  --tls-cert F --tls-key F   Cert paths (manual mode)
  --apns-team T --apns-key-id K --apns-key-path P --apns-topic T
                             APNs credentials (or set via env vars)
  --skip-apns                Install without APNs (no iOS push — test only)
  --pg-host H --pg-port P --pg-user U --pg-password W --pg-db D
                             Postgres connection (default: 127.0.0.1, pamzta/pamzta)
  --skip-pg-setup            Don't try CREATE USER/DATABASE (already done)
  --no-qr                    Skip enrollment QR at end
  --yes                      Don't prompt — fail on missing required values

${BOLD}EXAMPLES${NC}
  # Local install on this server
  sudo ./opam.sh install --domain gw.example.com --tls autocert

  # Remote install via SSH
  ./opam.sh install -i ~/.ssh/id_ed25519 -o IdentityAgent=none \\
      --domain gw.example.com --tls autocert root@gw.example.com

  # Update existing install
  sudo ./opam.sh update                  # local
  ./opam.sh update root@gw.example.com   # remote

  # Bootstrap root signer (after AppSigner exports root cert)
  sudo ./opam.sh set-root ~/Downloads/root.cert

${BOLD}OUT OF SCOPE${NC}
  - CA service install (separate Python install — see ../ca/ on Windows
    or 'cd ca-service/{mac,linux} && bash install.sh' from source)
  - OSH client install (separate end-user install — see ../osh/)
  - AppSigner install (TestFlight / Xcode sideload only)
EOF
}

# ---------- platform detection ----------
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) err "Unsupported architecture: $(uname -m)" ;;
  esac
}

detect_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) err "Unsupported OS: $(uname -s) — opam install supports Linux only" ;;
  esac
}

binary_for_host() {
  local os=$1 arch=$2
  echo "gateway-${os}-${arch}"
}

require_root() {
  [[ $EUID -eq 0 ]] || err "This command must run as root (use sudo)."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

# Download a release file (gateway/<name> or gateway/gateway.example.toml)
# into RELEASE_DIR if not already present. Echoes the resolved local path.
fetch_release_file() {
  local relpath=$1                     # e.g. "gateway/gateway-linux-amd64"
  local local_path="$RELEASE_DIR/$relpath"
  if [[ -f $local_path ]]; then
    echo "$local_path"
    return
  fi
  install -d "$(dirname "$local_path")"
  local url="$RELEASE_BASE_URL/$relpath"
  log "Fetching $relpath from $RELEASE_REPO@$RELEASE_REF…" >&2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar "$url" -o "$local_path" >&2 \
      || err "Download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress "$url" -O "$local_path" >&2 \
      || err "Download failed: $url"
  else
    err "Need curl or wget to download. Or clone https://github.com/$RELEASE_REPO manually."
  fi
  [[ $relpath == gateway/gateway-* ]] && chmod +x "$local_path"
  echo "$local_path"
}

ensure_binary() {
  local os=$1 arch=$2
  fetch_release_file "gateway/$(binary_for_host "$os" "$arch")"
}

# ---------- QR ----------
ensure_qrencode() {
  if command -v qrencode >/dev/null 2>&1; then return; fi
  log "Installing qrencode (for enrollment QR)…"
  if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq qrencode
  elif command -v dnf     >/dev/null; then dnf install -y -q qrencode
  elif command -v yum     >/dev/null; then yum install -y -q qrencode
  elif command -v apk     >/dev/null; then apk add --no-cache qrencode
  elif command -v pacman  >/dev/null; then pacman -S --noconfirm qrencode
  else warn "No package manager found — install qrencode manually for QR display"
  fi
}

print_qr() {
  local url=$1
  echo
  printf '%sScan with the AppSigner camera to set the gateway URL:%s\n\n' "$BOLD" "$NC"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$url"
  else
    echo "  (qrencode not installed — copy URL manually)"
  fi
  echo
  printf '  %sURL:%s %s\n' "$BOLD" "$NC" "$url"
  echo
}

# ---------- argument parsing ----------
DOMAIN=
TLS_MODE=
TLS_CERT=
TLS_KEY=
APNS_TEAM=${APNS_TEAM:-}
APNS_KEY_ID=${APNS_KEY_ID:-}
APNS_KEY_PATH=${APNS_KEY_PATH:-}
APNS_TOPIC=${APNS_TOPIC:-}
SKIP_APNS=0
PG_HOST=127.0.0.1
PG_PORT=5432
PG_USER=pamzta
PG_PASSWORD=
PG_DB=pamzta
SKIP_PG_SETUP=0
SHOW_QR=1
ASSUME_YES=0
SSH_IDENTITY=
SSH_OPTS=()
REMOTE_TARGET=

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain)         DOMAIN=$2; shift 2 ;;
      --tls)            TLS_MODE=$2; shift 2 ;;
      --tls-cert)       TLS_CERT=$2; shift 2 ;;
      --tls-key)        TLS_KEY=$2; shift 2 ;;
      --apns-team)      APNS_TEAM=$2; shift 2 ;;
      --apns-key-id)    APNS_KEY_ID=$2; shift 2 ;;
      --apns-key-path)  APNS_KEY_PATH=$2; shift 2 ;;
      --apns-topic)     APNS_TOPIC=$2; shift 2 ;;
      --skip-apns)      SKIP_APNS=1; shift ;;
      --pg-host)        PG_HOST=$2; shift 2 ;;
      --pg-port)        PG_PORT=$2; shift 2 ;;
      --pg-user)        PG_USER=$2; shift 2 ;;
      --pg-password)    PG_PASSWORD=$2; shift 2 ;;
      --pg-db)          PG_DB=$2; shift 2 ;;
      --skip-pg-setup)  SKIP_PG_SETUP=1; shift ;;
      --no-qr)          SHOW_QR=0; shift ;;
      --yes|-y)         ASSUME_YES=1; shift ;;
      -i)               SSH_IDENTITY=$2; shift 2 ;;
      -o)               SSH_OPTS+=("$2"); shift 2 ;;
      *@*)              REMOTE_TARGET=$1; shift ;;
      -h|--help)        usage; exit 0 ;;
      *)                err "Unknown option: $1" ;;
    esac
  done
}

# ---------- remote dispatcher ----------
ssh_args() {
  local args=()
  [[ -n $SSH_IDENTITY ]] && args+=(-i "$SSH_IDENTITY")
  for opt in "${SSH_OPTS[@]}"; do args+=(-o "$opt"); done
  printf '%s\n' "${args[@]}"
}

run_remote() {
  local subcommand=$1
  shift
  [[ -n $REMOTE_TARGET ]] || err "run_remote called without REMOTE_TARGET"
  require_cmd ssh
  require_cmd scp

  log "Detecting remote platform…"
  mapfile -t SSHA < <(ssh_args)
  local remote_uname
  remote_uname=$(ssh "${SSHA[@]}" "$REMOTE_TARGET" "uname -sm")
  local remote_os remote_arch
  case "$remote_uname" in
    Linux*x86_64|Linux*amd64)  remote_os=linux; remote_arch=amd64 ;;
    Linux*aarch64|Linux*arm64) remote_os=linux; remote_arch=arm64 ;;
    *) err "Remote platform '$remote_uname' not supported (Linux amd64/arm64 only)" ;;
  esac
  ok "Remote: $remote_os/$remote_arch"

  local remote_bin example_toml
  remote_bin=$(ensure_binary "$remote_os" "$remote_arch")
  example_toml=$(fetch_release_file "gateway/gateway.example.toml")

  local stage=/tmp/opam-$$
  log "Staging script + binary to $REMOTE_TARGET:$stage"
  ssh "${SSHA[@]}" "$REMOTE_TARGET" "mkdir -p $stage/gateway"
  scp "${SSHA[@]}" -q "$SCRIPT_PATH" "$REMOTE_TARGET:$stage/opam.sh"
  scp "${SSHA[@]}" -q "$remote_bin" "$REMOTE_TARGET:$stage/gateway/$(basename "$remote_bin")"
  scp "${SSHA[@]}" -q "$example_toml" "$REMOTE_TARGET:$stage/gateway/gateway.example.toml"

  log "Running 'opam $subcommand' on remote (sudo)…"
  ssh -t "${SSHA[@]}" "$REMOTE_TARGET" \
    "chmod +x $stage/opam.sh && sudo $stage/opam.sh $subcommand $* && rm -rf $stage"
}

# ---------- install: prompts ----------
prompt_missing() {
  if [[ -z $DOMAIN ]]; then
    [[ $ASSUME_YES -eq 1 ]] && err "--domain is required"
    DOMAIN=$(prompt_default "Public gateway hostname" "")
    [[ -n $DOMAIN ]] || err "--domain is required"
  fi

  if [[ -z $TLS_MODE ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then TLS_MODE=autocert
    else
      echo "TLS strategy:"
      echo "  1) autocert    Let's Encrypt (requires public DNS pointing here)"
      echo "  2) manual      I have a cert + key file"
      echo "  3) self-signed Generate a self-signed cert (DEV ONLY)"
      local choice; choice=$(prompt_default "Choose 1/2/3" "1")
      case $choice in 1) TLS_MODE=autocert ;; 2) TLS_MODE=manual ;; 3) TLS_MODE=self-signed ;; *) err "Invalid choice" ;; esac
    fi
  fi

  if [[ $TLS_MODE == manual ]]; then
    [[ -z $TLS_CERT ]] && TLS_CERT=$(prompt_default "Path to TLS cert PEM" "")
    [[ -z $TLS_KEY  ]] && TLS_KEY=$(prompt_default  "Path to TLS key PEM" "")
    [[ -f $TLS_CERT && -f $TLS_KEY ]] || err "Cert/key files not found"
  fi

  if [[ -z $PG_PASSWORD && $SKIP_PG_SETUP -eq 0 ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      PG_PASSWORD=$(openssl rand -hex 16)
      log "Generated Postgres password (saved to /etc/pam-zta/.pgpass)"
    else
      PG_PASSWORD=$(prompt_default "Postgres password for user '$PG_USER' (leave empty to auto-generate)" "")
      [[ -z $PG_PASSWORD ]] && PG_PASSWORD=$(openssl rand -hex 16)
    fi
  fi

  if [[ $SKIP_APNS -eq 0 ]]; then
    [[ -z $APNS_TEAM    ]] && APNS_TEAM=$(prompt_default    "APNs team_id (or empty to skip)" "")
    if [[ -z $APNS_TEAM ]]; then SKIP_APNS=1; warn "APNs disabled — approvals via push won't work"
    else
      [[ -z $APNS_KEY_ID   ]] && APNS_KEY_ID=$(prompt_default   "APNs key_id" "")
      [[ -z $APNS_KEY_PATH ]] && APNS_KEY_PATH=$(prompt_default "Path to APNs .p8 file" "")
      [[ -z $APNS_TOPIC    ]] && APNS_TOPIC=$(prompt_default    "APNs topic (iOS bundle id)" "com.example.appsigner")
      [[ -f $APNS_KEY_PATH ]] || err "APNs .p8 file not found: $APNS_KEY_PATH"
    fi
  fi
}

# ---------- install: steps ----------
ensure_user() {
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "Creating system user $SERVICE_USER…"
    useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" "$SERVICE_USER"
  fi
}

ensure_dirs() {
  install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR" "$LOG_DIR"
  install -d -m 0755 "$BIN_DIR"
  install -d -m 0700 -o root -g root "$CONFIG_DIR"
}

ensure_prereqs() {
  # openssl is the only critical command without a code-level fallback (token
  # + password + self-signed cert generation). Everything else is either
  # auto-installed (postgres family) or guaranteed present on a systemd box.
  command -v openssl >/dev/null 2>&1 && return
  local distro
  distro=$(detect_distro)
  log "Installing openssl ($distro)…"
  case $distro in
    debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null ;;
    rhel)   (command -v dnf >/dev/null && dnf install -y -q openssl >/dev/null) || yum install -y -q openssl >/dev/null ;;
    arch)   pacman -Sy --noconfirm openssl >/dev/null ;;
    suse)   zypper -n install -y openssl >/dev/null ;;
    *)      err "openssl not found and unknown distro — install it manually" ;;
  esac
}

detect_distro() {
  # Echoes one of: debian, rhel, arch, suse, unknown.
  if [[ ! -r /etc/os-release ]]; then echo unknown; return; fi
  # shellcheck disable=SC1091
  . /etc/os-release
  local probe=" ${ID:-} ${ID_LIKE:-} "
  case "$probe" in
    *' debian '*|*' ubuntu '*) echo debian ;;
    *' rhel '*|*' fedora '*|*' centos '*|*' rocky '*|*' almalinux '*) echo rhel ;;
    *' arch '*) echo arch ;;
    *' suse '*|*' opensuse '*) echo suse ;;
    *) echo unknown ;;
  esac
}

install_postgres() {
  local distro
  distro=$(detect_distro)
  log "Installing PostgreSQL ($distro)…"
  case $distro in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq postgresql postgresql-contrib >/dev/null
      ;;
    rhel)
      if command -v dnf >/dev/null; then
        dnf install -y -q postgresql-server postgresql-contrib >/dev/null
      else
        yum install -y -q postgresql-server postgresql-contrib >/dev/null
      fi
      # RHEL needs an explicit initdb before first start.
      if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
        if command -v postgresql-setup >/dev/null; then
          postgresql-setup --initdb >/dev/null
        else
          # Older path
          /usr/bin/postgresql-setup initdb >/dev/null 2>&1 || \
            sudo -u postgres /usr/bin/initdb -D /var/lib/pgsql/data
        fi
      fi
      ;;
    arch)
      pacman -Sy --noconfirm postgresql >/dev/null
      if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
        sudo -u postgres initdb -D /var/lib/postgres/data
      fi
      ;;
    suse)
      zypper -n install -y postgresql-server postgresql-contrib >/dev/null
      ;;
    *)
      err "Unknown distro — install PostgreSQL manually (e.g. 'apt-get install postgresql'), then re-run."
      ;;
  esac
  systemctl enable --now postgresql
}

ensure_postgres_running() {
  if command -v systemctl >/dev/null && systemctl is-active --quiet postgresql; then
    return
  fi
  if pg_isready -h "$PG_HOST" -p "$PG_PORT" >/dev/null 2>&1; then
    return
  fi
  # Not running. If we're local (127.0.0.1 / localhost) we can install it.
  if [[ $PG_HOST == "127.0.0.1" || $PG_HOST == "localhost" ]]; then
    install_postgres
    # Wait up to 30s for it to come up.
    local i
    for i in {1..30}; do
      if pg_isready -h "$PG_HOST" -p "$PG_PORT" >/dev/null 2>&1; then
        ok "PostgreSQL started"
        return
      fi
      sleep 1
    done
    err "PostgreSQL installed but didn't become ready in 30s — check 'systemctl status postgresql'"
  fi
  err "PostgreSQL is not reachable at $PG_HOST:$PG_PORT — install + start it on that host first."
}

setup_postgres() {
  [[ $SKIP_PG_SETUP -eq 1 ]] && { log "Skipping Postgres user/db setup"; return; }
  ensure_postgres_running
  log "Provisioning Postgres user '$PG_USER' and database '$PG_DB'…"
  # Run as the postgres OS user (typical Debian/Ubuntu/RHEL setup)
  local sql
  sql=$(cat <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_USER') THEN
    CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';
  ELSE
    ALTER USER $PG_USER WITH PASSWORD '$PG_PASSWORD';
  END IF;
END
\$\$;
EOF
)
  if id postgres >/dev/null 2>&1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "$sql" >/dev/null
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB'" | grep -q 1 || \
      sudo -u postgres createdb -O "$PG_USER" "$PG_DB"
  else
    PGPASSWORD=$PG_PASSWORD psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
      -v ON_ERROR_STOP=1 -c "$sql" >/dev/null || \
      err "Cannot provision Postgres — run with --skip-pg-setup if user/db already exist"
  fi
  install -m 0600 -o root -g root /dev/null "$CONFIG_DIR/.pgpass"
  echo "$PG_HOST:$PG_PORT:*:$PG_USER:$PG_PASSWORD" > "$CONFIG_DIR/.pgpass"
  ok "Postgres ready ($PG_USER@$PG_HOST:$PG_PORT/$PG_DB)"
}

generate_self_signed_cert() {
  log "Generating self-signed cert for $DOMAIN (DEV ONLY)…"
  TLS_CERT=$CONFIG_DIR/server.crt
  TLS_KEY=$CONFIG_DIR/server.key
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TLS_KEY" -out "$TLS_CERT" \
    -days 365 -subj "/CN=$DOMAIN" 2>/dev/null
  chmod 0600 "$TLS_KEY" "$TLS_CERT"
}

install_binary() {
  local os arch src
  os=$(detect_os); arch=$(detect_arch)
  src=$(ensure_binary "$os" "$arch")
  log "Installing $src → $BIN_DIR/gateway"
  install -m 0755 "$src" "$BIN_DIR/gateway"

  log "Symlinking $SCRIPT_PATH → $SYMLINK"
  ln -sf "$SCRIPT_PATH" "$SYMLINK"
  ok "Now you can run 'opam' from anywhere"
}

write_config() {
  local apns_block
  if [[ $SKIP_APNS -eq 1 ]]; then
    apns_block='[apns]
team_id     = ""
key_id      = ""
key_path    = ""
topic       = ""
use_sandbox = false'
  else
    apns_block="[apns]
team_id     = \"$APNS_TEAM\"
key_id      = \"$APNS_KEY_ID\"
key_path    = \"$APNS_KEY_PATH\"
topic       = \"$APNS_TOPIC\"
use_sandbox = false"
  fi

  local server_block
  case $TLS_MODE in
    autocert)
      server_block="[server]
listen_addr = \":$GATEWAY_PORT\"
autocert_domain    = \"$DOMAIN\"
autocert_cache_dir = \"$DATA_DIR/autocert-cache\"
autocert_email     = \"\""
      ;;
    manual|self-signed)
      server_block="[server]
listen_addr = \":$GATEWAY_PORT\"
tls_cert = \"$TLS_CERT\"
tls_key  = \"$TLS_KEY\""
      ;;
  esac

  local ca_token
  ca_token=$(openssl rand -hex 32)
  echo "$ca_token" | install -m 0600 -o root -g root /dev/stdin "$CONFIG_DIR/ca.token"

  log "Writing config to $CONFIG_DIR/gateway.toml"
  cat > "$CONFIG_DIR/gateway.toml" <<EOF
# Generated by opam $(date -u +%Y-%m-%dT%H:%M:%SZ)
$server_block

[ca]
token = "$ca_token"

[database]
host     = "$PG_HOST"
port     = $PG_PORT
user     = "$PG_USER"
password = "$PG_PASSWORD"
dbname   = "$PG_DB"
sslmode  = "disable"

[cert]
ttl = 300

$apns_block

[freeze]
soft_timeout = "30s"
hard_timeout = "120s"
EOF
  chmod 0600 "$CONFIG_DIR/gateway.toml"
  chown root:root "$CONFIG_DIR/gateway.toml"
}

write_systemd_unit() {
  log "Writing systemd unit $SYSTEMD_UNIT"
  local extra_caps=
  [[ $GATEWAY_PORT -lt 1024 ]] && extra_caps="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"

  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=pam-zta Control Gateway
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_DIR/gateway -config $CONFIG_DIR/gateway.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
$extra_caps

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR $LOG_DIR

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_and_wait() {
  log "Enabling + starting pam-zta-gateway…"
  systemctl enable --now pam-zta-gateway

  log "Waiting for /v1/health (up to 30s)…"
  local i ok=0
  for i in $(seq 1 30); do
    if curl -skf "https://$DOMAIN/v1/health" -o /dev/null 2>/dev/null \
       || curl -skf "https://localhost:$GATEWAY_PORT/v1/health" -o /dev/null 2>/dev/null; then
      ok=1; break
    fi
    sleep 1
  done
  if [[ $ok -eq 1 ]]; then ok "Gateway is healthy"
  else warn "Gateway not responding yet — check 'opam status' or 'journalctl -u pam-zta-gateway'"
  fi
}

print_summary() {
  echo
  printf '%s┌─────────────────────────────────────────────────────────────┐%s\n' "$BOLD" "$NC"
  printf '%s│ pam-zta gateway installed                                  │%s\n' "$BOLD" "$NC"
  printf '%s└─────────────────────────────────────────────────────────────┘%s\n' "$BOLD" "$NC"
  echo
  printf '  %sURL:%s         https://%s\n' "$BOLD" "$NC" "$DOMAIN"
  printf '  %sBinary:%s      %s/gateway\n' "$BOLD" "$NC" "$BIN_DIR"
  printf '  %sConfig:%s      %s/gateway.toml\n' "$BOLD" "$NC" "$CONFIG_DIR"
  printf '  %sCA token:%s    %s/ca.token  (paste into ca_service.toml)\n' "$BOLD" "$NC" "$CONFIG_DIR"
  printf '  %sService:%s     systemctl status pam-zta-gateway\n' "$BOLD" "$NC"
  printf '  %sLogs:%s        journalctl -u pam-zta-gateway -f\n' "$BOLD" "$NC"
  echo
  printf '  Next:\n'
  printf '    1. Install the CA service on its own host (../ca/ZTA-CaSetup.exe on Windows,\n'
  printf "       or 'cd ca-service/{mac,linux} && bash install.sh' from source)\n"
  printf '    2. Paste %s into ca_service.toml -> ca_token\n' "$CONFIG_DIR/ca.token"
  printf '    3. Open AppSigner on iOS, scan the QR below\n'
  printf '    4. Generate root cert in AppSigner, run: opam set-root /path/to/root.cert\n'
  echo

  if [[ $SHOW_QR -eq 1 ]]; then
    ensure_qrencode
    print_qr "https://$DOMAIN"
  fi
}

# ---------- subcommands ----------
cmd_install() {
  parse_install_args "$@"
  if [[ -n $REMOTE_TARGET ]]; then
    run_remote install \
      --domain "$DOMAIN" \
      ${TLS_MODE:+--tls "$TLS_MODE"} \
      ${TLS_CERT:+--tls-cert "$TLS_CERT"} ${TLS_KEY:+--tls-key "$TLS_KEY"} \
      ${APNS_TEAM:+--apns-team "$APNS_TEAM"} ${APNS_KEY_ID:+--apns-key-id "$APNS_KEY_ID"} \
      ${APNS_KEY_PATH:+--apns-key-path "$APNS_KEY_PATH"} ${APNS_TOPIC:+--apns-topic "$APNS_TOPIC"} \
      ${SKIP_APNS:+$([[ $SKIP_APNS -eq 1 ]] && echo --skip-apns)} \
      ${PG_PASSWORD:+--pg-password "$PG_PASSWORD"} \
      ${ASSUME_YES:+$([[ $ASSUME_YES -eq 1 ]] && echo --yes)}
    return
  fi

  require_root
  detect_os >/dev/null
  prompt_missing

  ensure_prereqs
  ensure_user
  ensure_dirs
  setup_postgres
  install_binary
  [[ $TLS_MODE == self-signed ]] && generate_self_signed_cert
  write_config
  write_systemd_unit
  start_and_wait
  print_summary
}

cmd_update() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -i) SSH_IDENTITY=$2; shift 2 ;;
      -o) SSH_OPTS+=("$2"); shift 2 ;;
      *@*) REMOTE_TARGET=$1; shift ;;
      *) shift ;;
    esac
  done

  if [[ -n $REMOTE_TARGET ]]; then
    run_remote update
    return
  fi

  require_root
  local os arch src
  os=$(detect_os); arch=$(detect_arch)
  # Force re-fetch on update so we pull the current ref's binary
  rm -f "$GATEWAY_DIR/$(binary_for_host "$os" "$arch")"
  src=$(ensure_binary "$os" "$arch")

  if cmp -s "$src" "$BIN_DIR/gateway" 2>/dev/null; then
    ok "Already up to date"
    return
  fi

  log "Updating $BIN_DIR/gateway from $src"
  install -m 0755 "$src" "$BIN_DIR/gateway.new"
  mv "$BIN_DIR/gateway.new" "$BIN_DIR/gateway"

  log "Restarting service…"
  systemctl restart pam-zta-gateway
  sleep 2
  systemctl is-active --quiet pam-zta-gateway && ok "Update applied" \
    || err "Service failed to restart — see 'journalctl -u pam-zta-gateway'"
}

cmd_set_root() {
  local cert=${1:-}
  [[ -n $cert ]] || err "Usage: opam set-root <cert-file>"
  [[ -f $cert ]] || err "Cert file not found: $cert"

  # Find CA service runtime dir (Linux/macOS)
  local target=
  for candidate in "${XDG_CONFIG_HOME:-$HOME/.config}/pam-zta/root_certs" \
                   "/root/.config/pam-zta/root_certs" \
                   "/var/lib/pam-zta/root_certs"; do
    if [[ -d $(dirname "$candidate") ]]; then target=$candidate; break; fi
  done
  [[ -n $target ]] || err "Could not locate CA service config dir — install the CA service first"

  install -d -m 0700 "$target"
  install -m 0600 "$cert" "$target/$(basename "$cert")"
  ok "Imported root cert → $target/$(basename "$cert")"

  log "If the CA service is running, it will reconnect within ~30s and the gateway"
  log "will auto-promote the matching pending signer to 'root'. Watch the logs:"
  echo "  journalctl -u pam-zta-gateway -f | grep -i 'auto-promot\\|root'"
}

cmd_status() {
  if [[ -n ${1:-} && $1 == *@* ]]; then
    REMOTE_TARGET=$1
    run_remote status
    return
  fi

  if command -v systemctl >/dev/null && systemctl list-units --all --no-legend | grep -q pam-zta-gateway; then
    systemctl status pam-zta-gateway --no-pager -l || true
    echo
  fi
  if [[ -f $CONFIG_DIR/gateway.toml ]]; then
    local domain
    domain=$(awk -F'"' '/autocert_domain/{print $2; exit}' "$CONFIG_DIR/gateway.toml")
    [[ -z $domain ]] && domain=localhost:$GATEWAY_PORT
    echo "Health check ($domain):"
    curl -skf "https://$domain/v1/health" 2>/dev/null && echo \
      || warn "Health check failed"
  else
    warn "No config at $CONFIG_DIR/gateway.toml — gateway not installed?"
  fi
}

cmd_uninstall() {
  if [[ -n ${1:-} && $1 == *@* ]]; then
    REMOTE_TARGET=$1
    run_remote uninstall
    return
  fi

  require_root
  echo "This will remove:"
  echo "  - $BIN_DIR/gateway"
  echo "  - $SYMLINK"
  echo "  - $CONFIG_DIR/ (gateway.toml + ca.token + .pgpass)"
  echo "  - $SYSTEMD_UNIT"
  echo "  - systemd unit pam-zta-gateway"
  echo "It will NOT remove: $DATA_DIR/, the Postgres db, the system user."
  confirm "Proceed?" || { warn "Aborted"; exit 0; }

  systemctl disable --now pam-zta-gateway 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT"
  systemctl daemon-reload || true
  rm -f "$BIN_DIR/gateway" "$SYMLINK"
  rm -rf "$CONFIG_DIR"
  ok "Removed gateway. ($DATA_DIR and Postgres db preserved.)"
}

# ---------- main ----------
main() {
  local cmd=${1:-help}
  shift || true
  case $cmd in
    install)              cmd_install              "$@" ;;
    update)               cmd_update               "$@" ;;
    set-root|set_root)    cmd_set_root             "$@" ;;
    status)               cmd_status               "$@" ;;
    uninstall)            cmd_uninstall            "$@" ;;
    help|-h|--help|"")    usage ;;
    *) err "Unknown command: $cmd  (try 'opam help')" ;;
  esac
}
main "$@"
