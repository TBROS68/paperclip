#!/usr/bin/env bash
#
# install-nodocker.sh — Cài A–Z Paperclip (TBROS68 fork) trên VPS Linux MỚI, KHÔNG dùng Docker
# ============================================================================================
#
# Chạy một lệnh trên VPS Ubuntu 22.04+/Debian 12+ mới tinh:
#   * Node.js 24 (NodeSource) + pnpm (corepack) + Rust (rustup) + build tools
#   * PostgreSQL 17 (repo chính thức PGDG), tạo user/db paperclip với mật khẩu ngẫu nhiên
#   * Clone TBROS68/paperclip → /opt/paperclip, build UI + runner + server
#   * CLI agent: @openai/codex + opencode-ai (dùng OPENAI_BASE_URL/Vilao)
#   * systemd service "paperclip" (user riêng, chỉ nghe 127.0.0.1:3100)
#   * Caddy HTTPS tự động (Let's Encrypt) cho tên miền, tự dừng nginx/apache nếu chiếm :80
#   * ufw (SSH/80/443)
#   * TỰ TẠO LINK MỜI ADMIN ĐẦU TIÊN và in ra cuối quá trình
#
# Cách dùng:
#   curl -fsSL https://raw.githubusercontent.com/TBROS68/paperclip/master/deploy/vps/install-nodocker.sh -o install-nodocker.sh
#   sudo bash install-nodocker.sh
#
# Các lệnh khác:
#   sudo bash /opt/paperclip/deploy/vps/install-nodocker.sh update          # kéo code mới, build lại, restart
#   sudo bash /opt/paperclip/deploy/vps/install-nodocker.sh admin-invite    # in lại link mời admin (nếu chưa có admin)
#   sudo bash /opt/paperclip/deploy/vps/install-nodocker.sh admin-invite --force  # tạo link mới kể cả khi đã có admin
#   sudo bash /opt/paperclip/deploy/vps/install-nodocker.sh uninstall       # gỡ service (giữ DB + dữ liệu)
#
# Biến môi trường tùy chỉnh (đều có mặc định):
#   DOMAIN, OPENAI_API_KEY, OPENAI_BASE_URL, OPENAI_API_KEY_ENV, OPENAI_WIRE_API,
#   APP_DIR, DATA_DIR, APP_PORT, GIT_REPO, GIT_BRANCH, PG_VERSION
#
# Yêu cầu: tối thiểu 2 GB RAM (script tự tạo swap nếu RAM < 4 GB), ~15 GB đĩa trống,
# bản ghi A của domain trỏ về IP VPS.

set -euo pipefail

# ──────────────────────────── Cấu hình ────────────────────────────
DOMAIN="${DOMAIN:-ai.top1.us}"
APP_DIR="${APP_DIR:-/opt/paperclip}"
DATA_DIR="${DATA_DIR:-/var/lib/paperclip}"
APP_PORT="${APP_PORT:-3100}"
APP_USER="paperclip"
GIT_REPO="${GIT_REPO:-https://github.com/TBROS68/paperclip.git}"
GIT_BRANCH="${GIT_BRANCH:-master}"
PG_VERSION="${PG_VERSION:-17}"
NODE_MAJOR="24"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-https://api.vilao.ai/v1}"
OPENAI_API_KEY_ENV="${OPENAI_API_KEY_ENV:-OPENAI_API_KEY}"
OPENAI_WIRE_API="${OPENAI_WIRE_API:-responses}"
ENV_DIR="/etc/paperclip"
ENV_FILE="${ENV_DIR}/paperclip.env"
SERVICE_FILE="/etc/systemd/system/paperclip.service"
CADDYFILE="/etc/caddy/Caddyfile"
INVITE_FILE="/root/paperclip-admin-invite.txt"
export RUSTUP_HOME="/usr/local/rustup"
export CARGO_HOME="/usr/local/cargo"
export PATH="${CARGO_HOME}/bin:${PATH}"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export DEBIAN_FRONTEND=noninteractive

C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'

