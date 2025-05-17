#!/bin/bash
sudo pip install psutil selenium --break-system-packages >/dev/null 2>&1 &
sudo pkill -f chrom
sudo python /home/user/idx/keep.py 
sudo pkill -f chrom
existing=$(crontab -l 2>/dev/null)
# 添加 restart.sh（如果不存在）
if ! echo "$existing" | grep -q 'restart.sh'; then
  existing=$(echo "$existing"; echo "*/3 * * * * bash /home/user/idx/restart.sh >> /home/user/idx/restart.log 2>&1")
fi
echo "$existing" | crontab -
export ARGO_AUTH=${ARGO_AUTH:-''}
if ! grep -q "argotunnel" /etc/hosts; then
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
fi
# 定义服务列表（兼容旧版Bash的替代方案）
services=(
    "v1|/home/user/idx|./v1 -c ./config.yaml"
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
