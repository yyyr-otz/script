#!/bin/bash
export NAME=${NAME:-'-IDX'}
export FILE_PATH=${FILE_PATH:-'/home/user/idx'} 
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}
export ARGO_AUTH=${ARGO_AUTH:-''}
export NEZHA_UUID=${NEZHA_UUID:-$(echo "$NAME"| sha1sum | awk '{OFS="-"; print substr($1,1,8), substr($1,9,4), "5" substr($1,14,3), substr($1,17,1) substr($1,18,3), substr($1,21,12)}')}
export UUID=${UUID:-''}
export NEZHA_SERVER=${NEZHA_SERVER:-''}
export NEZHA_PORT=${NEZHA_PORT:-''}
export NEZHA_KEY=${NEZHA_KEY:-''}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export TARGET_IDX_NAME=${TARGET_IDX_NAME:-''}
[ ! -d "${FILE_PATH}" ] && mkdir -p "${FILE_PATH}"
mkdir -p "${FILE_PATH}/xalist/data"

down_file() {
	echo "开始下载文件..."
	ALIST_URL="https://oec-argo.yyyrspeed.nyc.mn/xalist/d/%E6%9C%AC%E5%9C%B0/root/etc/xalist/data"
	IP_URL="https://github.com/yyyr-otz/script/releases/download/ip"
	ARCH=$(uname -m) && FILE_INFO=()
if [ "$ARCH" == "arm" ] || [ "$ARCH" == "arm64" ] || [ "$ARCH" == "aarch64" ]; then
    ARCH="arm64"
	BASE_URL="https://github.com/yyyr-otz/script/releases/download/linux-$ARCH"
elif [ "$ARCH" == "amd64" ] || [ "$ARCH" == "x86_64" ] || [ "$ARCH" == "x86" ]; then
	#cat /proc/cpuinfo | grep -q avx2 && IS_AMD64V3=v3
    ARCH="amd64"
	BASE_URL="https://github.com/yyyr-otz/script/releases/download/linux-$ARCH"
else
    echo "不支持的平台架构: $ARCH"
    exit 1
fi
echo "当前架构为 $ARCH"
FILE_INFO=("$BASE_URL/xray xray" "$BASE_URL/cfd cfd" "$BASE_URL/argo argo" "$BASE_URL/endpoint endpoint" "$IP_URL/warp-ipv4 ipv4" "$IP_URL/warp-ipv6 ipv6" "$ALIST_URL/data.db xalist/data/data.db" "$BASE_URL/xalist xalist/xalist" "$ALIST_URL/data.db-shm xalist/data/data.db-shm" "$ALIST_URL/data.db-wal xalist/data/data.db-wal" "$ALIST_URL/config.json xalist/data/config.json")
if [ -n "$NEZHA_PORT" ]; then
    FILE_INFO+=("$BASE_URL/v0 v0")
else
    FILE_INFO+=("$BASE_URL/v1 v1")
    NEZHA_TLS=$(case "${NEZHA_SERVER##*:}" in 443|8443|2096|2087|2083|2053) echo -n true;; *) echo -n false;; esac)
	if [ ! -e "${FILE_PATH}/agent.yaml" ]; then
    cat > "${FILE_PATH}"/agent.yaml << EOF
client_secret: ${NEZHA_KEY}
debug: false
disable_auto_update: true
disable_command_execute: true
disable_force_update: true
disable_nat: true
disable_send_query: false
gpu: false
insecure_tls: true
ip_report_period: 4800
report_delay: 4
server: ${NEZHA_SERVER}
skip_connection_count: true
skip_procs_count: true
temperature: false
tls: ${NEZHA_TLS}
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: ${NEZHA_UUID}
EOF
    fi
  fi
  for entry in "${FILE_INFO[@]}"; do
    URL=$(echo "$entry" | cut -d ' ' -f 1)
    NEW_FILENAME=$(echo "$entry" | cut -d ' ' -f 2)
    FILENAME="${FILE_PATH}/$NEW_FILENAME"
    if [ -e "$FILENAME" ]; then
        echo -e "\e[1;32m$FILENAME 已存在,跳过下载\e[0m"
    else
        curl -L -sS -o "$FILENAME" "$URL"
        echo -e "\e[1;32m正在下载 $FILENAME\e[0m"
		chmod 777 ${FILE_PATH}/${NEW_FILENAME}
		chmod +x ${FILE_PATH}/${NEW_FILENAME}
    fi
  done
}

