#!/usr/bin/env bash
#
# install.sh — Tự động cài đặt A–Z Paperclip (TBROS68 fork) trên VPS Linux
# ============================================================================
#
# Một file, chạy từ A đến Z cho người dùng mới:
#   * Cài Docker Engine + Compose plugin nếu chưa có
#   * Clone source từ TBROS68/paperclip (có tính năng OPENAI_BASE_URL / Vilao)
#   * Build image Docker và chạy container (kèm PostgreSQL, UI đi kèm)
#   * Cài Caddy (HTTPS tự động Let's Encrypt) cho tên miền ai.top1.us
#   * Mở firewall (SSH / 80 / 443)
#   * Kiểm tra sức khỏe và in tóm tắt cách dùng
#
# Cách dùng (chạy với quyền root, hoặc script tự sudo):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/TBROS68/paperclip/master/deploy/vps/install.sh)"
#   # hoặc lưu về máy rồi:  sudo bash install.sh
#
# Các biến môi trường tùy chỉnh (đều có mặc định):
#   DOMAIN              Tên miền (mặc định: ai.top1.us)
#   OPENAI_API_KEY      Key Vilao (nếu không set, script sẽ hỏi khi chạy)
#   OPENAI_BASE_URL     Base URL OpenAI-compatible (mặc định: https://api.vilao.ai/v1)
#   APP_DIR             Thư mục cài đặt (mặc định: /opt/paperclip)
#   APP_PORT            Cổng nội bộ của Paperclip (mặc định: 3100)
#
# Nâng cấp sau này:
#   sudo bash /opt/paperclip/deploy/vps/install.sh update
#
# Gỡ cài (tùy chọn):
#   sudo bash /opt/paperclip/deploy/vps/install.sh uninstall
#
# Yêu cầu: Ubuntu 22.04+, Debian 12+, tối thiểu 2 GB RAM, domain trỏ về IP VPS.

set -euo pipefail

# ──────────────────────────── Cấu hình ────────────────────────────
DOMAIN="${DOMAIN:-ai.top1.us}"
APP_DIR="${APP_DIR:-/opt/paperclip}"
APP_PORT="${APP_PORT:-3100}"
GIT_REPO="${GIT_REPO:-https://github.com/TBROS68/paperclip.git}"
GIT_BRANCH="${GIT_BRANCH:-master}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-https://api.vilao.ai/v1}"
OPENAI_API_KEY_ENV="${OPENAI_API_KEY_ENV:-OPENAI_API_KEY}"
OPENAI_WIRE_API="${OPENAI_WIRE_API:-responses}"
COMPOSE_FILE="deploy/vps/compose.yml"
COMPOSE_PATH="${APP_DIR}/deploy/vps/compose.yml"
ENV_FILE="${APP_DIR}/.env"
CADDYFILE="/etc/caddy/Caddyfile"

C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_DIM='\033[2m'; C_RESET='\033[0m'

info()  { printf "${C_CYAN}[info]${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}[ok]${C_RESET}   %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[warn]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}[error]${C_RESET} %s\n" "$*" >&2; exit 1; }

# ──────────────────────────── Hàm phụ ────────────────────────────
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      info "Chưa chạy bằng root — tự chuyển sang sudo..."
      exec sudo -E env DOMAIN="$DOMAIN" APP_DIR="$APP_DIR" APP_PORT="$APP_PORT" \
        GIT_REPO="$GIT_REPO" GIT_BRANCH="$GIT_BRANCH" \
        OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
        OPENAI_BASE_URL="$OPENAI_BASE_URL" \
        OPENAI_API_KEY_ENV="$OPENAI_API_KEY_ENV" \
        OPENAI_WIRE_API="$OPENAI_WIRE_API" \
        bash "$0" "$@"
    fi
    fail "Cần chạy bằng root (sudo bash $0)."
  fi
}

detect_os() {
  if [ ! -f /etc/os-release ]; then
    fail "Script chỉ hỗ trợ Debian/Ubuntu (không tìm thấy /etc/os-release)."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "$ID" in
    ubuntu|debian) ;;
    *) fail "Script chỉ hỗ trợ Ubuntu/Debian, phát hiện '$ID'." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    *) fail "Kiến trúc không được hỗ trợ: $(uname -m)" ;;
  esac
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

