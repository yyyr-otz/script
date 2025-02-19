#!/usr/bin/env bash

# Cloudflared 多模式管理脚本
# 支持：Token认证 / JSON配置文件 两种模式
# 版本: 2.1

export LANG=C.UTF-8
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[0;33m'
plain='\033[0m'

SERVICE_NAME="cloudflared"
BIN_PATH="/usr/local/bin/cloudflared"
CONFIG_DIR="/etc/cloudflared"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 获取最新版本
get_latest_version() {
    echo -e "${green}正在获取最新版本...${plain}"
    LATEST_VERSION=$(curl -sL https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep tag_name | cut -d'"' -f4)
    [ -z "$LATEST_VERSION" ] && echo -e "${red}错误: 无法获取最新版本号${plain}" && return 1
    echo -e "最新稳定版: ${yellow}${LATEST_VERSION}${plain}"
}

# 检测系统架构
get_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       echo -e "${red}不支持的架构: ${ARCH}${plain}" && exit 1 ;;
    esac
}

# 安装依赖
install_deps() {
    if ! command -v curl &> /dev/null; then
        echo -e "${yellow}安装 curl...${plain}"
        apt-get update >/dev/null && apt-get install -y curl >/dev/null
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${yellow}安装 jq...${plain}"
        apt-get install -y jq >/dev/null
    fi

    if ! command -v base64 &> /dev/null; then
        echo -e "${yellow}安装 coreutils...${plain}"
        apt-get install -y coreutils >/dev/null
    fi
}

# 解码验证 Token
validate_token() {
    local token=$1
    if ! decoded=$(echo "$token" | base64 -d 2>/dev/null); then
        echo -e "${red}Token 解码失败${plain}"
        return 1
    fi

    if ! jq -e 'has("a") and has("t") and has("s")' <<< "$decoded" &> /dev/null; then
        echo -e "${red}Token 缺少必要字段 (需要包含 a/t/s)${plain}"
        return 1
    fi

    return 0
}

# 生成配置文件
generate_config() {
    local mode=$1
    local token=$2

    [ ! -d "${CONFIG_DIR}" ] && mkdir -p "${CONFIG_DIR}"

    # 公共配置部分
    cat > "${CONFIG_DIR}/config.yml" << EOF
logfile: /var/log/cloudflared.log
metrics: 0.0.0.0:4000
no-autoupdate: true
EOF

    # 模式专属配置
    case $mode in
        token)
            local decoded=$(echo "$token" | base64 -d)
            local tunnel_id=$(jq -r '.t' <<< "$decoded")
            echo "tunnel: ${tunnel_id}" >> "${CONFIG_DIR}/config.yml"
            ;;
        json)
            echo "credentials-file: ${CONFIG_DIR}/credentials.json" >> "${CONFIG_DIR}/config.yml"
            ;;
    esac

    # 服务文件配置
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} tunnel --config ${CONFIG_DIR}/config.yml run${token:+ --token $token}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
}

# 安装 Cloudflared
install_cloudflared() {
    get_latest_version || return 1
    ARCH=$(get_arch)
    DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/${LATEST_VERSION}/cloudflared-linux-${ARCH}"

    echo -e "${green}下载地址: ${yellow}${DOWNLOAD_URL}${plain}"
    if ! curl -sL ${DOWNLOAD_URL} -o ${BIN_PATH}; then
        echo -e "${red}下载失败! 请检查网络连接${plain}"
        return 1
    fi

    chmod +x ${BIN_PATH}
    echo -e "${green}已安装至: ${yellow}${BIN_PATH}${plain}"
}

# 安装流程
do_install() {
    install_deps
    install_cloudflared || return

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
            while true; do
                read -p "请输入 Cloudflare Tunnel Token: " token
                if validate_token "$token"; then
                    break
                else
                    echo -e "${yellow}请重新输入有效的 Token...${plain}"
                fi
            done
            generate_config token "$token"
            ;;

        json)
            while true; do
                read -p "输入 JSON 文件路径 (默认: ./credentials.json): " json_file
                json_file=${json_file:-credentials.json}
                if [ ! -f "$json_file" ]; then
                    echo -e "${red}文件不存在: $json_file${plain}"
                elif ! jq -e . "$json_file" >/dev/null 2>&1; then
                    echo -e "${red}JSON 格式无效${plain}"
                else
                    cp "$json_file" "${CONFIG_DIR}/credentials.json"
                    chmod 600 "${CONFIG_DIR}/credentials.json"
                    break
                fi
            done
            generate_config json
            ;;
    esac

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME >/dev/null 2>&1
    systemctl start $SERVICE_NAME

    echo -e "\n${green}安装完成!${plain}"
    echo -e "查看状态: ${yellow}systemctl status ${SERVICE_NAME}${plain}"
    echo -e "日志文件: ${yellow}tail -f /var/log/cloudflared.log${plain}"
}

# 卸载
do_uninstall() {
    systemctl stop $SERVICE_NAME 2>/dev/null
    systemctl disable $SERVICE_NAME 2>/dev/null
    rm -f ${SERVICE_FILE}
    rm -f ${BIN_PATH}
    rm -rf ${CONFIG_DIR}
    systemctl daemon-reload
    echo -e "${green}已完全卸载${plain}"
}

# 显示菜单
show_menu() {
    echo -e "
  Cloudflared 管理脚本

 ${green}1.${plain} 安装/配置
 ${green}2.${plain} 完全卸载
 ${green}3.${plain} 启动服务
 ${green}4.${plain} 停止服务
 ${green}5.${plain} 重启服务
 ${green}6.${plain} 查看状态
 ${green}7.${plain} 退出
"
    read -p "请输入操作编号 (1-7): " choice
    case $choice in
        1) do_install ;;
        2) do_uninstall ;;
        3) systemctl start $SERVICE_NAME ;;
        4) systemctl stop $SERVICE_NAME ;;
        5) systemctl restart $SERVICE_NAME ;;
        6) systemctl status $SERVICE_NAME ;;
        7) exit 0 ;;
        *) echo -e "${red}无效输入，请重新选择${plain}" ;;
    esac
}

# 主入口
if [[ $EUID -ne 0 ]]; then
    echo -e "${red}请使用 root 用户运行此脚本${plain}"
    exit 1
fi

while true; do
    show_menu
    echo -e "\n按回车键返回菜单..."
    read -n 1 -s
done
