#!/usr/bin/env bash

# Cloudflared 多模式管理脚本
# 支持：Token认证 / JSON配置文件 两种模式

export LANG=C.UTF-8
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[0;33m'
plain='\033[0m'

SERVICE_NAME="cloudflared"
BIN_PATH="/usr/local/bin/cloudflared"
CONFIG_DIR="/etc/cloudflared"
CREDENTIAL_FILE="${CONFIG_DIR}/credentials.json"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 配置文件模板
generate_config() {
  local mode=$1
  local token=$2

  echo -e "${green}生成配置文件...${plain}"
  [ ! -d "${CONFIG_DIR}" ] && mkdir -p "${CONFIG_DIR}"

  # 生成主配置文件
  cat > "${CONFIG_DIR}/config.yml" << EOF
# 运行模式: token (CLI参数) 或 credentials (JSON文件)
tunnel: <TUNNEL_ID>
EOF

  # 模式专属配置
  case $mode in
    token)
      echo "credentials-file: /dev/null" >> "${CONFIG_DIR}/config.yml"
      ;;
    json)
      echo "credentials-file: ${CREDENTIAL_FILE}" >> "${CONFIG_DIR}/config.yml"
      [ ! -f "$CREDENTIAL_FILE" ] && echo -e "${red}错误: 找不到凭证文件${plain}" && return 1
      ;;
  esac

  # 生成服务文件
  cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} tunnel --config ${CONFIG_DIR}/config.yml run ${token:+--token $token}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
}

# 输入验证
validate_input() {
  local mode=$1
  local input=$2

  case $mode in
    token)
      # 增强的JWT格式验证
      if ! [[ "$input" =~ ^([A-Za-z0-9_-]+\.){2}[A-Za-z0-9_-]+$ ]]; then
        echo -e "${red}令牌格式错误 (需为xxxxx.yyyyy.zzzzz结构)${plain}"
        return 1
      fi
      
      # 检查header是否可以解码
      local header=$(echo "$input" | cut -d. -f1 | base64url -d 2>/dev/null)
      if ! jq -e . <<< "$header" &> /dev/null; then
        echo -e "${red}令牌头部解码失败${plain}"
        return 1
      fi

      # 检查必要字段
      if ! jq -e '.iss == "cloudflare-tunnel" and .sub == "Tunnel" ' <<< "$header" &> /dev/null; then
        echo -e "${red}令牌类型不匹配 (非Cloudflare Tunnel Token)${plain}"
        return 1
      }
      ;;

    json)
      [ -f "$input" ] || { echo -e "${red}文件不存在: $input${plain}"; return 1; }
      jq -e 'has("AccountTag") and has("TunnelSecret") and has("TunnelID")' "$input" >/dev/null || {
        echo -e "${red}JSON缺少必要字段 (需含AccountTag/TunnelSecret/TunnelID)${plain}"
        return 1
      }
      ;;
  esac
}

# 安装流程
install() {
  echo -e "\n${green}选择认证方式:${plain}"
  select mode in "Token认证" "JSON配置文件"; do
    case $REPLY in
      1) mode="token"; break ;;
      2) mode="json"; break ;;
      *) echo -e "${red}无效选择${plain}";;
    esac
  done

  case $mode in
    token)
      read -p "请输入 Cloudflare Tunnel Token: " token
      validate_input token "$token" || exit 1
      generate_config token "$token"
      ;;

    json)
      read -p "输入 JSON 文件路径 (默认: argo.json): " json_file
      json_file=${json_file:-argo.json}
      validate_input json "$json_file" || exit 1
      cp "$json_file" "$CREDENTIAL_FILE"
      generate_config json
      ;;
  esac

  systemctl daemon-reload
  systemctl enable $SERVICE_NAME
  systemctl start $SERVICE_NAME
  echo -e "\n${green}配置完成!${plain}"
}

# 状态检查
status() {
  echo -e "${green}服务状态:${plain}"
  systemctl status $SERVICE_NAME --no-pager

  echo -e "\n${green}隧道信息:${plain}"
  $BIN_PATH tunnel list
}

# 切换模式
switch_mode() {
  uninstall keep_config
  install
}

# 卸载
uninstall() {
  local keep_config=${1:-false}

  systemctl stop $SERVICE_NAME 2>/dev/null
  systemctl disable $SERVICE_NAME 2>/dev/null
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload

  [ "$keep_config" = "false" ] && {
    rm -rf "${CONFIG_DIR}"
    echo -e "${green}已删除所有配置文件${plain}"
  }

  [ -x "$BIN_PATH" ] && {
    rm -f "$BIN_PATH"
    echo -e "${green}已移除二进制文件${plain}"
  }
}

# 管理菜单
menu() {
  echo -e "
  Cloudflared 多模式管理

  ${green}1.${plain} 安装/切换模式
  ${green}2.${plain} 查看状态
  ${green}3.${plain} 启动服务
  ${green}4.${plain} 停止服务
  ${green}5.${plain} 重启服务
  ${green}6.${plain} 完全卸载
  ${green}7.${plain} 退出
  "
  read -p "请输入选项 (1-7): " choice

  case $choice in
    1) install ;;
    2) status ;;
    3) systemctl start $SERVICE_NAME ;;
    4) systemctl stop $SERVICE_NAME ;;
    5) systemctl restart $SERVICE_NAME ;;
    6) uninstall ;;
    7) exit 0 ;;
    *) echo -e "${red}无效选项${plain}" ;;
  esac
}

# 初始化检查
init_check() {
  [ "$(id -u)" != "0" ] && {
    echo -e "${red}请使用 root 权限运行${plain}"
    exit 1
  }

  command -v jq >/dev/null || apt-get install -y jq
}

# 主流程
init_check
while true; do
  menu
  echo -e "\n按回车键继续..."
  read -n 1 -s
done
