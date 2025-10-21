#!/usr/bin/env bash
# WordPress 一键自动安装脚本（Ubuntu 24.04）
# 组件: Nginx + MariaDB + PHP-FPM + WordPress + Let's Encrypt SSL
# 运行: sudo bash install.sh

set -euo pipefail

CONFIG="/etc/wp-autoinstall.conf"
DB_HOST="localhost"

# 交互/配置变量（初始为空）
DOMAIN=""
TITLE=""
DB_NAME=""
DB_USER=""
DB_PASS=""
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_EMAIL=""
SSL_EMAIL=""
WP_PATH=""
OPEN_PORTS="80,443"

PHP_VER=""
FPM_SERVICE=""

log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*"; }
error() { echo -e "[ERROR] $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "请以 root 或使用 sudo 执行。示例：sudo bash install.sh"
    exit 1
  fi
  if [[ -f /etc/os-release ]]; then
    if ! grep -qi "ubuntu" /etc/os-release; then
      warn "未检测到 Ubuntu 系列发行版。脚本主要在 Ubuntu 上测试。"
    fi
  fi
}

ask_value() {
  local prompt="$1"; local varname="$2"; local is_secret="${3:-0}"; local default="${4:-}"
  local val
  if [[ "$is_secret" == "1" ]]; then
    read -r -p "$prompt${default:+ [$default]}: " -s val; echo
  else
    read -r -p "$prompt${default:+ [$default]}: " val
  fi
  val="${val:-$default}"
  eval "$varname=\"${val}\""
}

input_config() {
  log "请输入首次安装所需信息："
  ask_value "要开放的端口（逗号或空格分隔，默认 80,443）" OPEN_PORTS 0 "80,443"
  ask_value "数据库名称" DB_NAME
  ask_value "数据库用户名" DB_USER
  ask_value "数据库密码（输入时不可见）" DB_PASS 1
  ask_value "WordPress 网站域名（如 example.com）" DOMAIN
  ask_value "WordPress 网站标题（可选，默认 WordPress）" TITLE 0 "WordPress"
  ask_value "WP 管理员用户名" ADMIN_USER
  ask_value "WP 管理员密码（输入时不可见）" ADMIN_PASS 1
  ask_value "WP 管理员邮箱" ADMIN_EMAIL
  ask_value "SSL 证书邮箱（用于 Certbot）" SSL_EMAIL
  if [[ -z "${WP_PATH}" ]]; then
    if [[ -n "${DOMAIN}" ]]; then
      WP_PATH="/var/www/${DOMAIN}"
    else
      WP_PATH="/var/www/wordpress"
    fi
  fi
}

save_config() {
  log "保存配置到 ${CONFIG}（权限 600）"
  cat > "$CONFIG" <<EOF
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
DB_HOST="$DB_HOST"
DOMAIN="$DOMAIN"
TITLE="$TITLE"
ADMIN_USER="$ADMIN_USER"
ADMIN_PASS="$ADMIN_PASS"
ADMIN_EMAIL="$ADMIN_EMAIL"
SSL_EMAIL="$SSL_EMAIL"
WP_PATH="$WP_PATH"
OPEN_PORTS="$OPEN_PORTS"
EOF
  chmod 600 "$CONFIG"
}

load_config() { # shellcheck disable=SC1090
  if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG"
    DB_HOST="${DB_HOST:-localhost}"
    WP_PATH="${WP_PATH:-/var/www/wordpress}"
    OPEN_PORTS="${OPEN_PORTS:-80,443}"
  else
    error "配置文件不存在：${CONFIG}"
    exit 1
  fi
}

backup_file_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%s)"
    log "已备份 ${f} 为 ${f}.bak.$(date +%s)"
  fi
}

install_packages() {
  log "更新 apt 源并安装所需软件包（Nginx, MariaDB, PHP, WP-CLI, Certbot 等）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y

  apt-get install -y nginx mariadb-server php-fpm php-mysql php-xml php-gd php-curl php-zip curl wget zip unzip certbot python3-certbot-nginx rsync dnsutils

  install_wpcli_if_missing
}

