#!/bin/bash

set -e

echo "=== 独角数自动发卡系统 2.0.6-antibody 一键安装脚本 ==="

# 交互输入用户配置
read -p "请输入网站域名（例：p.golife.blog）: " DOMAIN
read -p "请输入 MySQL root 密码（无密码直接回车）: " MYSQL_ROOT_PASS
read -p "请输入独角数数据库名（默认dujiaoka）: " DB_NAME
DB_NAME=${DB_NAME:-dujiaoka}
read -p "请输入独角数数据库用户名（默认dujiaoka）: " DB_USER
DB_USER=${DB_USER:-dujiaoka}
read -p "请输入独角数数据库用户密码: " DB_PASS

INSTALL_DIR="/var/www/dujiaoka"
PHP_VER="8.3"
DUJIAOKA_VER="2.0.6-antibody"
DOWNLOAD_URL="https://github.com/assimon/dujiaoka/releases/download/2.0.6/2.0.6-antibody.tar.gz"

echo ""
echo "===== 配置信息确认 ====="
echo "域名: $DOMAIN"
echo "数据库名: $DB_NAME"
echo "数据库用户: $DB_USER"
echo "数据库密码: (已隐藏)"
echo "安装目录: $INSTALL_DIR"
echo "PHP版本: $PHP_VER"
echo "独角数版本: $DUJIAOKA_VER"
echo ""

echo "开始安装，请耐心等待..."

# 更新系统并安装必要组件
apt update && apt upgrade -y
apt install -y nginx mysql-server php${PHP_VER}-fpm php-mysql php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip unzip wget curl

# 配置 MySQL
echo "配置MySQL数据库和用户..."

if [ -z "$MYSQL_ROOT_PASS" ]; then
  echo "MySQL root无密码，尝试无密码登录"
  MYSQL_CMD="mysql"
else
  MYSQL_CMD="mysql -uroot -p${MYSQL_ROOT_PASS}"
  echo "检测MySQL root密码有效性..."
  echo "SELECT 1;" | $MYSQL_CMD >/dev/null 2>&1 || { echo "MySQL root密码错误，脚本终止！"; exit 1; }
fi

$MYSQL_CMD <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# 下载独角数系统
echo "下载独角数自动发卡系统版本 $DUJIAOKA_VER..."
mkdir -p $INSTALL_DIR
cd /tmp
wget -O dujiaoka.tar.gz "$DOWNLOAD_URL" || { echo "下载失败，请检查网络或版本号"; exit 1; }

# 解压文件
echo "解压安装文件..."
tar -zxf dujiaoka.tar.gz -C $INSTALL_DIR --strip-components=1

# 设置文件权限
echo "设置文件权限..."
chown -R www-data:www-data $INSTALL_DIR
find $INSTALL_DIR -type d -exec chmod 755 {} \;
find $INSTALL_DIR -type f -exec chmod 644 {} \;

# 配置 Nginx
echo "配置Nginx..."
cat >/etc/nginx/sites-available/$DOMAIN.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $INSTALL_DIR;
    index index.php index.html index.htm;

    client_max_body_size 1024M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/

nginx -t || { echo "Nginx 配置错误，安装终止！"; exit 1; }
systemctl reload nginx

# 优化PHP配置
echo "优化PHP配置..."
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" $PHP_INI
sed -i "s/post_max_size = .*/post_max_size = 1024M/" $PHP_INI
sed -i "s/max_execution_time = .*/max_execution_time = 900/" $PHP_INI
sed -i "s/max_input_time = .*/max_input_time = 900/" $PHP_INI

systemctl restart php${PHP_VER}-fpm
systemctl restart nginx

echo "安装完成！请访问 http://$DOMAIN 进行后台初始化配置。"
