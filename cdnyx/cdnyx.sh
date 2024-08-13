#!/bin/bash
#若目录不存在则创建
if [ ! -d "/root/cdnyx" ]; then mkdir /root/cdnyx/
fi
"api_dir"="/root/cdnyx"
#下载本脚本
curl -sL -o "$api_dir/cdnyx.sh" https://raw.githubusercontent.com/yyyr-otz/script/master/cdnyx.sh
#下载api列表
curl -sL -o "$api_dir/api.txt" https://raw.githubusercontent.com/yyyr-otz/script/master/api.txt
#读取api列表
# 读取输入文件的每一行
while IFS= read -r url; do
  # 使用curl下载文件并重命名
  curl -sL -o "$api_dir/$url"
  wait 3
done < "$api_dir/api.txt"
#修改文件
wait 10
sed -i 's/$/#bestCF/' "$api_dir/api_15_bestcf"
sed -i 's/$/#bestRP/' "$api_dir/api_16_bestproxy"
cat "$api_dir/*best*"
wait 3
#合并文件
find "$api_dir/" -name "api_*" | xargs sed 'a\' > "$api_dir/merge.txt"
rm -f "$api_dir/aip_*"
#修改文件
sed -i 's/:443//g' "$api_dir/merge.txt"
sed -i 's/@Warp_Key//g' "$api_dir/merge.txt"
sed -i '/404/d' "$api_dir/merge.txt"
sed -i '/DOCTYPE/d' "$api_dir/merge.txt"
echo "优选完成!"