info()  { printf "${C_CYAN}[info]${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}[ok]${C_RESET}   %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[warn]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}[error]${C_RESET} %s\n" "$*" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ──────────────────────────── Kiểm tra môi trường ────────────────────────────
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command_exists sudo; then
      info "Chưa chạy bằng root — tự chuyển sang sudo..."
      exec sudo -E env DOMAIN="$DOMAIN" APP_DIR="$APP_DIR" DATA_DIR="$DATA_DIR" APP_PORT="$APP_PORT" \
        GIT_REPO="$GIT_REPO" GIT_BRANCH="$GIT_BRANCH" PG_VERSION="$PG_VERSION" \
        OPENAI_API_KEY="${OPENAI_API_KEY:-}" OPENAI_BASE_URL="$OPENAI_BASE_URL" \
        OPENAI_API_KEY_ENV="$OPENAI_API_KEY_ENV" OPENAI_WIRE_API="$OPENAI_WIRE_API" \
        bash "$0" "$@"
    fi
    fail "Cần chạy bằng root (sudo bash $0)."
  fi
}

detect_os() {
  [ -f /etc/os-release ] || fail "Chỉ hỗ trợ Ubuntu/Debian (không thấy /etc/os-release)."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "$ID" in
    ubuntu|debian) ;;
    *) fail "Chỉ hỗ trợ Ubuntu/Debian, phát hiện '$ID'." ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *) fail "Kiến trúc không được hỗ trợ: $(uname -m)" ;;
  esac
}

try_public_ip() {
  local src ip
  for src in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    ip="$(curl -fsSL --max-time 8 "$src" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  done
  echo ""
}

check_dns() {
  info "Kiểm tra DNS: $DOMAIN → IP VPS..."
  local public_ip domain_ip
  public_ip="$(try_public_ip)"
  if [ -z "$public_ip" ]; then
    warn "Không xác định được IP public. Bỏ qua kiểm tra DNS."
    return 0
  fi
  domain_ip="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
  if [ -z "$domain_ip" ]; then
    warn "Không phân giải được $DOMAIN — cần trỏ bản ghi A về $public_ip."
  elif [ "$domain_ip" = "$public_ip" ]; then
    ok "DNS đã trỏ đúng: $DOMAIN → $public_ip"
  else
    warn "DNS $DOMAIN ($domain_ip) chưa trỏ về IP VPS ($public_ip) — HTTPS sẽ chưa cấp được."
  fi
}

ensure_swap() {
  local mem_mb swap_mb
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  swap_mb="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"
  if [ "$mem_mb" -lt 4000 ] && [ "$swap_mb" -lt 2000 ] && [ ! -f /swapfile ]; then
    info "RAM ${mem_mb} MB — tạo swap 4 GB để build không bị thiếu bộ nhớ..."
    fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Đã bật swap 4 GB."
  fi
}

# ──────────────────────────── Cài phụ thuộc ────────────────────────────
install_packages() {
  info "Cài gói hệ thống (curl, git, build tools, ufw, ...)..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git openssl ufw jq ripgrep python3 \
    build-essential pkg-config libc6-dev lsb-release iproute2
  ok "Gói hệ thống sẵn sàng."
}

install_node() {
  local major=""
  if command_exists node; then
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  if [ "${major:-0}" -ge "$NODE_MAJOR" ] 2>/dev/null; then
    ok "Node.js $(node -v) đã có."
  else
    info "Cài Node.js ${NODE_MAJOR}.x (NodeSource)..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
    ok "Node.js $(node -v)."
  fi
  corepack enable
  ok "corepack đã bật (pnpm sẽ theo phiên bản ghim trong repo)."
}

install_rust() {
  if [ -x "${CARGO_HOME}/bin/rustup" ]; then
    ok "rustup đã có."
  else
    info "Cài rustup (Rust toolchain cho paperclip-runnerd)..."
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain none
    ok "rustup đã cài."
  fi
}