install_wpcli_if_missing() {
  if ! command -v wp >/dev/null 2>&1; then
    log "安装 WP-CLI..."
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
  fi
}

detect_php() {
  if command -v php >/dev/null 2>&1; then
    PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    # find FPM service
    if systemctl list-units --full -all -t service | grep -q "php${PHP_VER}-fpm.service"; then
      FPM_SERVICE="php${PHP_VER}-fpm"
    else
      FPM_SERVICE="$(systemctl list-units --type service --no-legend | awk '{print $1}' | grep -E 'php[0-9]+\.[0-9]+-fpm.service' | head -n1 | sed 's/.service$//')"
      if [[ -n "$FPM_SERVICE" ]]; then
        PHP_VER="$(echo "$FPM_SERVICE" | sed -E 's/php([0-9]+\.[0-9]+)-fpm/\1/')"
      fi
    fi
    if [[ -z "$PHP_VER" || -z "$FPM_SERVICE" ]]; then
      error "未能检测到 PHP 或 PHP-FPM 服务，请确认 PHP 已正确安装。"
      exit 1
    fi
    log "检测到 PHP 版本: ${PHP_VER}, FPM 服务: ${FPM_SERVICE}"
  else
    error "PHP 未安装或不可用。请先运行 install_packages 安装 PHP。"
    exit 1
  fi
}

apply_ini_value() {
  local file="$1"; local key="$2"; local value="$3"
  if grep -qE "^[[:space:]]*;?[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*;?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|g" "$file"
  else
    echo "${key} = ${value}" >> "$file"
  fi
}

tune_php() {
  detect_php
  local fpm_ini="/etc/php/${PHP_VER}/fpm/php.ini"
  local cli_ini="/etc/php/${PHP_VER}/cli/php.ini"
  log "调整 PHP 配置（upload_max_filesize/post_max_size/memory_limit 等）..."
  for ini in "$fpm_ini" "$cli_ini"; do
    if [[ -f "$ini" ]]; then
      apply_ini_value "$ini" "upload_max_filesize" "1024M"
      apply_ini_value "$ini" "post_max_size" "1024M"
      apply_ini_value "$ini" "max_execution_time" "1800"
      apply_ini_value "$ini" "max_input_time" "1800"
      apply_ini_value "$ini" "memory_limit" "1024M"
    fi
  done

  if [[ -n "$FPM_SERVICE" ]]; then
    log "重启并启用 ${FPM_SERVICE}"
    systemctl restart "$FPM_SERVICE" || true
    systemctl enable "$FPM_SERVICE" || true
  fi
}

configure_nginx() {
  log "配置 Nginx 站点..."
  mkdir -p "${WP_PATH}"
  local site_conf="/etc/nginx/sites-available/wordpress"
  backup_file_if_exists "$site_conf"

  cat > "$site_conf" <<'NGINX_EOF'
server {
    listen 80;
    server_name __DOMAIN__;
    root __WPPATH__;
    index index.php index.html index.htm;
    client_max_body_size 1024M;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__FPM_SOCK__;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires max;
        log_not_found off;
    }
}
NGINX_EOF

  # 替换占位符
  local fpm_sock="/run/php/php${PHP_VER}-fpm.sock"
  sed -i "s|__DOMAIN__|${DOMAIN}|g" "$site_conf"
  sed -i "s|__WPPATH__|${WP_PATH}|g" "$site_conf"
  sed -i "s|__FPM_SOCK__|${fpm_sock}|g" "$site_conf"

  ln -sf "$site_conf" /etc/nginx/sites-enabled/wordpress
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t
  systemctl restart nginx
  systemctl enable nginx
}

open_ports() {
  local raw="$1"
  raw="${raw// /,}"
  IFS=',' read -ra ports <<< "$raw"
  declare -A seen
  local to_open=()
  for p in "${ports[@]}"; do
    p="${p// /}"
    if [[ -n "$p" && -z "${seen[$p]:-}" ]]; then
      seen[$p]=1
      to_open+=("$p")
    fi
  done

  if command -v ufw >/dev/null 2>&1; then
    if ufw status verbose | grep -qi "Status: active"; then
      log "UFW 已启用，正在开放端口：${to_open[*]}"
      for p in "${to_open[@]}"; do
        ufw allow "${p}/tcp" || true
      done
      ufw reload || true
    else
      warn "UFW 未启用。请在防火墙/云控制台手动开放端口: ${to_open[*]}"
    fi
  else
    warn "未检测到 UFW。请手动确保端口 ${to_open[*]} 已开放（云面板或 iptables）。"
  fi
}

