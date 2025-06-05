#!/bin/bash

echo "🧠 开始安装独角数自动发卡系统 (Dujiaoka)..."

# ==== 交互式参数输入 ====
read -p "请输入用于部署的主域名（例如：shop.example.com）: " DOMAIN
read -p "请输入用于申请 SSL 的邮箱: " SSL_EMAIL
read -p "请输入数据库名称: " DB_NAME
read -p "请输入数据库用户名: " DB_USER
read -sp "请输入数据库密码: " DB_PASSWORD && echo
read -sp "请输入 MySQL root 密码（若无则为空，直接回车）: " MYSQL_ROOT_PASSWORD && echo

DUJIAO_PATH="/var/www/dujiaoka"
PHP_VERSION="8.1"

# ==== 更新系统 & 安装依赖 ====
echo "🔧 安装依赖组件..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y nginx mariadb-server php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip unzip git curl composer php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-gd

# ==== 配置 MySQL 数据库 ====
echo "🛠️ 创建数据库..."
if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
    MYSQL_CMD="mysql -uroot -p$MYSQL_ROOT_PASSWORD"
else
    MYSQL_CMD="mysql -uroot"
fi

$MYSQL_CMD <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# ==== 下载独角数 ====
echo "⬇️ 下载 Dujiaoka..."
sudo rm -rf ${DUJIAO_PATH}
sudo git clone https://github.com/assimon/dujiaoka.git ${DUJIAO_PATH}
cd ${DUJIAO_PATH}
sudo composer install -o

# ==== 配置环境文件 ====
echo "⚙️ 配置 .env..."
sudo cp .env.example .env

sudo sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
sudo sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
sudo sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" .env

# ==== 设置文件权限 ====
echo "🔐 设置权限..."
sudo chown -R www-data:www-data ${DUJIAO_PATH}
sudo chmod -R 755 ${DUJIAO_PATH}/

# ==== 配置 Laravel ====
echo "🔧 初始化 Laravel..."
sudo php artisan dujiao:install
sudo php artisan key:generate

# ==== 配置 Nginx ====
echo "🌐 配置 Nginx..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
sudo tee ${NGINX_CONF} > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${DUJIAO_PATH}/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# 启用配置
sudo ln -s ${NGINX_CONF} /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# ==== 申请 SSL 证书 ====
echo "🔐 申请 SSL..."
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d ${DOMAIN} --email ${SSL_EMAIL} --agree-tos --no-eff-email

# ==== 重启服务 ====
sudo systemctl restart php${PHP_VERSION}-fpm
sudo systemctl restart nginx

echo "🎉 安装完成！请访问 https://${DOMAIN} 初始化后台信息"