try_public_ip() {
  # Lấy IP public (fallback nhiều nguồn), trả về chuỗi rỗng nếu không lấy được.
  for src in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    ip="$(curl -fsSL --max-time 8 "$src" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  done
  echo ""
}

check_dns() {
  info "Kiểm tra DNS: $DOMAIN → IP VPS..."
  public_ip="$(try_public_ip)"
  if [ -z "$public_ip" ]; then
    warn "Không xác định được IP public của VPS. Bỏ qua kiểm tra DNS."
    return 0
  fi
  domain_ip="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
  if [ -z "$domain_ip" ]; then
    warn "Không phân giải được $DOMAIN. Cần trỏ bản ghi A về $public_ip trước khi chạy."
    return 0
  fi
  if [ "$domain_ip" = "$public_ip" ]; then
    ok "DNS đã trỏ đúng: $DOMAIN → $public_ip"
  else
    warn "DNS của $DOMAIN ($domain_ip) chưa trỏ về IP VPS ($public_ip)."
    warn "HTTPS (Let's Encrypt) sẽ không cấp được chứng chỉ tới khi bản ghi A đúng."
  fi
}

install_docker() {
  if command_exists docker && docker info >/dev/null 2>&1; then
    ok "Docker đã chạy sẵn."
  elif command_exists docker; then
    info "Docker đã cài nhưng daemon chưa chạy — bật lên..."
    systemctl enable --now docker >/dev/null 2>&1 || service docker start
  else
    info "Cài Docker Engine (script chính thức get.docker.com)..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    systemctl enable --now docker
  fi
  if ! docker compose version >/dev/null 2>&1; then
    warn "Thiếu Docker Compose plugin — cài bổ sung..."
    apt-get install -y docker-compose-plugin >/dev/null 2>&1 || \
      curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  docker compose version
  ok "Docker + Compose sẵn sàng."
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  info "Cập nhật apt và cài gói cần thiết (curl, git, openssl, ufw)..."
  apt-get update -y
  apt-get install -y --no-install-recommends curl ca-certificates git openssl ufw
  ok "Gói hệ thống đã sẵn sàng."
}

clone_repo() {
  if [ -d "${APP_DIR}/.git" ]; then
    info "Đã có source tại $APP_DIR — cập nhật từ remote..."
    git -C "$APP_DIR" fetch --depth 1 origin "$GIT_BRANCH"
    git -C "$APP_DIR" reset --hard "origin/$GIT_BRANCH"
  else
    info "Clone source ${GIT_REPO} (branch ${GIT_BRANCH}) vào ${APP_DIR}..."
    mkdir -p "$APP_DIR"
    git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_REPO" "$APP_DIR"
  fi
  ok "Source sẵn sàng tại $APP_DIR (commit: $(git -C "$APP_DIR" rev-parse --short HEAD))."
}

ask_api_key() {
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    return 0
  fi
  # Reuse key đã có trong .env cũ (không hỏi lại khi chạy lại)
  if [ -f "$ENV_FILE" ] && grep -q "^${OPENAI_API_KEY_ENV}=." "$ENV_FILE"; then
    info "Dùng ${OPENAI_API_KEY_ENV} đã cấu hình trong $ENV_FILE."
    return 0
  fi
  printf "${C_YELLOW}Nhập API key Vilao (đăng ký tại https://vilao.ai, lấy từ dashboard):${C_RESET}\n> "
  read -r input_key || true
  if [ -z "${input_key:-}" ]; then
    warn "Không nhập key — agents sẽ không chạy được cho tới khi bạn set ${OPENAI_API_KEY_ENV} trong $ENV_FILE."
  else
    OPENAI_API_KEY="$input_key"
  fi
}