install_postgres() {
  if command_exists psql && systemctl list-unit-files 2>/dev/null | grep -q '^postgresql'; then
    ok "PostgreSQL đã có ($(psql --version | awk '{print $3}'))."
  else
    info "Cài PostgreSQL ${PG_VERSION} (repo PGDG)..."
    # shellcheck disable=SC1091
    . /etc/os-release
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt-get update -y
    apt-get install -y "postgresql-${PG_VERSION}"
  fi
  systemctl enable --now postgresql >/dev/null 2>&1 || true
  local tries=0
  until runuser -u postgres -- pg_isready -q >/dev/null 2>&1; do
    tries=$((tries + 1)); [ "$tries" -ge 30 ] && fail "PostgreSQL không khởi động được."
    sleep 2
  done
  ok "PostgreSQL đang chạy."
}

install_agent_clis() {
  info "Cài CLI agent: @openai/codex, opencode-ai..."
  npm install --global --omit=dev @openai/codex@latest opencode-ai@latest >/dev/null 2>&1 \
    || warn "Cài CLI agent thất bại — chạy tay: npm i -g @openai/codex opencode-ai"
  ok "CLI agent đã cài."
}

# ──────────────────────────── Source + build ────────────────────────────
clone_repo() {
  git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
  if [ -d "${APP_DIR}/.git" ]; then
    info "Cập nhật source tại $APP_DIR..."
    git -C "$APP_DIR" fetch --depth 1 origin "$GIT_BRANCH"
    git -C "$APP_DIR" reset --hard "origin/$GIT_BRANCH"
  else
    info "Clone ${GIT_REPO} (branch ${GIT_BRANCH}) → ${APP_DIR}..."
    mkdir -p "$(dirname "$APP_DIR")"
    git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_REPO" "$APP_DIR"
  fi
  ok "Source: commit $(git -C "$APP_DIR" rev-parse --short HEAD)."
}

build_app() {
  info "Build Paperclip (pnpm install + UI + runner Rust + server) — 15–40 phút tùy VPS..."
  cd "$APP_DIR"
  (cd packages/paperclip-runner && { rustup toolchain install >/dev/null 2>&1 || rustup show >/dev/null; })
  export PAPERCLIP_BUILD_COMMIT
  PAPERCLIP_BUILD_COMMIT="$(git rev-parse HEAD)"
  export NODE_OPTIONS="--max-old-space-size=4096"
  pnpm install --frozen-lockfile
  pnpm --filter @paperclipai/ui build
  pnpm --filter @paperclipai/plugin-sdk build
  pnpm --filter @paperclipai/server build
  unset NODE_OPTIONS
  [ -f server/dist/index.js ] || fail "Build xong nhưng thiếu server/dist/index.js."
  ok "Build hoàn tất."
}

# ──────────────────────────── User, DB, env ────────────────────────────
ensure_user() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  mkdir -p "$DATA_DIR"
  chown -R "$APP_USER:$APP_USER" "$DATA_DIR"
}

env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    { grep -v "^${key}=" "$ENV_FILE" || true; } > "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

ask_api_key() {
  [ -n "${OPENAI_API_KEY:-}" ] && return 0
  if [ -n "$(env_get "$OPENAI_API_KEY_ENV")" ]; then
    info "Dùng ${OPENAI_API_KEY_ENV} đã có trong $ENV_FILE."
    return 0
  fi
  printf "${C_YELLOW}Nhập API key Vilao (lấy tại https://vilao.ai → dashboard), Enter để bỏ qua:${C_RESET}\n> "
  read -r input_key </dev/tty || true
  if [ -n "${input_key:-}" ]; then
    OPENAI_API_KEY="$input_key"
  else
    warn "Chưa có key — agent sẽ không chạy tới khi set ${OPENAI_API_KEY_ENV} trong $ENV_FILE."
  fi
}

