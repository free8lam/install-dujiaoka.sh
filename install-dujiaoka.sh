#!/usr/bin/env bash
# WordPress 修复优化版一键安装脚本（Ubuntu 24.04）
# 组件: Nginx + MariaDB + PHP-FPM + WordPress + Let's Encrypt SSL
# 功能增强: 修复端口、防火墙、Cron、PHP-FPM、SSL回退
# 运行: sudo bash install_fix.sh

set -euo pipefail

CONFIG="/etc/wp-autoinstall.conf"
WP_PATH="/var/www/wordpress"
DB_HOST="localhost"
NGINX_SITE="/etc/nginx/sites-available/wordpress"

# 交互/配置变量（初始为空，运行时赋值）
DOMAIN=""
TITLE=""
DB_NAME=""
DB_USER=""
DB_PASS=""
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_EMAIL=""
SSL_EMAIL=""
OPEN_PORTS="80 443"
PHP_VER=""
FPM_SERVICE=""

log() { echo -e "[INFO] $*"; }
error() { echo -e "[ERROR] $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "请以 root 或使用 sudo 执行。示例：sudo bash install_fix.sh"
    exit 1
  fi
  if ! grep -qi "Ubuntu 24.04" /etc/os-release; then
    error "检测到非 Ubuntu 24.04 系统。当前仅支持 Ubuntu 24.04。"
    exit 1
  fi
}

ask_value() { # ask_value "提示" 变量名 [是否密文(1/0)]
  local prompt="$1"; local varname="$2"; local is_secret="${3:-0}"; local val
  if [[ "$is_secret" == "1" ]]; then
      read -r -p "$prompt: " -s val; echo
  else
      read -r -p "$prompt: " val
  fi
  eval "$varname=\"${val}\""
}

input_config() {
  log "请输入首次安装所需信息："
  ask_value "数据库名称" DB_NAME
  ask_value "数据库用户名" DB_USER
  ask_value "数据库密码" DB_PASS 1
  ask_value "WordPress 网站域名（如 example.com）" DOMAIN
  read -r -p "WordPress 网站标题（可选，默认 WordPress）: " TITLE
  TITLE="${TITLE:-WordPress}"
  ask_value "WP 管理员用户名" ADMIN_USER
  ask_value "WP 管理员密码" ADMIN_PASS 1
  ask_value "WP 管理员邮箱" ADMIN_EMAIL
  ask_value "SSL 证书邮箱（用于 Certbot）" SSL_EMAIL

  read -r -p "请输入需要开放的端口（空格分隔，默认 80 443）: " ports
  OPEN_PORTS="${ports:-80 443}"
}

save_config() {
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
OPEN_PORTS="$OPEN_PORTS"
WP_PATH="$WP_PATH"
EOF
  chmod 600 "$CONFIG"
}

load_config() { # shellcheck disable=SC1090
  source "$CONFIG"
  DB_HOST="${DB_HOST:-localhost}"
  WP_PATH="${WP_PATH:-/var/www/wordpress}"
}

install_packages() {
  log "安装依赖包（Nginx、MariaDB、PHP、WP-CLI、Certbot）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx mariadb-server php-fpm php-mysql php-xml php-gd php-curl php-zip php-mbstring php-intl php-imagick curl wget zip unzip certbot python3-certbot-nginx
}

detect_php() {
  PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  FPM_SERVICE="php${PHP_VER}-fpm"
  log "检测到 PHP 版本：$PHP_VER，FPM 服务：$FPM_SERVICE"
}

apply_ini_value() {
  local file="$1"; local key="$2"; local value="$3"
  if grep -qE "^[; ]*${key}\s*=" "$file"; then
    sed -i -E "s|^[; ]*${key}\s*=.*|${key} = ${value}|g" "$file"
  else
    echo "${key} = ${value}" >> "$file"
  fi
}

