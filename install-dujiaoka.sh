#!/bin/bash

set -e

echo "===== 独角数自动发卡系统 一键安装脚本 ====="
echo "请确保服务器已正确解析域名，且端口已开放"

# 1. 读取用户输入
read -p "请输入网站域名（如 p.golife.blog）: " DOMAIN
read -p "请输入 MySQL root 密码（若为空请确保你可无密码登录）: " MYSQL_ROOT_PASS
read -p "请输入独角数数据库名（建议 dujiaoka）: " DB_NAME
read -p "请输入独角数数据库用户（建议 dujiaoka_user）: " DB_USER
read -p "请输入数据库用户密码: " DB_PASS
read -p "请输入 SSL 证书绑定邮箱（用于 Let's Encrypt）: " SSL_EMAIL

# 2. 安装系统依赖
echo "📦 更新系统 & 安装必备软件"
sudo apt update && sudo apt upgrade -y
sudo apt install -y nginx mysql-server php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-intl php8.3-mbstring php8.3-soap php8.3-xml php8.3-zip certbot python3-certbot-nginx unzip wget curl

# 3. 配置 MySQL
echo "🔧 配置 MySQL 数据库与用户"
if [ -z "$MYSQL_ROOT_PASS" ]; then
  echo "检测到 MySQL root 密码为空，尝试无密码连接"
  MYSQL_CMD="mysql -uroot"
else
  MYSQL_CMD="mysql -uroot -p${MYSQL_ROOT_PASS}"
fi

$MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
$MYSQL_CMD -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
$MYSQL_CMD -e "FLUSH PRIVILEGES;"

# 4. 自动获取独角数最新版本号
echo "🌐 获取独角数最新版本号"
LATEST_VERSION=$(curl -s https://api.github.com/repos/dujiaoka/dujiaoka/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
if [ -z "$LATEST_VERSION" ]; then
  echo "❌ 无法获取最新版本号，脚本退出"
  exit 1
fi
echo "检测到最新版本为: $LATEST_VERSION"

# 5. 下载独角数压缩包
DOWNLOAD_URL="https://github.com/dujiaoka/dujiaoka/releases/download/${LATEST_VERSION}/dujiaoka-${LATEST_VERSION}.zip"
echo "⬇️ 下载独角数安装包: $DOWNLOAD_URL"
wget -O dujiaoka.zip "$DOWNLOAD_URL"

# 6. 解压并部署
echo "📂 解压并部署独角数"
sudo mkdir -p /var/www/dujiaoka
sudo unzip -o dujiaoka.zip -d /var/www/dujiaoka/
sudo chown -R www-data:www-data /var/www/dujiaoka

# 7. 配置 Nginx 虚拟主机
echo "🌐 配置 Nginx"
cat > /etc/nginx/sites-available/${DOMAIN}.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/dujiaoka;
    index index.php index.html index.htm;

    client_max_body_size 1024M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/${DOMAIN}.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 8. 优化 PHP 配置
echo "⚙️ 优化 PHP 上传限制和执行时间"
PHP_INI="/etc/php/8.3/fpm/php.ini"
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" $PHP_INI
sudo sed -i "s/post_max_size = .*/post_max_size = 1024M/" $PHP_INI
sudo sed -i "s/max_execution_time = .*/max_execution_time = 900/" $PHP_INI
sudo sed -i "s/max_input_time = .*/max_input_time = 900/" $PHP_INI

sudo systemctl restart php8.3-fpm

# 9. 申请 SSL 证书（自动交互）
echo "🔐 使用 Certbot 为 ${DOMAIN} 申请 SSL 证书"
sudo certbot --nginx -d "${DOMAIN}" --email "${SSL_EMAIL}" --agree-tos --no-eff-email --redirect

# 10. 设置目录权限
sudo chown -R www-data:www-data /var/www/dujiaoka
sudo find /var/www/dujiaoka -type d -exec chmod 755 {} \;
sudo find /var/www/dujiaoka -type f -exec chmod 644 {} \;

echo "🎉 安装完成！请访问 https://${DOMAIN} 完成独角数后台初始化配置。"
