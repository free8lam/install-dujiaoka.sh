#!/bin/bash

set -e

echo "=== 独角数自动发卡系统 2.0.6-antibody 一键安装脚本 ==="

# 交互输入用户配置
read -p "请输入网站域名（例如 p.golife.blog）: " DOMAIN
read -p "请输入用于申请 SSL 的邮箱地址: " SSL_EMAIL
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

APP_URL="https://$DOMAIN"

echo ""
echo "===== 配置信息确认 ====="
echo "域名: $DOMAIN"
echo "SSL邮箱: $SSL_EMAIL"
echo "数据库名: $DB_NAME"
echo "数据库用户: $DB_USER"
echo "数据库密码: (已隐藏)"
echo "安装目录: $INSTALL_DIR"
echo "PHP版本: $PHP_VER"
echo "独角数版本: $DUJIAOKA_VER"
echo ""

echo "开始安装，请耐心等待..."

# 安装必要组件
apt update && apt upgrade -y
apt install -y nginx mysql-server curl wget unzip certbot python3-certbot-nginx \
  php${PHP_VER}-fpm php-mysql php-curl php-gd php-intl php-mbstring php-soap php-xml php-zip php-bcmath composer

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
CREATE DATABASE IF NOT EXISTS \
