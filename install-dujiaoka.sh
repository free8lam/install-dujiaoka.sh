#!/bin/bash
set -e

echo "=== 独角数自动发卡系统 2.0.6-antibody 一键安装脚本（稳定修复版）==="

# 用户交互输入
read -p "请输入网站域名（）: " DOMAIN
read -p "请输入用于申请 SSL 的邮箱: " SSL_EMAIL
read -p "请输入 MySQL root 密码（无密码直接回车）: " MYSQL_ROOT_PASS
read -p "请输入独角数数据库名（默认 dujiaoka）: " DB_NAME
DB_NAME=${DB_NAME:-dujiaoka}
read -p "请输入独角数数据库用户名（默认 dujiaoka）: " DB_USER
DB_USER=${DB_USER:-dujiaoka}
read -p "请输入独角数数据库用户密码: " DB_PASS

INSTALL_DIR="/var/www/dujiaoka"
PHP_VER="8.3"
DUJIAOKA_VER="2.0.6-antibody"
DOWNLOAD_URL="https://github.com/assimon/dujiaoka/releases/download/2.0.6/2.0.6-antibody.tar.gz"

# 显示确认
echo ""
echo "===== 配置信息确认 ====="
echo "域名: $DOMAIN"
echo "SSL邮箱: $SSL_EMAIL"
echo "数据库名: $DB_NAME"
echo "数据库用户: $DB_USER"
echo "数据库密码: (已隐藏)"
echo "安装目录: $INSTALL_DIR"
echo "PHP版本: $PHP_VER"
echo ""

# 安装环境
apt update && apt upgrade -y
apt install -y nginx mysql-server curl wget unzip git certbot python3-certbot-nginx \
    php${PHP_VER}-fpm php-mysql php-curl php-gd php-intl php-mbstring php-soap \
    php-xml php-zip php-bcmath php-cli php-common php-tokenizer

# MySQL 配置
echo "配置 MySQL 数据库..."
if [ -z "$MYSQL_ROOT_PASS" ]; then
  MYSQL_CMD="mysql"
else
  MYSQL_CMD="mysql -uroot -p${MYSQL_ROOT_PASS}"
  echo "SELECT 1;" | $MYSQL_CMD >/dev/null 2>&1 || { echo "MySQL root密码错误"; exit 1; }
fi

$MYSQL_CMD <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# 下载独角数
echo "下载独角数程序..."
mkdir -p $INSTALL_DIR
cd /tmp
curl -L -o dujiaoka.tar.gz -H "User-Agent: Mozilla/5.0" "$DOWNLOAD_URL"
tar -zxf dujiaoka.tar.gz
cp -r dujiaoka/* $INSTALL_DIR

# 权限设置
chown -R www-data:www-data $INSTALL_DIR
find $INSTALL_DIR -type d -exec chmod 755 {} \;
find $INSTALL_DIR -type f -exec chmod 644 {} \;

# 创建 Laravel .env
echo "生成 Laravel 配置文件..."
cp $INSTALL_DIR/.env.example $INSTALL_DIR/.env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" $INSTALL_DIR/.env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" $INSTALL_DIR/.env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" $INSTALL_DIR/.env

# 配置 nginx
echo "配置 Nginx..."
cat >/etc/nginx/sites-available/$DOMAIN.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $INSTALL_DIR/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ /.well-known/acme-challenge/ {
        allow all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# SSL申请（IPv4模式）
echo "申请 SSL（IPv4 强制）..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m "$SSL_EMAIL" --preferred-challenges http --no-eff-email --force-renewal || {
    echo "SSL申请失败，将继续使用HTTP"
}

# 替换为 HTTPS 配置
if [ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    echo "切换为 HTTPS 配置..."
    cat >/etc/nginx/sites-available/$DOMAIN.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root $INSTALL_DIR/public;
    index index.php index.html;

    client_max_body_size 1024M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF
    nginx -t && systemctl reload nginx
fi

# Laravel 初始化
echo "初始化 Laravel..."
cd $INSTALL_DIR
php artisan key:generate
php artisan config:cache
php artisan migrate --force

chown -R www-data:www-data $INSTALL_DIR

# PHP 优化
echo "优化 PHP 参数..."
INI_PATH="/etc/php/${PHP_VER}/fpm/php.ini"
sed -i "s/post_max_size = .*/post_max_size = 1024M/" $INI_PATH
sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" $INI_PATH
sed -i "s/max_execution_time = .*/max_execution_time = 900/" $INI_PATH
sed -i "s/max_input_time = .*/max_input_time = 900/" $INI_PATH

systemctl restart php${PHP_VER}-fpm
systemctl restart nginx

echo ""
echo "✅ 安装完成！请访问以下地址初始化网站："
echo "👉 https://$DOMAIN"
echo ""
