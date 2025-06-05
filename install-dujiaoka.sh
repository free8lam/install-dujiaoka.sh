#!/bin/bash

set -euo pipefail

echo "=============================="
echo " 独角数自动发卡系统 一键安装脚本"
echo " 适用于 Ubuntu 20.04 / 22.04"
echo "=============================="

# 交互输入区
read -p "请输入站点域名（如 example.com）: " DOMAIN
read -p "请输入 MySQL root 密码（无则留空直接回车）: " MYSQL_ROOT_PASS
read -p "请输入独角数数据库名（建议 dujiaoka）: " DB_NAME
read -p "请输入独角数数据库用户名（建议 dujiaoka）: " DB_USER
read -p "请输入独角数数据库用户密码: " DB_PASS
read -p "请输入你的邮箱地址（用于申请SSL证书）: " SSL_EMAIL

# 变量
PHP_VERSION="8.3"
WP_PATH="/var/www/dujiaoka"
DUJIAOKA_VERSION="2.0.6-antibody"
DOWNLOAD_URL="https://github.com/assimon/dujiaoka/releases/download/${DUJIAOKA_VERSION}/${DUJIAOKA_VERSION}.tar.gz"

echo "🚀 开始系统更新升级..."
sudo apt update && sudo apt upgrade -y

echo "📦 安装基础环境: Nginx, MySQL, PHP${PHP_VERSION}及扩展..."
sudo apt install -y nginx mysql-server php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-curl php${PHP_VERSION}-gd php${PHP_VERSION}-intl php${PHP_VERSION}-mbstring php${PHP_VERSION}-soap php${PHP_VERSION}-xml php${PHP_VERSION}-zip php${PHP_VERSION}-imagick unzip wget curl certbot python3-certbot-nginx

echo "🔧 配置 MySQL root 用户密码及授权数据库..."
if [ -z "$MYSQL_ROOT_PASS" ]; then
  echo "检测到 MySQL root 密码为空，尝试无密码连接..."
  sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
else
  sudo mysql -uroot -p"${MYSQL_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

echo "📥 下载独角数自动发卡系统版本 ${DUJIAOKA_VERSION}..."
sudo mkdir -p "${WP_PATH}"
cd /tmp
wget -O dujiaoka.tar.gz "${DOWNLOAD_URL}" || { echo "❌ 下载失败，请检查网络和版本号"; exit 1; }

echo "📂 解压..."
sudo tar -zxvf dujiaoka.tar.gz -C /tmp || { echo "❌ 解压失败"; exit 1; }

# 解压后目录名称：dujiaoka-2.0.6-antibody
EXTRACTED_DIR="/tmp/dujiaoka-${DUJIAOKA_VERSION}"

if [ ! -d "$EXTRACTED_DIR" ]; then
  echo "❌ 解压目录不存在: $EXTRACTED_DIR"
  exit 1
fi

echo "📁 移动并重命名安装目录到 ${WP_PATH}..."
sudo rm -rf "${WP_PATH}"
sudo mv "$EXTRACTED_DIR" "${WP_PATH}"

echo "🔐 设置文件权限..."
sudo chown -R www-data:www-data "${WP_PATH}"
sudo find "${WP_PATH}" -type d -exec chmod 755 {} \;
sudo find "${WP_PATH}" -type f -exec chmod 644 {} \;

echo "🌐 配置 Nginx 虚拟主机..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"

sudo tee "$NGINX_CONF" > /dev/null <<EOF
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
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

echo "🔍 检查 Nginx 配置语法..."
sudo nginx -t || { echo "❌ Nginx 配置语法错误"; exit 1; }

echo "🔄 重载 Nginx..."
sudo systemctl reload nginx

echo "🔧 优化 PHP 配置参数..."
PHP_INI_PATH="/etc/php/${PHP_VERSION}/fpm/php.ini"
if [ -f "$PHP_INI_PATH" ]; then
    sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" "$PHP_INI_PATH"
    sudo sed -i "s/post_max_size = .*/post_max_size = 1024M/" "$PHP_INI_PATH"
    sudo sed -i "s/max_execution_time = .*/max_execution_time = 900/" "$PHP_INI_PATH"
    sudo sed -i "s/max_input_time = .*/max_input_time = 900/" "$PHP_INI_PATH"
fi

echo "🔄 重启 PHP-FPM 和 Nginx 服务..."
sudo systemctl restart php${PHP_VERSION}-fpm
sudo systemctl restart nginx

echo "🔐 申请并配置 SSL 证书（使用 Certbot）..."
sudo certbot --nginx -d "${DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email --redirect || echo "❌ SSL 证书申请失败，请确认域名DNS解析正确"

echo "🎉 安装完成！请访问 https://${DOMAIN} 进行后台初始化配置"