IPV4=1
IPV6=0

best_endpoint() {
  echo "正在优选best_endpoint..."
  if [[ -e ${FILE_PATH}/endpoint && -e ${FILE_PATH}/ipv4 &&  "$IPV4" = "1"  ]]; then
    ${FILE_PATH}/endpoint -file ${FILE_PATH}/ipv4 -max 1000 -output ${FILE_PATH}/endpoint_result >/dev/null 2>&1
    ENDPOINT4=$(grep -sE '[0-9]+[ ]+ms$' ${FILE_PATH}/endpoint_result | awk -F, 'NR==1 {print $1}')
  fi
  if [[ -e ${FILE_PATH}/endpoint && -e ${FILE_PATH}/ipv6 &&  "$IPV6" = "1" ]]; then
    ${FILE_PATH}/endpoint -file ${FILE_PATH}/ipv6 -max 1000 -output ${FILE_PATH}/endpoint_result >/dev/null 2>&1
    ENDPOINT6=$(grep -sE '[0-9]+[ ]+ms$' ${FILE_PATH}/endpoint_result | awk -F, 'NR==1 {print $1}')
  fi
  [ "$IPV4" = "1" ] && endpoint4=$ENDPOINT4 || endpoint4=$ENDPOINT6
  [ "$IPV6" = "1" ] && endpoint6=$ENDPOINT6 || endpoint6=$ENDPOINT4
  echo "endpoint4:$endpoint4,endpoint6:$endpoint6" | tee -a /tmp/warp_endpoint
  #endpointip4="162.159.192.1:2408" && endpointip6="[2606:4700:d0::a29f:c001]:2408"
}

generate_config() {
  echo "开始初始化config"
  if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
    echo -e "\e[1;32mARGO_DOMAIN 或 ARGO_AUTH 变量为空，使用临时隧道\e[0m"
    return
  fi
  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    echo $ARGO_AUTH > ${FILE_PATH}/tunnel.json
    cat > ${FILE_PATH}/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$ARGO_AUTH")
credentials-file: ${FILE_PATH}/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    echo -e "\e[1;32m当前使用的是token,请在cloudflare后台设置隧道端口为${ARGO_PORT}\e[0m"
  fi
  if ! grep -q "argotunnel" /etc/hosts; then
    # 追加新的域名映射
    sudo tee -a /etc/hosts > /dev/null <<EOF
127.0.0.1 region1.v2.argotunnel.com
127.0.0.1 region2.v2.argotunnel.com
127.0.0.1 us-region1.v2.argotunnel.com
127.0.0.1 us-region2.v2.argotunnel.com
::1 region1.v2.argotunnel.com
::1 region2.v2.argotunnel.com
::1 us-region1.v2.argotunnel.com
::1 us-region2.v2.argotunnel.com
EOF
    echo "追加argotunnel域名映射"
  else
    echo "argotunnel域名映射已存在"
  fi
  cat > ${FILE_PATH}/ips-cfd.txt << EOF
198.41.192.0/24
198.41.193.0/24
198.41.194.0/24
198.41.195.0/24
198.41.196.0/24
198.41.197.0/24
198.41.198.0/24
198.41.199.0/24
198.41.200.0/24
EOF
  cat > ${FILE_PATH}/config.json << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": ${ARGO_PORT}, "listen": "127.0.0.1", "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
        "decryption": "none",
        "fallbacks": [
		   {"alpn": "","dest": "3001","name": "","path": "","xver": 0},
           {"alpn": "","dest": "3002","name": "","path": "/ws","xver": 0}
        ]
      },
      "streamSettings": { "network": "tcp" }
    },
	{
      "tag": "xh", "port": "3001", "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "none", "xhttpSettings": { "headers": {},"host": "","mode": "auto","path": "/xh" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "tag": "ws","port": "3002", "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/ws" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    }
  ],
  "dns": { "servers": ["https://8.8.8.8/dns-query","https://1.1.1.1/dns-query"] },
  "outbounds": [ {"protocol": "freedom", "tag": "direct" },{"protocol": "blackhole","tag": "block" },
    {"tag":"WARP","protocol":"wireguard",
    "settings":{
    "secretKey":"IetBDorm9i0JFnBfizX4cBZwMs31a8E0754DZEitoLs=",
    "address":["172.16.0.2/32","2606:4700:cf1:1000::1/128"],
    "peers":[{"publicKey":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=","allowedIPs":["0.0.0.0/0","::/0"],"endpoint":"$endpoint4"}],
    "reserved":[139,239,136],"mtu":1380}}
  ],
  "routing": {"domainStrategy": "IPOnDemand",
    "rules": [
      {"type": "field","network": "tcp,udp","outboundTag": "WARP"}
    ]
  }
}
EOF
}