setup_database() {
  log "创建数据库与用户（MariaDB）..."
  local sql="
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
"
  echo "$sql" | sudo mysql
  systemctl restart mariadb || true
  systemctl enable mariadb || true
}

download_wordpress() {
  if [[ ! -f "${WP_PATH}/wp-settings.php" ]]; then
    log "下载并部署 WordPress 最新版..."
    wget -qO /tmp/wordpress.tar.gz https://wordpress.org/latest.tar.gz
    tar -xf /tmp/wordpress.tar.gz -C /tmp/
    rsync -a /tmp/wordpress/ "${WP_PATH}/"
    chown -R www-data:www-data "${WP_PATH}"
    find "${WP_PATH}" -type d -exec chmod 755 {} \;
    find "${WP_PATH}" -type f -exec chmod 644 {} \;
  else
    log "已检测到 WordPress 文件，跳过下载。"
  fi
}

# 修复可能存在的错误 define（例如 define('FS_METHOD', direct);）
fix_wp_constants_in_config() {
  local cfg="${WP_PATH}/wp-config.php"
  if [[ -f "$cfg" ]]; then
    # 如果存在未加引号的 direct 常量，替换为带引号的
    if grep -q "FS_METHOD" "$cfg" 2>/dev/null; then
      sed -i "s/define\s*(\s*'FS_METHOD'\s*,\s*direct\s*)/define('FS_METHOD','direct')/g" "$cfg" || true
      # 更稳妥写法：确保格式为 define('FS_METHOD', 'direct');
      sed -i "s/define\s*(\s*'FS_METHOD'\s*,\s*'direct'\s*)/define('FS_METHOD', 'direct')/g" "$cfg" || true
    fi
  fi
}

setup_wordpress() {
  install_wpcli_if_missing
  if [[ ! -f "${WP_PATH}/wp-config.php" ]]; then
    log "生成 wp-config.php..."
    wp config create --path="${WP_PATH}" --allow-root --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASS}" --dbhost="${DB_HOST}" --skip-check || {
      error "wp config create 失败，请检查 DB 信息。"
      exit 1
    }
  fi

  # 使用 WP-CLI 写入常量（更安全）
  # FS_METHOD 应为字符串 'direct'
  if wp config get FS_METHOD --path="${WP_PATH}" --allow-root >/dev/null 2>&1; then
    log "FS_METHOD 已存在于 wp-config.php，尝试修正为字符串格式..."
    # 覆盖为常量字符串
    wp config set FS_METHOD 'direct' --path="${WP_PATH}" --allow-root --type=constant || true
  else
    wp config set FS_METHOD 'direct' --path="${WP_PATH}" --allow-root --type=constant || true
  fi

  # 其他建议常量（可选）
  wp config set WP_MEMORY_LIMIT '512M' --path="${WP_PATH}" --allow-root --type=constant || true
  wp config set WP_MAX_MEMORY_LIMIT '1024M' --path="${WP_PATH}" --allow-root --type=constant || true

  # 兼容用 sed 修复可能存在的错误写法（兜底）
  fix_wp_constants_in_config

  if wp core is-installed --path="${WP_PATH}" --allow-root >/dev/null 2>&1; then
    log "WordPress 已安装，更新站点 URL 为 https://${DOMAIN}"
    wp option update siteurl "https://${DOMAIN}" --path="${WP_PATH}" --allow-root || true
    wp option update home "https://${DOMAIN}" --path="${WP_PATH}" --allow-root || true
  else
    log "执行 WordPress 安装并创建管理员..."
    wp core install \
      --path="${WP_PATH}" \
      --allow-root \
      --url="https://${DOMAIN}" \
      --title="${TITLE}" \
      --admin_user="${ADMIN_USER}" \
      --admin_password="${ADMIN_PASS}" \
      --admin_email="${ADMIN_EMAIL}" \
      --skip-email || {
        error "wp core install 执行失败，请查看上方错误信息并修复后重试。"
        exit 1
      }
  fi

  chown -R www-data:www-data "${WP_PATH}"
}