write_env() {
  info "Tạo/giữ ${ENV_FILE}..."
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  set_env() {
    local key="$1" value="$2"
    # An toàn với mọi ký tự trong value: chỉ regex trên TÊN key (do script đặt),
    # value được ghi nguyên văn bằng printf — không đi qua sed/regex.
    if [ -f "$ENV_FILE" ] && grep -q "^${key}=" "$ENV_FILE"; then
      grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp"
      mv "${ENV_FILE}.tmp" "$ENV_FILE"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  }
  set_env PAPERCLIP_PUBLIC_URL "https://${DOMAIN}"
  set_env PAPERCLIP_DEPLOYMENT_MODE "authenticated"
  set_env PAPERCLIP_DEPLOYMENT_EXPOSURE "public"
  set_env PAPERCLIP_ALLOWED_HOSTNAMES "$DOMAIN,localhost"
  set_env SERVE_UI "true"
  set_env OPENAI_BASE_URL    "$OPENAI_BASE_URL"
  set_env OPENAI_API_KEY_ENV "$OPENAI_API_KEY_ENV"
  set_env OPENAI_WIRE_API    "$OPENAI_WIRE_API"
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    set_env "$OPENAI_API_KEY_ENV" "$OPENAI_API_KEY"
  fi
  # Secret chỉ sinh một lần, giữ nguyên khi chạy lại
  if ! grep -q "^BETTER_AUTH_SECRET=..*" "$ENV_FILE"; then
    set_env BETTER_AUTH_SECRET "$(openssl rand -hex 32)"
  fi
  # Mật khẩu PostgreSQL nội bộ — sinh một lần, giữ nguyên khi chạy lại.
  # Server "authenticated + public" KHÔNG cho dùng embedded DB, nên cần
  # service db riêng với DATABASE_URL (xem comment trong compose.yml).
  if ! grep -q "^POSTGRES_PASSWORD=..*" "$ENV_FILE"; then
    set_env POSTGRES_PASSWORD "$(openssl rand -hex 16)"
  fi
  ok "Đã cấu hình ${ENV_FILE} (permission 600)."

  # Compose file riêng: env_file truyền MỌI key trong .env vào container
  # (compose quickstart của repo chỉ đẩy một số key, thiếu OPENAI_BASE_URL).
  # Kèm service db (PostgreSQL 17) vì deployment authenticated+public bắt
  # buộc DATABASE_URL; db chỉ lộ trong mạng Docker (không publish port).
  info "Sinh ${COMPOSE_PATH}..."
  mkdir -p "$(dirname "$COMPOSE_PATH")"
  cat > "$COMPOSE_PATH" <<EOF
services:
  db:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: paperclip
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-paperclip}
      POSTGRES_DB: paperclip
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U paperclip -d paperclip"]
      interval: 5s
      timeout: 5s
      retries: 30
    volumes:
      - pgdata:/var/lib/postgresql/data

  paperclip:
    build:
      context: ../..
      dockerfile: Dockerfile
    image: paperclip-tbros:local
    restart: unless-stopped
    pids_limit: 2048
    ports:
      - "127.0.0.1:${APP_PORT}:${APP_PORT}"
    env_file:
      - ${ENV_FILE}
    environment:
      HOST: "0.0.0.0"
      PAPERCLIP_HOME: "/paperclip"
      DATABASE_URL: postgres://paperclip:\${POSTGRES_PASSWORD:-paperclip}@db:5432/paperclip
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - paperclip-data:/paperclip

volumes:
  paperclip-data:
  pgdata:
EOF
  chmod 600 "$COMPOSE_PATH"
  ok "Đã sinh ${COMPOSE_PATH}."
}

start_paperclip() {
  info "Build image Docker (Rust runner + UI + server — có thể mất 10–20 phút tùy VPS)..."
  info "Nhật ký build:  docker compose -f ${COMPOSE_FILE} logs -f"
  cd "$APP_DIR"
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --build

  info "Chờ Paperclip khởi động trên cổng ${APP_PORT} (tối đa 5 phút)..."
  local tries=0
  until [ "$tries" -ge 60 ]; do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1; then
      ok "Paperclip đã chạy (http://127.0.0.1:${APP_PORT}/api/health)."
      return 0
    fi
    tries=$((tries + 1)); sleep 5
  done
  warn "Chưa thấy /api/health sau 5 phút. Kiểm tra: cd $APP_DIR && docker compose --env-file $ENV_FILE -f $COMPOSE_FILE logs -f"
  return 1
}

install_caddy() {
  if command_exists caddy; then
    ok "Caddy đã cài sẵn."
    return 0
  fi
  info "Cài Caddy (reverse proxy + HTTPS tự động)..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y
  apt-get install -y caddy
  ok "Caddy đã cài."
}