run() {
  echo "开始检查进程"
# 定义服务列表（兼容旧版Bash的替代方案）
services=(
    "v1|/home/user/idx|./v1 -c ./agent.yaml"
    "cfd|/home/user/idx|./cfd -num 20 -task 200 -file ./ips-cfd.txt"
    "argo|/home/user/idx|./argo --edge-ip-version auto --protocol http2 tunnel run --token ${ARGO_AUTH}"
    "xray|/home/user/idx|./xray run -c ./config.json"
    "xalist|/home/user/idx/xalist|./xalist server"
)

# 遍历所有服务
for service in "${services[@]}"; do
    # 使用IFS分割字符串
    IFS='|' read -r proc_name work_dir cmd <<< "$service"

    # 检查进程是否在运行（精确匹配命令开头）
    if ! pgrep -f "^${cmd%% *}" >/dev/null 2>&1; then
        echo "启动 ${proc_name}..."
        # 使用子shell隔离进程
        cd "$work_dir" && (nohup $cmd >/dev/null 2>&1 &)
        sleep 1  # 避免并发启动冲突
    else
        echo "${proc_name} 已经在运行"
    fi
done
pkill -f "(start.sh|restart.sh|sleep)" >/dev/null 2>&1 &
pgrep -f "(start.sh|restart.sh|sleep)" | xargs kill -9 >/dev/null 2>&1 &
  echo "所有进程检查完成"
}

get_argodomain() {
  if [[ -n $ARGO_AUTH ]]; then
    echo "$ARGO_DOMAIN"
  else
    local retry=0
    local max_retries=6
    local argodomain=""
    while [[ $retry -lt $max_retries ]]; do
      ((retry++))
      argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${FILE_PATH}/boot.log") 
      if [[ -n $argodomain ]]; then
        break
      fi
      sleep 1
    done
    echo "$argodomain"
  fi
}

keep_idx() {
sudo pip install psutil selenium --break-system-packages >/dev/null 2>&1 &
sudo pkill -f chrom
[ -e "${FILE_PATH}/keep.py " ] || bash <(curl -Ls https://raw.githubusercontent.com/yyyr-otz/script/main/idx/keep.sh)
sudo python "${FILE_PATH}"/keep.py 
sudo pkill -f chrom	
}

rm -rf /home/user/idx/*.log >/dev/null 2>&1 &
(crontab -l 2>/dev/null || true; echo "*/3 * * * * bash /home/user/idx/idx.sh restart >> /home/user/idx/restart.log 2>&1") | sort -u | crontab -

if [ "$1" == "restart" ]; then
	keep_idx
	run
	exit 0
fi

keep_idx
down_file
wait
[ ! -e "/tmp/warp_endpoint" ] && best_endpoint
wait
generate_config
wait
run
argodomain=$(get_argodomain)
echo -e "\e[1;32mArgo域名:\e[1;35m${argodomain}\e[0m"
echo -e "\e[1;96m运行结束!\e[0m"
