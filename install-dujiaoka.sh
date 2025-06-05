#!/bin/bash
# 独角数自动发卡系统一键安装脚本（Ubuntu + PHP8.3 + Nginx + MySQL + HTTPS）
# 重要隐私信息安装时交互输入，避免脚本明文存储
# 版本：2.0.6-antibody

set -e

echo "🚀 欢迎使用独角数自动发卡系统安装脚本"
echo "请确保已将域名正确解析到本服务器"
echo

# 交互输入区（敏感信息）
read -rp "请输入站点域名（例如: p.golife.blog）: " DOMAIN
read -rp "请输入 MySQL root 用户密码（无密码请留空）: " MYSQL_ROOT_PASS
read -rp "请输入独角数数据库名（默认dujiaoka）: " DB_NAME
DB_NAME=${DB_NAME:-dujiaoka}
read -rp "请输入独角数数据库用户名（默认dujiaoka）: " DB_USER
DB_USER=${DB_USER:-dujiaoka}
read -rp "请输入独角数数据库密码: " DB_PASS

# PHP 版本
PHP_VERSION="8.3"
WP_PATH="/var/www/${DOMAIN}"

echo
echo "🛠️ 开始安装依赖和配置环境..."

# 更新系统
sudo apt update && sudo apt upgrade -y

# 安装 Nginx、MySQL、PHP 及必备扩展
sudo apt install -y nginx mysql-server php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-curl php${PHP_VERSION}-gd php${PHP_VERSION}-intl php${PHP_VERSION}-mbstring php${PHP_VERSION}-soap php${PHP_VERSION}-xml php${PHP_VERSION}-zip unzip wget curl certbot python3-certbot-nginx

# 启动并设置服务开机启动
sudo systemctl enable nginx
sudo systemctl enable mysql
sudo systemctl enable php${PHP_VERSION}-fpm
sudo systemctl start nginx
sudo systemctl start mysql
sudo systemctl start php${PHP_VERSION}-fpm

echo
echo "🔧 配置 MySQL 数据库和用户..."

if [ -z "$MYSQL_ROOT_PASS" ]; then
    # 无root密码，直接操作
    sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
else
    sudo mysql -u root -p"${MYSQL_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

echo
echo "⬇️ 下载独角数自动发卡系统最新版本（2.0.6-antibody）..."

INSTALL_DIR="/var/www/${DOMAIN}"
sudo mkdir -p "${INSTALL_DIR}"
sudo chown "$USER":"$USER" "${INSTALL_DIR}"
cd /tmp
wget -c https://github.com/assimon/dujiaoka/releases/download/2.0.6/2.0.6-antibody.tar.gz -O dujiaoka.tar.gz

echo "🗜️ 解压并部署独角数程序..."
tar -zxf dujiaoka.tar.gz -C "${INSTALL_DIR}"
sudo chown -R www-data:www-data "${INSTALL_DIR}"

echo
echo "🌐 配置 Nginx 虚拟主机..."

NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
sudo bash -c "cat > ${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${INSTALL_DIR};
    index index.php index.html index.htm;

    client_max_body_size 1024M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

sudo ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/

echo
echo "⚙️ 优化 PHP 配置参数..."

PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" "$PHP_INI"
sudo sed -i "s/post_max_size = .*/post_max_size = 1024M/" "$PHP_INI"
sudo sed -i "s/max_execution_time = .*/max_execution_time = 900/" "$PHP_INI"
sudo sed -i "s/max_input_time = .*/max_input_time = 900/" "$PHP_INI"

echo
echo "🔐 设置文件权限..."

sudo chown -R www-data:www-data "${INSTALL_DIR}"
sudo find "${INSTALL_DIR}" -type d -exec chmod 755 {} \;
sudo find "${INSTALL_DIR}" -type f -exec chmod 644 {} \;

echo
echo "🔐 申请 SSL 证书..."

sudo certbot --nginx -d "${DOMAIN}" --agree-tos --no-eff-email --email "admin@${DOMAIN}" || echo "⚠️ SSL 申请失败，请确认域名已正确解析"

echo
echo "🔄 重启服务..."

sudo systemctl reload nginx
sudo systemctl restart php${PHP_VERSION}-fpm

echo
echo "🎉 安装完成！请访问 https://${DOMAIN} 进行后台初始化配置。"
