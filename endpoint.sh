#!/bin/bash
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "脚本所在目录: $WORK_DIR"
ARCH=$(uname -m) && FILE_INFO=()
if [ "$ARCH" == "arm" ] || [ "$ARCH" == "arm64" ] || [ "$ARCH" == "aarch64" ]; then
    ARCH="arm64"
elif [ "$ARCH" == "amd64" ] || [ "$ARCH" == "x86_64" ] || [ "$ARCH" == "x86" ]; then
	#cat /proc/cpuinfo | grep -q avx2 && IS_AMD64V3=v3
    ARCH="amd64"
else
    echo "不支持的平台架构: $ARCH"
    exit 1
fi
echo "当前架构为 $ARCH"

curl -L -sS -o "${WORK_DIR}/endpoint" "https://github.com/yyyr-otz/script/releases/download/linux-$ARCH/endpoint"
check() { curl -$1 -m3 -s http://google.com >/dev/null; }
check 4 && IPV4=1 && curl -L -sS -o "${WORK_DIR}/ipv4" "https://github.com/yyyr-otz/script/releases/download/ip/warp-ipv4" || IPV4==0
check 6 && IPV6=1 && curl -L -sS -o "${WORK_DIR}/ipv6" "https://github.com/yyyr-otz/script/releases/download/ip/warp-ipv6" || IPV6==0
[ "$IPV4$IPV6" = "01" ] && STACK=-6 || STACK=-4
echo "IPV4=$IPV4,IPV6=$IPV6,STACK=$STACK"

best_endpoint() {
  if [[ -e ${WORK_DIR}/endpoint && -e ${WORK_DIR}/ipv4 ]]; then
    ${WORK_DIR}/endpoint -file ${WORK_DIR}/ipv4 -max 1000 -output ${WORK_DIR}/endpoint_result >/dev/null 2>&1
    ENDPOINT4=$(grep -sE '[0-9]+[ ]+ms$' ${WORK_DIR}/endpoint_result | awk -F, 'NR==1 {print $1}')
  fi
  if [[ -e ${WORK_DIR}/endpoint && -e ${WORK_DIR}/ipv4 ]]; then
    ${WORK_DIR}/endpoint -file ${WORK_DIR}/ipv4 -max 1000 -output ${WORK_DIR}/endpoint_result >/dev/null 2>&1
    ENDPOINT6=$(grep -sE '[0-9]+[ ]+ms$' ${WORK_DIR}/endpoint_result | awk -F, 'NR==1 {print $1}')
  fi
  [ "$IPV4" = "1" ] && endpoint4=$ENDPOINT4 || endpoint4=$ENDPOINT6
  [ "$IPV6" = "1" ] && endpoint6=$ENDPOINT6 || endpoint6=$ENDPOINT4
  echo "endpoint4:$endpoint4,endpoint6:$endpoint6"
}
best_endpoint
