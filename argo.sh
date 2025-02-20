#!/bin/bash

# 定义工作目录
WORK_DIR="/root/cloudflared"
SERVICE_FILE="/etc/systemd/system/argo.service"

# 安装功能
install_argo() {
  echo "正在创建工作目录..."
  mkdir -p $WORK_DIR
  cd $WORK_DIR || exit 1

  # 获取最新版本号
  echo "正在获取最新版本信息..."
  VERSION=$(curl -sL https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep tag_name | cut -d'"' -f4)
  if [ -z "$VERSION" ]; then
    echo "错误：无法获取版本号！"
    exit 1
  fi

  # 检测系统架构
  ARCH=$(uname -m)
  case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
  esac

  # 下载对应版本
  DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/${VERSION}/cloudflared-linux-${ARCH}"
  echo "正在下载 cloudflared (${VERSION}-${ARCH})..."
  curl -# -L $DOWNLOAD_URL -o cloudflared || {
    echo "下载失败！"
    exit 1
  }

  # 赋予执行权限
  chmod +x cloudflared

  # 用户输入验证
  read -p "请输入 Argo 域名: " ARGO_DOMAIN
  read -p "请输入 Argo Token: " ARGO_TOKEN

  if [[ -z "$ARGO_DOMAIN" || -z "$ARGO_TOKEN" ]]; then
    echo "错误：域名和 Token 不能为空！"
    exit 1
  fi

  # 生成 systemd 服务文件
  cat > $SERVICE_FILE <<EOF
[Unit]
Description=Cloudflare Argo Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$WORK_DIR/cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

  # 重载 systemd 并启动服务
  systemctl daemon-reload
  systemctl enable argo
  systemctl start argo

  # 输出状态信息
  echo -e "\n服务部署完成！"
  echo -e "状态检查: systemctl status argo"
  echo -e "日志查看: journalctl -u argo -f"
}

# 卸载功能
uninstall_argo() {
  echo "正在停止并禁用 Argo 服务..."
  systemctl stop argo
  systemctl disable argo

  echo "正在删除服务文件..."
  rm -f $SERVICE_FILE
  systemctl daemon-reload

  echo "正在删除工作目录及其内容..."
  rm -rf $WORK_DIR

  echo "Argo 服务已成功卸载。"
}

# 主菜单
while true; do
  echo "请选择操作："
  echo "1. 安装 Argo 服务"
  echo "2. 卸载 Argo 服务"
  echo "0. 退出"
  read -p "请输入数字: " CHOICE

  case $CHOICE in
    1)
      install_argo
      ;;
    2)
      uninstall_argo
      ;;
    0)
      echo "退出脚本。"
      exit 0
      ;;
    *)
      echo "无效选择，请重新输入！"
      ;;
  esac
done