write_env() {
  info "Ghi cấu hình ${ENV_FILE}..."
  mkdir -p "$ENV_DIR"; chmod 700 "$ENV_DIR"
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"

  local pg_password
  pg_password="$(env_get POSTGRES_PASSWORD)"
  [ -n "$pg_password" ] || pg_password="$(openssl rand -hex 16)"
  local auth_secret
  auth_secret="$(env_get BETTER_AUTH_SECRET)"
  [ -n "$auth_secret" ] || auth_secret="$(openssl rand -hex 32)"

  set_env NODE_ENV "production"
  set_env HOME "$DATA_DIR"
  set_env HOST "127.0.0.1"
  set_env PORT "$APP_PORT"
  set_env SERVE_UI "true"
  set_env PAPERCLIP_HOME "$DATA_DIR"
  set_env PAPERCLIP_INSTANCE_ID "default"
  set_env PAPERCLIP_PUBLIC_URL "https://${DOMAIN}"
  set_env PAPERCLIP_DEPLOYMENT_MODE "authenticated"
  set_env PAPERCLIP_DEPLOYMENT_EXPOSURE "public"
  set_env PAPERCLIP_ALLOWED_HOSTNAMES "${DOMAIN},localhost,127.0.0.1"
  set_env PAPERCLIP_MIGRATION_AUTO_APPLY "true"
  set_env OPENCODE_ALLOW_ALL_MODELS "true"
  set_env GEMINI_SANDBOX "false"
  set_env POSTGRES_PASSWORD "$pg_password"
  set_env DATABASE_URL "postgres://paperclip:${pg_password}@127.0.0.1:5432/paperclip"
  set_env BETTER_AUTH_SECRET "$auth_secret"
  set_env OPENAI_BASE_URL "$OPENAI_BASE_URL"
  set_env OPENAI_API_KEY_ENV "$OPENAI_API_KEY_ENV"
  set_env OPENAI_WIRE_API "$OPENAI_WIRE_API"
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    set_env "$OPENAI_API_KEY_ENV" "$OPENAI_API_KEY"
  fi
  ok "Đã ghi ${ENV_FILE} (quyền 600)."
}

setup_database() {
  info "Tạo/đồng bộ user + database PostgreSQL 'paperclip'..."
  local pg_password
  pg_password="$(env_get POSTGRES_PASSWORD)"
  (cd /tmp && runuser -u postgres -- psql -q -v ON_ERROR_STOP=1 -v pw="$pg_password" >/dev/null) <<'SQL'
SELECT 'CREATE ROLE paperclip LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'paperclip')\gexec
ALTER ROLE paperclip WITH LOGIN PASSWORD :'pw';
SELECT 'CREATE DATABASE paperclip OWNER paperclip' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'paperclip')\gexec
SQL
  ok "Database sẵn sàng (chỉ nghe localhost)."
}

# ──────────────────────────── systemd ────────────────────────────
write_service() {
  info "Tạo systemd service paperclip..."
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Paperclip (TBROS68 fork)
After=network-online.target postgresql.service
Wants=network-online.target postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$(command -v node) --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=30
TasksMax=4096
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable paperclip >/dev/null 2>&1
  ok "Đã tạo ${SERVICE_FILE}."
}

start_app() {
  info "Khởi động Paperclip (lần đầu sẽ tự chạy migration DB)..."
  systemctl restart paperclip
  local tries=0
  until [ "$tries" -ge 72 ]; do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1; then
      ok "Paperclip đang chạy (http://127.0.0.1:${APP_PORT}/api/health)."
      return 0
    fi
    tries=$((tries + 1)); sleep 5
  done
  warn "Chưa thấy /api/health sau 6 phút. Log gần nhất:"
  journalctl -u paperclip -n 40 --no-pager 2>/dev/null || true
  fail "Xem log đầy đủ: journalctl -u paperclip -f"
}

# ──────────────────────────── Caddy + firewall ────────────────────────────
install_caddy() {
  if command_exists caddy; then ok "Caddy đã có."; return 0; fi
  info "Cài Caddy (reverse proxy + HTTPS tự động)..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1 || true
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
  ok "Caddy đã cài."
}

