#!/bin/bash
#若目录不存在则创建
if [ ! -d "/root/cdnyx" ]; then mkdir /root/cdnyx/
fi
#清空目录
find /root/cdnyx -mindepth 1 ! -name 'cdnyx.*' -exec rm -rf {} +
#下载本脚本
curl -sL -o /root/cdnyx/cdnyx.sh https://raw.githubusercontent.com/yyyr-otz/script/master/cdnyx/cdnyx.sh
#下载api列表
curl -sL -o /root/cdnyx/api.txt https://raw.githubusercontent.com/yyyr-otz/script/master/cdnyx/api.txt
#读取api列表
# 读取输入文件的每一行
while IFS= read -r url; do
  # 使用curl下载文件并重命名
  curl -sL -o /root/cdnyx/$url
  sleep 3
done < /root/cdnyx/api.txt
#修改文件
sleep 10
sed -i 's/\(.*[0-9]\).*/\1#bestCF/' /root/cdnyx/api_15_bestcf
sed -i 's/\(.*[0-9]\).*/\1#bestRP/' /root/cdnyx/api_15_bestproxy
sleep 3
#合并文件
find /root/cdnyx/ -name "api_*" | xargs sed 'a\' > "/root/cdnyx/cdnyx.txt"
rm -f /root/cdnyx/aip_*
#修改文件
sed -i 's/:443//g' /root/cdnyx/cdnyx.txt
sed -i 's/@Warp_Key//g' /root/cdnyx/cdnyx.txt
sed -i '/404/d' /root/cdnyx/cdnyx.txt
sed -i '/DOCTYPE/d' /root/cdnyx/cdnyx.txt
echo "\n优选完成\n"