# Cổng có đang bị process KHÁC (không phải caddy) chiếm không?
port_in_use_by_other() {
  local port="$1" owner="$2" out=""
  if command_exists ss; then
    out="$(ss -ltnpH "sport = :${port}" 2>/dev/null || true)"
    [ -n "$out" ] || return 1
    printf '%s' "$out" | grep -q "$owner" && return 1
    return 0
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

start_caddy_service() {
  # Nạp cấu hình mới bằng cách RESTART service (không dùng `caddy reload`:
  # lệnh đó cần admin API ở :2019 và sẽ fail nếu service chưa chạy).
  systemctl enable caddy >/dev/null 2>&1 || true
  local tries=0
  while [ "$tries" -lt 5 ]; do
    if systemctl restart caddy >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
      return 0
    fi
    tries=$((tries + 1)); sleep 3
  done
  return 1
}

configure_caddy() {
  info "Cấu hình Caddy cho ${DOMAIN} → 127.0.0.1:${APP_PORT}..."

  # Nhiều VPS có sẵn nginx/apache chiếm :80. Caddy mặc định tạo thêm listener :80
  # để redirect + ACME HTTP-01 → sẽ fail với "bind: address already in use".
  # `auto_https disable_redirects` bỏ listener đó; Let's Encrypt vẫn cấp được
  # chứng chỉ qua TLS-ALPN-01 trên :443.
  local global_block=""
  if port_in_use_by_other 80 "caddy"; then
    warn "Cổng 80 đang bị process khác chiếm — Caddy chỉ lắng nghe :443 (không có redirect HTTP→HTTPS; ACME dùng TLS-ALPN-01)."
    global_block="{
	auto_https disable_redirects
}
"
  fi
  if port_in_use_by_other 443 "caddy"; then
    fail "Cổng 443 đang bị process khác chiếm — dừng process đó rồi chạy lại script."
  fi

  cat > "$CADDYFILE" <<EOF
# Cấu hình do install.sh sinh — Paperclip qua HTTPS tự động.
${global_block}
${DOMAIN} {
	encode gzip zstd
	reverse_proxy 127.0.0.1:${APP_PORT}
}
EOF
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null
  if start_caddy_service; then
    ok "Caddy đang chạy với cấu hình mới; HTTPS sẽ được cấp tự động."
  else
    warn "Không khởi động được service Caddy. Log gần nhất:"
    journalctl -u caddy -n 15 --no-pager 2>/dev/null | tail -15 || true
    warn "Chạy tay: systemctl restart caddy"
  fi
}

configure_firewall() {
  info "Cấu hình firewall (SSH + 80 + 443)..."
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  ok "Firewall: OpenSSH, 80, 443 đã mở."
  warn "Nếu VPS dùng cloud security group (AWS/Azure/GCP), hãy mở 80/443 ở đó tương ứng."
}

final_check() {
  info "Kiểm tra https://${DOMAIN}/api/health..."
  local code=""
  if command_exists caddy; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "https://${DOMAIN}/api/health" || true)"
  fi
  if [ "$code" = "200" ]; then
    ok "✅ Hệ thống sẵn sàng tại https://${DOMAIN}/"
  else
    warn "HTTP ${code:-n/a} từ https://${DOMAIN}/api/health — có thể DNS chưa trỏ hoặc bản ghi chưa lan tỏa."
    warn "Kiểm tra lại sau 1–2 phút: curl https://${DOMAIN}/api/health"
  fi
}