port_in_use_by_other() {
  local port="$1" owner="$2" out=""
  if command_exists ss; then
    out="$(ss -ltnpH "sport = :${port}" 2>/dev/null || true)"
    [ -n "$out" ] || return 1
    printf '%s' "$out" | grep -q "$owner" && return 1
    return 0
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

stop_conflicting_webserver() {
  local unit
  for unit in nginx apache2 httpd openresty lighttpd; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${unit}\\.service" || continue
    if systemctl is-active --quiet "$unit"; then
      warn "Phát hiện ${unit} đang chạy — backup /etc/${unit} rồi dừng + disable để Caddy dùng 80/443."
      tar czf "/root/${unit}-config-backup.tar.gz" "/etc/${unit}" 2>/dev/null || true
      systemctl stop "$unit" >/dev/null 2>&1 || true
      systemctl disable "$unit" >/dev/null 2>&1 || true
      sleep 2
    fi
  done
}

configure_caddy() {
  info "Cấu hình Caddy: ${DOMAIN} → 127.0.0.1:${APP_PORT}..."
  if port_in_use_by_other 80 "caddy"; then stop_conflicting_webserver; fi
  local global_block=""
  if port_in_use_by_other 80 "caddy"; then
    warn "Cổng 80 vẫn bị process khác chiếm — Caddy chỉ dùng :443 (ACME TLS-ALPN)."
    global_block=$'{\n\tauto_https disable_redirects\n}\n'
  fi
  port_in_use_by_other 443 "caddy" && fail "Cổng 443 bị process khác chiếm — dừng nó rồi chạy lại."
  cat > "$CADDYFILE" <<EOF
# Sinh bởi install-nodocker.sh — Paperclip qua HTTPS tự động.
${global_block}
${DOMAIN} {
	encode gzip zstd
	reverse_proxy 127.0.0.1:${APP_PORT}
}
EOF
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null
  systemctl enable caddy >/dev/null 2>&1 || true
  local tries=0
  until systemctl restart caddy >/dev/null 2>&1 && systemctl is-active --quiet caddy; do
    tries=$((tries + 1))
    if [ "$tries" -ge 5 ]; then
      warn "Caddy không khởi động được:"
      journalctl -u caddy -n 15 --no-pager 2>/dev/null || true
      return 0
    fi
    sleep 3
  done
  ok "Caddy đang chạy; chứng chỉ HTTPS sẽ được cấp tự động."
}

configure_firewall() {
  info "Firewall: mở SSH/80/443..."
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  ok "Firewall đã cấu hình (nhớ mở 80/443 ở security group của nhà cung cấp cloud nếu có)."
}

# ──────────────────────────── Link mời admin đầu tiên ────────────────────────────
# Tương đương `paperclipai auth bootstrap-ceo`: ghi một invite bootstrap_ceo vào DB
# (token chỉ lưu dạng sha256), thu hồi các invite bootstrap cũ còn hạn.
create_admin_invite() {
  local force="${1:-}" db_url admins token hash url
  db_url="$(env_get DATABASE_URL)"
  [ -n "$db_url" ] || fail "Không thấy DATABASE_URL trong $ENV_FILE."
  admins="$(psql "$db_url" -tAq -c "SELECT count(*) FROM instance_user_roles WHERE role = 'instance_admin'" 2>/dev/null)" \
    || fail "Không đọc được bảng instance_user_roles (server đã chạy migration chưa? journalctl -u paperclip)."
  if [ "${admins:-0}" -gt 0 ] && [ "$force" != "--force" ]; then
    ok "Đã có admin — không cần link mời. (Dùng: admin-invite --force để tạo link mới.)"
    return 0
  fi
  token="pcp_bootstrap_$(openssl rand -hex 24)"
  hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')"
  psql "$db_url" -q -v ON_ERROR_STOP=1 -v hash="$hash" >/dev/null <<'SQL'
UPDATE invites SET revoked_at = now(), updated_at = now()
  WHERE invite_type = 'bootstrap_ceo' AND revoked_at IS NULL AND accepted_at IS NULL AND expires_at > now();
INSERT INTO invites (invite_type, token_hash, allowed_join_types, expires_at, invited_by_user_id)
  VALUES ('bootstrap_ceo', :'hash', 'human', now() + interval '72 hours', 'system');
SQL
  url="$(env_get PAPERCLIP_PUBLIC_URL)"
  url="${url%/}/invite/${token}"
  umask 077; printf '%s\n' "$url" > "$INVITE_FILE"
  printf "\n${C_GREEN}Link tạo ADMIN ĐẦU TIÊN (hết hạn sau 72 giờ, dùng 1 lần):${C_RESET}\n"
  printf "  ${C_CYAN}%s${C_RESET}\n" "$url"
  printf "  (đã lưu tại %s)\n\n" "$INVITE_FILE"
}

final_check() {
  info "Kiểm tra https://${DOMAIN}/api/health..."
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "https://${DOMAIN}/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    ok "HTTPS hoạt động: https://${DOMAIN}/"
  else
    warn "HTTP ${code:-n/a} từ https://${DOMAIN}/api/health — có thể DNS/chứng chỉ chưa xong, thử lại sau 1–2 phút."
  fi
}

print_summary() {
  printf "\n${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}\n"
  printf "${C_GREEN}  Paperclip (không Docker) đã cài xong!${C_RESET}\n"
  printf "${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}\n"
  printf "  URL:        https://%s\n" "$DOMAIN"
  printf "  Source:     %s\n" "$APP_DIR"
  printf "  Dữ liệu:    %s  +  PostgreSQL db 'paperclip'\n" "$DATA_DIR"
  printf "  Cấu hình:   %s\n\n" "$ENV_FILE"
  printf "${C_YELLOW}Tạo admin:${C_RESET} mở link mời ở trên → Đăng ký tài khoản → Chấp nhận lời mời.\n"
  printf "  Mất link?  sudo bash %s/deploy/vps/install-nodocker.sh admin-invite\n\n" "$APP_DIR"
  printf "${C_YELLOW}Lệnh hữu ích:${C_RESET}\n"
  printf "  Log:        journalctl -u paperclip -f\n"
  printf "  Restart:    systemctl restart paperclip\n"
  printf "  Nâng cấp:   sudo bash %s/deploy/vps/install-nodocker.sh update\n" "$APP_DIR"
  if [ -z "$(env_get "$OPENAI_API_KEY_ENV")" ]; then
    printf "\n${C_YELLOW}Chưa có key AI:${C_RESET} thêm %s=<key Vilao> vào %s rồi: systemctl restart paperclip\n" \
      "$OPENAI_API_KEY_ENV" "$ENV_FILE"
  fi
}

# ──────────────────────────── Các chế độ ────────────────────────────
do_install() {
  detect_os
  info "Bắt đầu cài Paperclip (không Docker) — domain: $DOMAIN"
  check_dns || true
  ensure_swap
  install_packages
  install_node
  install_rust
  install_postgres
  install_agent_clis
  ensure_user
  ask_api_key
  write_env
  setup_database
  clone_repo
  build_app
  write_service
  start_app
  install_caddy
  configure_caddy
  configure_firewall
  final_check
  create_admin_invite
  print_summary
}

do_update() {
  [ -d "${APP_DIR}/.git" ] || fail "Chưa cài tại $APP_DIR — chạy script không tham số trước."
  detect_os
  ensure_swap
  ensure_user
  write_env
  setup_database
  clone_repo
  build_app
  write_service
  start_app
  install_caddy
  configure_caddy
  final_check
  create_admin_invite
  print_summary
}

do_uninstall() {
  warn "Gỡ service Paperclip + cấu hình Caddy (GIỮ source, dữ liệu và database)..."
  systemctl disable --now paperclip >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"; systemctl daemon-reload
  systemctl disable --now caddy >/dev/null 2>&1 || true
  rm -f "$CADDYFILE"
  if [ -f /root/nginx-config-backup.tar.gz ]; then
    info "Khôi phục nginx cũ: tar xzf /root/nginx-config-backup.tar.gz -C / && systemctl enable --now nginx"
  fi
  info "Xóa hẳn (KHÔNG hoàn tác): rm -rf $APP_DIR $DATA_DIR $ENV_DIR; runuser -u postgres -- dropdb paperclip"
  ok "Xong."
}

case "${1:-install}" in
  install)      require_root "$@"; do_install ;;
  update)       require_root "$@"; do_update ;;
  admin-invite) require_root "$@"; create_admin_invite "${2:-}" ;;
  uninstall)    require_root "$@"; do_uninstall ;;
  -h|--help)    grep -E "^#" "$0" | grep -v '^#!' | sed 's/^#\s\{0,1\}//' | head -40 ;;
  *) fail "Tham số không hợp lệ: $1 (install | update | admin-invite [--force] | uninstall)" ;;
esac
