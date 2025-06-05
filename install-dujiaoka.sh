#!/bin/bash

set -e

echo "==== 独角数自动发卡系统一键安装脚本（极致优化版） ===="
echo "适用于 Ubuntu 20.04/22.04，自动安装 PHP 8.3 环境及相关依赖"

# 输入配置参数，避免隐私泄漏
read -p "请输入数据库名（示例：dujiaoka）: " DB_NAME
read -p "请输入数据库用户名（示例：dujiaoka）: " DB_USER
read -s -p "请输入数据库密码: " DB_PASSWORD
echo
read -p "请输入 MySQL root 用户密码（如果没有可留空）: " MYSQL_ROOT_PASSWORD
read -p "请输入绑定的域名（示例：p.golife.blog）: " DOMAIN

WEB_ROOT="/var/www/dujiaoka"

echo "更新系统软件包..."
sudo apt update && sudo apt upgrade -y

echo "安装 Nginx、MySQL、PHP 8.3 及必要 PHP 扩展..."
sudo apt install -y nginx mysql-server php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-intl php8.3-mbstring php8.3-soap php8.3-xml php8.3-zip php8.3-imagick unzip wget curl

echo "配置 MySQL Root 密码（如提供）..."
if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
  sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;"
fi

echo "创建数据库和用户..."
MYSQL_CMD="mysql -uroot"
if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
  MYSQL_CMD="mysql -uroot -p${MYSQL_ROOT_PASSWORD}"
fi

$MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
$MYSQL_CMD -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

echo "下载独角数自动发卡系统..."
sudo mkdir -p $WEB_ROOT
cd /tmp
wget -O dujiaoka.zip https://github.com/dujiaoka/dujiaoka/releases/latest/download/dujiaoka.zip
unzip -o dujiaoka.zip -d dujiaoka_temp
sudo cp -r dujiaoka_temp/. $WEB_ROOT

echo "设置目录权限，确保安全"
sudo chown -R www-data:www-data $WEB_ROOT
sudo find $WEB_ROOT -type d -exec chmod 755 {} \;
sudo find $WEB_ROOT -type f -exec chmod 644 {} \;
# storage 目录为写权限
sudo chmod -R 775 $WEB_ROOT/storage
sudo chown -R www-data:www-data $WEB_ROOT/storage

echo "配置 Nginx 虚拟主机..."
sudo tee /etc/nginx/sites-available/$DOMAIN.conf >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $WEB_ROOT/public;
    index index.php index.html index.htm;

    client_max_body_size 1024M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

echo "启用 Nginx 站点配置并测试..."
sudo ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

echo "极致优化 PHP 配置参数..."

PHP_INI="/etc/php/8.3/fpm/php.ini"
if [ -f "$PHP_INI" ]; then
    sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1024M/" $PHP_INI
    sudo sed -i "s/post_max_size = .*/post_max_size = 1024M/" $PHP_INI
    sudo sed -i "s/max_execution_time = .*/max_execution_time = 900/" $PHP_INI
    sudo sed -i "s/max_input_time = .*/max_input_time = 900/" $PHP_INI
    sudo sed -i "s/memory_limit = .*/memory_limit = 512M/" $PHP_INI
fi

echo "重启 PHP-FPM 和 Nginx 服务..."
sudo systemctl restart php8.3-fpm
sudo systemctl enable php8.3-fpm
sudo systemctl restart nginx
sudo systemctl enable nginx

echo "配置防火墙，开放 80 端口..."
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 80/tcp
  sudo ufw reload
fi

echo "安装完成！请访问 http://$DOMAIN 进行后续配置。"
