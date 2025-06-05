#!/bin/bash

# 独角数自动发卡系统一键安装脚本
# 适用环境：Ubuntu 20.04/22.04，PHP 8.3，Nginx，MySQL
# 版本：dujiaoka 2.0.6-antibody

set -e

echo "=== 独角数自动发卡系统安装脚本 ==="

# 交互输入
read -p "请输入网站域名（如 example.com）: " DOMAIN
read -p "请输入MySQL root密码（如果没有请留空直接回车）: " MYSQL_ROOT_PASSWORD
read -p "请输入新建数据库名称（例如 dujiaoka）: " DB_NAME
read -p "请输入数据库用户名: " DB_USER
read -sp "请输入数据库用户密码: " DB_PASSWORD
echo
read -p "请输入你的邮箱地址（用于申请SSL证书）: " SSL_EMAIL

# 软件版本和路径
DUJIAOKA_VERSION="2.0.6-antibody"
DUJIAOKA_DOWNLOAD_URL="https://github.com/assimon/dujiaoka/releases/download/${DUJIAOKA_VERSION}/${DUJIAOKA_VERSION}.tar.gz"
WEB_ROOT="/var/www/dujiaoka"
PHP_VERSION="8.3"

echo "🔄 更新系统..."
sudo apt update && sudo apt upgrade -y

echo "📦 安装必要软件包..."
sudo apt install -y nginx mysql-server php${PHP_VERSION}-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip unzip wget curl certbot python3-certbot-nginx

echo "🛠️ 配置 MySQL..."
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  # 无密码连接
  sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
  sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
else
  sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
  sudo mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
fi

echo "📥 下载独角数自动发卡系统版本 ${DUJIAOKA_VERSION}..."
mkdir -p /tmp/dujiaoka_install
cd /tmp/dujiaoka_install
wget -q --show-progress "${DUJIAOKA_DOWNLOAD_URL}" -O dujiaoka.tar.gz || { echo "❌ 下载失败，请检查网络和版本号"; exit 1; }
tar -zxf dujiaoka.tar.gz

echo "📂 部署文件到网站根目录 ${WEB_ROOT} ..."
sudo mkdir -p ${WEB_ROOT}
sudo cp -r * ${WEB_ROOT}/
sudo chown -R www-data:www-data ${WEB_ROOT}
sudo find ${WEB_ROOT} -type d -exec chmod 755 {} \;
sudo find ${WEB_ROOT} -type f -exec chmod 644 {} \;

echo "🌐 配置 Nginx 虚拟主机..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
sudo tee ${NGINX_CONF} > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
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

# 启用站点配置
sudo ln -sf ${NGINX_CONF} /etc/nginx/sites-enabled/
sudo nginx -t || { echo "❌ Nginx 配置测试失败，请检查！"; exit 1; }
sudo systemctl reload nginx

echo "🔐 申请并安装 SSL 证书..."
sudo certbot --nginx -d "${DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email --non-interactive || echo "❌ SSL 证书申请失败，请确认域名已正确解析"

echo "⚙️ 优化 PHP 配置参数..."
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" $PHP_INI
sudo sed -i "s/post_max_size = .*/post_max_size = 1024M/" $PHP_INI
sudo sed -i "s/max_execution_time = .*/max_execution_time = 900/" $PHP_INI
sudo sed -i "s/max_input_time = .*/max_input_time = 900/" $PHP_INI

echo "🔄 重启 PHP 和 Nginx 服务..."
sudo systemctl restart php${PHP_VERSION}-fpm
sudo systemctl restart nginx

echo "🎉 安装完成！请访问 https://${DOMAIN} 进行独角数自动发卡系统的后台初始化配置"
