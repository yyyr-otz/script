touch /root/cdnyx
wget -O /root/cdnyx https://raw.githubusercontent.com/yyyr-otz/script/master/cdnyx.sh
curl -sL -o /root/cdnyx/api_15_bestcf https://ipdb.api.030101.xyz/?type=bestcf&country=true&down=true &
curl -sL -o /root/cdnyx/api_16_bestproxy https://ipdb.api.030101.xyz/?type=bestproxy&country=true&down=true &
curl -sL -o /root/cdnyx/api_1_cmliu https://raw.githubusercontent.com/cmliu/WorkerVle2sub/main/addressesapi.txt &
curl -sL -o /root/cdnyx/api_2_cfyes https://addressesapi.090227.xyz/CloudFlareYes &
curl -sL -o /root/cdnyx/api_3_cfspeed https://addressesapi.090227.xyz/ip.164746.xyz &
curl -sL -o /root/cdnyx/api_4_cmliuct https://addressesapi.090227.xyz/ct &
curl -sL -o /root/cdnyx/api_5_cmliucmcc https://addressesapi.090227.xyz/cmcc &
curl -sL -o /root/cdnyx/api_6_cmliucmcc6 https://addressesapi.090227.xyz/cmcc-ipv6 &
curl -sL -o /root/cdnyx/api_7_cn https://cn.xxxxxxxx.tk &
curl -sL -o /root/cdnyx/api_8_ct https://ct.xxxxxxxx.tk &
curl -sL -o /root/cdnyx/api_9_cm  https://cm.xxxxxxxx.tk &
curl -sL -o /root/cdnyx/api_10_cu https://cu.xxxxxxxx.tk &
curl -sL -o /root/cdnyx/api_11_cn6  https://cnv6.xxxxxxxx.tk &
curl -sL -o /root/cdnyx/api_12_ct6 https://ctv6.xxxxxxxx.tk &
curl -sL -o /root/cdnyx/api_13_cm6 https://cmv6.xxxxxxxx.tk &
curl -sL -o /root/cdnyx/api_14_cu6 https://cuv6.xxxxxxxx.tk &
wait 30 &
sed -i 's/$/#bestCF/' /root/cdnyx/api_15_bestcf &
sed -i 's/$/#bestRP/' /root/cdnyx/api_16_bestproxy &
wait 30 &
find /root/cdnyx/ -name "api_*" | xargs sed 'a\' > /root/cdnyx/merge.txt &
rm -f /root/cdnyx/api_* &
sed -i 's/:443//g' /root/cdnyx/merge.txt &
sed -i 's/@Warp_Key//g' /root/cdnyx/merge.txt &
sed -i '/404/d' /root/cdnyx/merge.txt &
sed -i '/DOCTYPE/d' /root/cdnyx/merge.txt &
cat /root/cdnyx/merge.txt