print_summary() {
  printf "\n${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}\n"
  printf "${C_GREEN}  Paperclip đã được cài đặt thành công!${C_RESET}\n"
  printf "${C_GREEN}══════════════════════════════════════════════════════════════${C_RESET}\n\n"
  printf "  🌐  URL:            ${C_CYAN}https://${DOMAIN}${C_RESET}\n"
  printf "  📁  Source:         %s\n" "$APP_DIR"
  printf "  ⚙️   Cấu hình:       %s\n" "$ENV_FILE"
  printf "  🗄️   Dữ liệu:        Volume Docker \"paperclip-data\" (giữ khi update)\n\n"

  printf "${C_YELLOW}Bước tiếp theo (onboarding lần đầu):${C_RESET}\n"
  printf "  1. Mở https://${DOMAIN} trong trình duyệt.\n"
  printf "  2. Tạo tài khoản admin đầu tiên (người đầu tiên đăng ký là chủ sở hữu).\n"
  printf "  3. Làm theo onboarding — chọn OpenAI-compatible (Vilao) làm provider,\n"
  printf "     chọn model (vd gpt-4o), tạo CEO agent, và bắt đầu giao việc.\n\n"

  printf "${C_YELLOW}Các lệnh hữu ích:${C_RESET}\n"
  printf "  Xem log:        cd %s && docker compose --env-file %s -f %s logs -f\n" "$APP_DIR" "$ENV_FILE" "$COMPOSE_FILE"
  printf "  Nâng cấp:       sudo bash %s/deploy/vps/install.sh update\n" "$APP_DIR"
  printf "  Gỡ cài:         sudo bash %s/deploy/vps/install.sh uninstall\n" "$APP_DIR"
  if [ -z "${OPENAI_API_KEY:-}" ] && ! grep -q "^${OPENAI_API_KEY_ENV}=." "$ENV_FILE"; then
    printf "\n${C_YELLOW}Chú ý: chưa có key AI.${C_RESET} Set %s=<key Vilao> trong %s\n" \
      "$OPENAI_API_KEY_ENV" "$ENV_FILE"
    printf "  rồi chạy: sudo bash %s/deploy/vps/install.sh update\n\n" "$APP_DIR"
  fi
}

do_update() {
  require_root
  [ -d "${APP_DIR}/.git" ] || fail "Chưa cài Paperclip tại $APP_DIR — chạy script lần đầu không có tham số."
  info "Nâng cấp Paperclip..."
  git -C "$APP_DIR" fetch --depth 1 origin "$GIT_BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$GIT_BRANCH"
  cd "$APP_DIR"
  # Sinh lại .env + compose.yml từ script mới (compose.yml là file sinh, không có
  # trong git — nếu không sinh lại thì VPS vẫn chạy compose cũ).
  ask_api_key
  write_env
  info "Build image Docker (Rust runner + UI + server — có thể mất 10–20 phút tùy VPS)..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --build
  info "Chờ Paperclip khởi động trên cổng ${APP_PORT} (tối đa 5 phút)..."
  local tries=0
  until [ "$tries" -ge 60 ]; do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1; then
      ok "Paperclip đang chạy."
      break
    fi
    tries=$((tries + 1)); sleep 5
  done
  if [ "$tries" -ge 60 ]; then
    warn "Chưa thấy /api/health sau 5 phút. Kiểm tra log:"
    warn "  cd $APP_DIR && docker compose --env-file $ENV_FILE -f $COMPOSE_FILE logs -f"
    return 1
  fi
  if command_exists caddy; then
    configure_caddy
  else
    warn "Chưa cài Caddy — bỏ qua proxy HTTPS. Cài khi cần: sudo bash $0 install"
  fi
  final_check
  print_summary
}

do_uninstall() {
  require_root
  warn "Gỡ cài Paperclip (giữ lại dữ liệu trong volume Docker \"paperclip-data\")..."
  if [ -d "$APP_DIR" ]; then
    (cd "$APP_DIR" && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down --rmi local 2>/dev/null || true)
  fi
  systemctl disable --now caddy >/dev/null 2>&1 || true
  rm -f "$CADDYFILE"
  info "Đã dừng container và gỡ Caddy proxy."
  info "Muốn xóa cả dữ liệu: docker volume rm paperclip-data; rm -rf $APP_DIR (không thể hoàn tác!)"
  ok "Xong."
}

# ──────────────────────────── Chạy chính ────────────────────────────
case "${1:-install}" in
  install) ;;
  update)    do_update; exit 0 ;;
  uninstall) do_uninstall; exit 0 ;;
  -h|--help) grep -E "^#" "$0" | grep -v '^#!' | sed 's/^#\s\{0,1\}//' | head -60; exit 0 ;;
  *) fail "Tham số không hợp lệ: $1 (dùng: install | update | uninstall)" ;;
esac

require_root
detect_os
detect_arch >/dev/null

info "Bắt đầu cài đặt Paperclip — domain: $DOMAIN, ổ đĩa: $APP_DIR"
check_dns || true
install_packages
install_docker
clone_repo
ask_api_key
write_env
start_paperclip
install_caddy
configure_caddy
configure_firewall
final_check
print_summary