tune_php() {
  local fpm_ini="/etc/php/${PHP_VER}/fpm/php.ini"
  local cli_ini="/etc/php/${PHP_VER}/cli/php.ini"
  for ini in "$fpm_ini" "$cli_ini"; do
    [[ -f "$ini" ]] || continue
    apply_ini_value "$ini" "upload_max_filesize" "1024M"
    apply_ini_value "$ini" "post_max_size" "1024M"
    apply_ini_value "$ini" "max_execution_time" "1800"
    apply_ini_value "$ini" "max_input_time" "1800"
    apply_ini_value "$ini" "memory_limit" "1024M"
  done
  systemctl restart "$FPM_SERVICE"
  systemctl enable "$FPM_SERVICE"
}

configure_nginx() {
  log "配置 Nginx 站点..."
  mkdir -p "$WP_PATH"
  cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${WP_PATH};
    index index.php index.html index.htm;
    client_max_body_size 1024M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires max;
        log_not_found off;
    }
}
EOF
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/wordpress
  if [[ -f /etc/nginx/sites-enabled/default ]]; then rm -f /etc/nginx/sites-enabled/default; fi
  nginx -t
  systemctl restart nginx
  systemctl enable nginx
}

configure_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      for p in $OPEN_PORTS; do
        ufw allow "$p/tcp" || true
      done
      ufw reload
    else
      log "UFW 未启用，跳过开放端口。"
    fi
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
  echo "$sql" | mysql -u root
  systemctl restart mariadb
  systemctl enable mariadb
}

install_wpcli() {
  if ! command -v wp >/dev/null 2>&1; then
    log "安装 WP-CLI..."
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
  fi
}

download_wordpress() {
  if [[ ! -f "${WP_PATH}/wp-settings.php" ]]; then
    log "下载 WordPress 最新版..."
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

setup_wordpress() {
  install_wpcli
  if [[ ! -f "${WP_PATH}/wp-config.php" ]]; then
    log "生成 wp-config.php..."
    wp config create --path="${WP_PATH}" --allow-root --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASS}" --dbhost="${DB_HOST}" --skip-check
    wp config set FS_METHOD "direct" --path="${WP_PATH}" --allow-root
  fi

  if wp core is-installed --path="${WP_PATH}" --allow-root >/dev/null 2>&1; then
    log "WordPress 已安装，更新站点地址..."
    wp option update siteurl "https://${DOMAIN}" --path="${WP_PATH}" --allow-root
    wp option update home "https://${DOMAIN}" --path="${WP_PATH}" --allow-root
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
      --skip-email
  fi
  chown -R www-data:www-data "${WP_PATH}"
}

setup_cron() {
  log "设置系统 Cron 以执行 WP Cron..."
  (crontab -l 2>/dev/null; echo "*/5 * * * * cd ${WP_PATH} && wp cron event run --due-now --allow-root >/dev/null 2>&1") | crontab -
  systemctl enable cron
  systemctl restart cron
}

obtain_ssl() {
  log "申请并安装 Let's Encrypt 证书..."
  if certbot --nginx --non-interactive --agree-tos -m "${SSL_EMAIL}" -d "${DOMAIN}" --redirect; then
    log "SSL 申请成功"
  else
    log "SSL 申请失败，暂时使用 HTTP 测试访问"
  fi
  systemctl reload nginx
}

summary() {
  echo "------------------------------------------------------------"
  echo "安装完成！请访问："
  echo "http://${DOMAIN}/ （HTTP 临时访问）"
  echo "管理员后台："
  echo "http://${DOMAIN}/wp-admin"
  echo "已开放端口: $OPEN_PORTS"
  echo "------------------------------------------------------------"
}

menu_existing() {
  echo "检测到已存在配置：$CONFIG"
  echo "请选择操作："
  echo "1) 使用现有配置继续部署"
  echo "2) 重新输入配置（更新并保存到配置文件）"
  echo "3) 仅重新部署（不修改数据库与 WordPress 文件）"
  echo "4) 完全重装并清空数据库（危险操作）"
  read -r -p "输入选项数字并回车: " choice
  case "$choice" in
    1)
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
      configure_ufw
      setup_cron
      obtain_ssl
      summary
      exit 0
      ;;
    4)
      load_config
      log "执行完全重装：清理数据库与文件..."
      mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
      mysql -u root -e "DROP USER IF EXISTS '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
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
setup_database
download_wordpress
configure_nginx
configure_ufw
setup_cron
setup_wordpress
obtain_ssl
summary

exit 0