preflight_checks_for_certbot() {
  if ! command -v host >/dev/null 2>&1 && ! command -v dig >/dev/null 2>&1; then
    warn "系统缺少 'host' 或 'dig' 工具，无法自动验证域名解析。建议安装 dnsutils（apt install -y dnsutils）。"
  fi

  if command -v host >/dev/null 2>&1; then
    if ! host "${DOMAIN}" >/dev/null 2>&1; then
      warn "域名 ${DOMAIN} 似乎无法解析到 IP。Certbot 申请将可能失败。请确保 DNS A/AAAA 记录指向本服务器。"
    else
      log "域名解析检查通过（存在 DNS 记录）。"
    fi
  fi

  if ss -ltn | grep -q ':80 '; then
    log "检测到本机 80 端口在监听（可能由 nginx）。"
  else
    warn "未检测到 80 端口监听。Certbot HTTP 验证可能失败。"
  fi
}

obtain_ssl() {
  if [[ -z "${SSL_EMAIL}" || -z "${DOMAIN}" ]]; then
    warn "SSL 邮箱或域名为空，跳过证书申请"
    return
  fi
  preflight_checks_for_certbot
  log "使用 certbot --nginx 申请 Let's Encrypt 证书（非交互模式）..."
  if certbot --nginx --non-interactive --agree-tos -m "${SSL_EMAIL}" -d "${DOMAIN}" --redirect; then
    log "证书申请成功并已配置 HTTPS 重定向。"
  else
    warn "certbot 申请证书失败。请检查 DNS、80/443 端口或 certbot 日志后手动运行 certbot。"
  fi
  systemctl reload nginx || true
}

summary() {
  echo "------------------------------------------------------------"
  echo "安装流程已完成！"
  echo "网站地址: https://${DOMAIN}/"
  echo "后台登录: https://${DOMAIN}/wp-admin"
  echo "数据库: ${DB_NAME} @ ${DB_HOST} (用户: ${DB_USER})"
  echo "管理员: ${ADMIN_USER}  （请妥善保存密码）"
  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    echo "SSL 证书: 已安装（Let's Encrypt）"
  else
    echo "SSL 证书: 未检测到（请检查 certbot 运行日志或 DNS 指向）"
  fi
  echo "配置文件路径: ${CONFIG}（包含敏感信息，请妥善删除或备份）"
  echo "------------------------------------------------------------"
}

menu_existing() {
  echo "检测到已存在配置文件：$CONFIG"
  echo "请选择操作："
  echo "1) 使用现有配置继续部署（默认）"
  echo "2) 重新输入配置（更新并保存）"
  echo "3) 仅重新部署服务与 SSL（不修改数据库与 WP 文件）"
  echo "4) 完全重装并清空数据库与站点（危险）"
  read -r -p "输入选项数字并回车: " choice
  case "$choice" in
    1|"")
      load_config
      ;;
    2)
      input_config
      save_config
      ;;
    3)
      load_config
      install_packages
      detect_php
      tune_php
      configure_nginx
      open_ports "${OPEN_PORTS}"
      obtain_ssl
      summary
      exit 0
      ;;
    4)
      load_config
      log "执行完全重装：清理数据库与文件..."
      echo "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" | sudo mysql || true
      echo "DROP USER IF EXISTS '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" | sudo mysql || true
      rm -rf "${WP_PATH}"
      input_config
      save_config
      ;;
    *)
      echo "无效选项，默认使用现有配置继续。"
      load_config
      ;;
  esac
}

# 主流程
require_root

if [[ -f "$CONFIG" ]]; then
  menu_existing
else
  input_config
  save_config
fi

install_packages
detect_php
tune_php
open_ports "${OPEN_PORTS}"
setup_database
download_wordpress
configure_nginx
setup_wordpress
obtain_ssl
summary

exit 0
