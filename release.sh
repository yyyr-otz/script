#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-all}"
FORCE_UPDATE="${FORCE_UPDATE:-false}"
PLATFORMS=("linux-amd64" "linux-arm64")
LOCAL_CONFIG="release.json"
UPDATED_COUNT=0
MAX_WEBDAV_JOBS=5       # WebDAV 并发传输连接数
WEBDAV_FAILED=false     # 标记 WebDAV 推送是否有失败项

# 初始化临时状态目录
mkdir -p dist/linux-amd64 dist/linux-arm64 dist/rules dist/.versions dist/.webdav_reports dist/.sha256_updates dist/.rules_changed
rm -f dist/.upload_amd64 dist/.upload_arm64

# ==================== WebDAV 认证与配置载入 ====================
WEBDAV_AUTH="${WEBDAV_AUTH:-${WEBDAV_CONFIG:-}}"
WEBDAV_ENABLED=false
WEBDAV_URL=""
WEBDAV_USER=""
WEBDAV_PASS=""
WEBDAV_FILE="release.json"
WEBDAV_DIR="/root/"

if [[ -n "$WEBDAV_AUTH" ]] && jq empty <<< "$WEBDAV_AUTH" 2>/dev/null; then
  WEBDAV_URL=$(jq -r '.url // .webdav.url // empty' <<< "$WEBDAV_AUTH")
  WEBDAV_USER=$(jq -r '.username // .user // .webdav.username // empty' <<< "$WEBDAV_AUTH")
  WEBDAV_PASS=$(jq -r '.password // .pass // .webdav.password // empty' <<< "$WEBDAV_AUTH")
  WEBDAV_FILE=$(jq -r '.file // .filename // "release.json"' <<< "$WEBDAV_AUTH")
  WEBDAV_DIR=$(jq -r '.dir // "/root/"' <<< "$WEBDAV_AUTH")

  if [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USER" && -n "$WEBDAV_PASS" ]]; then
    WEBDAV_ENABLED=true
  fi
fi

# 解析 WebDAV 完整 URL（将 /root 视为 WebDAV 根目录）
resolve_webdav_url() {
  local raw_dir="$1"
  local file="$2"

  local base="${WEBDAV_URL%/}"
  local path="${raw_dir#/}"
  path="${path%/}"

  if [[ "$path" == "root" ]]; then
    path=""
  elif [[ "$path" == root/* ]]; then
    path="${path#root/}"
  fi

  if [[ -n "$path" ]]; then
    echo "${base}/${path}/${file}"
  else
    echo "${base}/${file}"
  fi
}

# 并发异步上传单个文件到 WebDAV 并记录测速指标
upload_to_webdav_async() {
  local local_file="$1"
  local raw_dir="$2"
  local target_file="$3"

  if [[ ! -f "$local_file" ]]; then
    return 0
  fi

  local target_url
  target_url=$(resolve_webdav_url "$raw_dir" "$target_file")

  (
    local file_name file_size result time_total speed_bytes speed_mb status
    file_name=$(basename "$local_file")
    file_size=$(du -h "$local_file" 2>/dev/null | cut -f1 || echo "0B")

    result=$(curl -s -f \
      --connect-timeout 15 \
      -u "${WEBDAV_USER}:${WEBDAV_PASS}" \
      -T "${local_file}" \
      "${target_url}" \
      -w "TIME:%{time_total}|SPEED:%{speed_upload}" 2>&1) && status="SUCCESS" || status="FAILED"

    time_total=$(echo "$result" | grep -o 'TIME:[^|]*' | cut -d: -f2 || echo "0.0")
    speed_bytes=$(echo "$result" | grep -o 'SPEED:.*' | cut -d: -f2 || echo "0")
    speed_mb=$(awk "BEGIN {printf \"%.2f\", ${speed_bytes:-0}/1024/1024}")

    local log_id="${RANDOM}_$(date +%s%N)"
    echo "${file_name}|${file_size}|${time_total}|${speed_mb}|${status}|${raw_dir}" > "dist/.webdav_reports/${log_id}.log"
  ) &

  while (( $(jobs -r -p | wc -l) >= MAX_WEBDAV_JOBS )); do
    sleep 0.05
  done
}

# 打印美化的传输测速报表（同时设置全局失败标志）
print_webdav_summary() {
  local reports=(dist/.webdav_reports/*.log)
  if [[ ! -e "${reports[0]}" ]]; then
    return 0
  fi

  echo ""
  echo "================================================================================================"
  echo "                                    NAS WebDAV 传输报告                                         "
  echo "================================================================================================"
  printf "%-8s %-30s %-10s %-10s %-14s %-25s\n" "状态" "文件名" "大小" "耗时" "平均速度" "目标路径"
  echo "------------------------------------------------------------------------------------------------"

  local total_count=0
  local success_count=0
  local fail_count=0

  for r in dist/.webdav_reports/*.log; do
    [[ -f "$r" ]] || continue
    local line
    line=$(cat "$r")
    IFS='|' read -r fname fsize ftime fspeed fstatus fdir <<< "$line"

    local status_display="[成功]"
    if [[ "$fstatus" == "SUCCESS" ]]; then
      success_count=$((success_count + 1))
    else
      status_display="[失败]"
      fail_count=$((fail_count + 1))
    fi
    total_count=$((total_count + 1))

    printf "%-8s %-30s %-10s %-10s %-14s %-25s\n" \
      "$status_display" "$fname" "$fsize" "${ftime}s" "${fspeed} MB/s" "$fdir"
  done

  echo "------------------------------------------------------------------------------------------------"
  echo "传输统计: 共 ${total_count} 个文件 | 成功: ${success_count} | 失败: ${fail_count}"
  echo "================================================================================================"
  echo ""

  if (( fail_count > 0 )); then
    WEBDAV_FAILED=true
  fi
}

# 将任务中的文件排队加入 WebDAV 并发上传池
queue_task_webdav_uploads() {
  local task="$1"
  if [[ "$WEBDAV_ENABLED" != "true" || ! -f "$LOCAL_CONFIG" ]]; then
    return 0
  fi

  local targets_json
  targets_json=$(jq -c --arg t "$task" '.tasks[$t] // empty' "$LOCAL_CONFIG" 2>/dev/null || echo "")

  if [[ -z "$targets_json" || "$targets_json" == "null" || "$targets_json" == "[]" ]]; then
    return 0
  fi

  local count
  count=$(jq 'length' <<< "$targets_json")
  for (( i=0; i<count; i++ )); do
    local item
    item=$(jq -c ".[$i]" <<< "$targets_json")
    local dir
    dir=$(jq -r '.dir' <<< "$item")
    local file
    file=$(jq -r '.file // .filename' <<< "$item")
    local arch
    arch=$(jq -r '.arch // "linux-arm64"' <<< "$item")

    if [[ "$task" == "rules" ]]; then
      if [[ "$file" == "*.txt" || "$file" == "*" ]]; then
        for rf in dist/rules/*.txt; do
          local bname
          bname=$(basename "$rf")
          if [[ -f "dist/.rules_changed/${bname}" || "$FORCE_UPDATE" == "true" ]]; then
            upload_to_webdav_async "$rf" "$dir" "$bname"
          fi
        done
      else
        if [[ -f "dist/.rules_changed/${file}" || "$file" == "rules.tar.gz" || "$FORCE_UPDATE" == "true" ]]; then
          upload_to_webdav_async "dist/rules/${file}" "$dir" "$file"
        fi
      fi
    elif [[ "$task" == "eooce" ]]; then
      if [[ -f "dist/.sha256_updates/eooce_${arch}_${file}" || "$FORCE_UPDATE" == "true" ]]; then
        upload_to_webdav_async "dist/${arch}/${file}" "$dir" "$file"
      fi
    else
      upload_to_webdav_async "dist/${arch}/${file}" "$dir" "$file"
    fi
  done
}

# ==================== 联动 Nginx Lua 接口重启受影响的服务 ====================
trigger_nginx_restarts() {
  if [[ "$WEBDAV_ENABLED" != "true" || "$WEBDAV_FAILED" == "true" || ! -f "$LOCAL_CONFIG" ]]; then
    return 0
  fi

  local nginx_url nginx_key
  nginx_url=$(jq -r '.nginx.url // empty' "$LOCAL_CONFIG" 2>/dev/null || echo "")
  nginx_key=$(jq -r '.nginx.key // empty' "$LOCAL_CONFIG" 2>/dev/null || echo "")

  if [[ -z "$nginx_url" || -z "$nginx_key" ]]; then
    return 0
  fi

  mapfile -t allowed_svcs < <(jq -r '.nginx.services[]? // empty' "$LOCAL_CONFIG" 2>/dev/null)
  if (( ${#allowed_svcs[@]} == 0 )); then
    return 0
  fi

  # 建立“更新任务 -> 需重启服务”映射（alist 仅上传文件，不再触发重启）
  declare -A svcs_to_restart
  for vf in dist/.versions/*; do
    [[ -f "$vf" ]] || continue
    local tname
    tname=$(basename "$vf")
    case "$tname" in
      xray)     svcs_to_restart["xray"]=1 ;;
      mosdns5)  svcs_to_restart["mosdns5"]=1 ;;
      openlist) svcs_to_restart["openlist"]=1 ;;
      argo)     svcs_to_restart["argo"]=1 ;;
      rules)
        svcs_to_restart["mosdns5"]=1
        svcs_to_restart["xray"]=1
        ;;
    esac
  done

  if (( ${#svcs_to_restart[@]} == 0 )); then
    return 0
  fi

  # 过滤出 release.json 白名单中允许的服务，并拼接为逗号分隔列表单次派发
  local target_list=()
  for svc in "${!svcs_to_restart[@]}"; do
    for allowed in "${allowed_svcs[@]}"; do
      if [[ "$allowed" == "$svc" ]]; then
        target_list+=("$svc")
        break
      fi
    done
  done

  if (( ${#target_list[@]} > 0 )); then
    local joined_svcs
    joined_svcs=$(IFS=,; echo "${target_list[*]}")
    echo "=========================================================="
    echo "阶段 4: 远程通知 NAS 执行二进制赋权并依次重启 [${joined_svcs}]..."
    echo "=========================================================="

    local resp
    if resp=$(curl -fsSL --connect-timeout 10 -H "X-Key: ${nginx_key}" "${nginx_url}?service=${joined_svcs}" 2>&1); then
      echo "==> 触发成功: $(jq -r '.message // "OK"' <<< "$resp" 2>/dev/null || echo "$resp")"
    else
      echo "==> 触发失败: ${resp}"
    fi
  fi
}

# ==================== 初始化与版本管理 ====================
init_release_json() {
  local loaded=false

  if [[ "$WEBDAV_ENABLED" == "true" ]]; then
    local webdav_config_url
    webdav_config_url=$(resolve_webdav_url "$WEBDAV_DIR" "$WEBDAV_FILE")
    echo "==> 正在从 WebDAV 获取主配置文件: ${webdav_config_url}"

    if curl -fsSL --connect-timeout 15 -u "${WEBDAV_USER}:${WEBDAV_PASS}" "${webdav_config_url}" -o "$LOCAL_CONFIG" 2>/dev/null; then
      if jq empty "$LOCAL_CONFIG" >/dev/null 2>&1; then
        echo "==> 成功从 NAS 加载 release.json (包含 tasks, version 与 sha256)"
        loaded=true
      fi
    fi
  fi

  if [[ "$loaded" != "true" && ! -f "$LOCAL_CONFIG" ]]; then
    echo "==> 尝试从 GitHub Release 下载备用 ${LOCAL_CONFIG}..."
    gh release download "linux-amd64" -p "$LOCAL_CONFIG" 2>/dev/null || true
    if [[ -f "$LOCAL_CONFIG" ]] && jq empty "$LOCAL_CONFIG" >/dev/null 2>&1; then
      loaded=true
    fi
  fi

  if [[ ! -f "$LOCAL_CONFIG" ]] || ! jq empty "$LOCAL_CONFIG" >/dev/null 2>&1; then
    echo '{"tasks":{},"version":{},"sha256":{}}' > "$LOCAL_CONFIG"
  fi

  if [[ $(jq '.version // empty' "$LOCAL_CONFIG") == "" ]]; then
    local tmp
    tmp=$(jq '.version = {}' "$LOCAL_CONFIG") && echo "$tmp" > "$LOCAL_CONFIG"
  fi
  if [[ $(jq '.sha256 // empty' "$LOCAL_CONFIG") == "" ]]; then
    local tmp
    tmp=$(jq '.sha256 = {}' "$LOCAL_CONFIG") && echo "$tmp" > "$LOCAL_CONFIG"
  fi
}

sync_release_json() {
  if [[ ! -f "$LOCAL_CONFIG" ]]; then
    return
  fi

  # 1. 汇总所有更新任务计数与版本号
  for vf in dist/.versions/*; do
    [[ -f "$vf" ]] || continue
    local tname
    tname=$(basename "$vf")
    UPDATED_COUNT=$((UPDATED_COUNT + 1))

    if [[ "$tname" != "rules" && "$tname" != "eooce" ]]; then
      local nver
      nver=$(cat "$vf")
      local tmp
      tmp=$(jq --arg k "$tname" --arg v "$nver" '.version[$k] = $v' "$LOCAL_CONFIG")
      echo "$tmp" > "$LOCAL_CONFIG"
    fi
  done

  # 2. 汇总所有无版本号文件的哈希更新 (.sha256)
  if [[ -d dist/.sha256_updates ]]; then
    for sf in dist/.sha256_updates/*; do
      [[ -f "$sf" ]] || continue
      local key
      key=$(basename "$sf")
      local hval
      hval=$(cat "$sf")
      local tmp
      tmp=$(jq --arg k "$key" --arg h "$hval" '.sha256[$k] = $h' "$LOCAL_CONFIG")
      echo "$tmp" > "$LOCAL_CONFIG"
    done
  fi

  local formatted
  formatted=$(jq . "$LOCAL_CONFIG") && echo "$formatted" > "$LOCAL_CONFIG"
  echo "=========================================="
  echo "当前 release.json 最新状态预览:"
  jq '{version: .version, sha256_tracked_files: (.sha256 | length)}' "$LOCAL_CONFIG" || cat "$LOCAL_CONFIG"
  echo "=========================================="

  # 若 WebDAV 推送存在失败文件，阻止覆盖云端 release.json 以便下次补传
  if [[ "$WEBDAV_FAILED" == "true" ]]; then
    echo "⚠️ [中断回写] 检测到 NAS WebDAV 有部分文件推送失败，已跳过更新 release.json，下次运行时将自动补传！" >&2
    return 1
  fi

  if [[ "$UPDATED_COUNT" -gt 0 || "$FORCE_UPDATE" == "true" ]]; then
    if [[ "$WEBDAV_ENABLED" == "true" ]]; then
      echo "==> 正在回写 release.json 到 NAS WebDAV..."
      upload_to_webdav_async "$LOCAL_CONFIG" "$WEBDAV_DIR" "$WEBDAV_FILE"
      wait
    fi

    echo "==> 正在备份 release.json 到 GitHub Release (linux-amd64)..."
    gh_upload_with_retry "linux-amd64" "$LOCAL_CONFIG" || true
  else
    echo "==> 本次全部组件无更新，无需回写 release.json"
  fi
}

# ==================== GitHub Release 限流重试上传器 ====================
gh_upload_with_retry() {
  local tag="$1"
  shift
  local files=("$@")

  if (( ${#files[@]} == 0 )); then
    return 0
  fi

  printf "%s\n" "${files[@]}" | xargs -P 2 -I {} bash -c '
    tag="$1"
    file="$2"
    for ((i=1; i<=5; i++)); do
      if gh release upload "$tag" "$file" --clobber; then
        exit 0
      fi
      echo "⚠️ [第 ${i}/5 次] 上传 $(basename "$file") 至 [${tag}] 遇到服务端异常，4秒后重试..." >&2
      sleep 4
    done
    echo "❌ 上传 $(basename "$file") 至 [${tag}] 彻底失败" >&2
    exit 1
  ' _ "$tag" {}
}

# ==================== 版本比对与并发构建工具 ====================
VERSIONED_TASKS=("agent" "dashboard" "xray" "argo" "mosdns4" "mosdns5" "alist" "openlist" "gost" "wireproxy" "aria2" "dpanel")
UNVERSIONED_TASKS=("eooce" "rules")
ALL_TASKS=("${UNVERSIONED_TASKS[@]}" "${VERSIONED_TASKS[@]}")

gh_curl() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
  else
    curl -fsSL "$url"
  fi
}

fetch_latest() {
  local repo="$1"
  gh_curl "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // empty'
}

fetch_compare_prerelease() {
  local repo="$1"
  local latest
  latest=$(fetch_latest "$repo")

  local prerelease
  prerelease=$(gh_curl "https://api.github.com/repos/${repo}/releases" | \
    jq -r '[.[] | select(.prerelease == true) | .tag_name | sub("^v";"") | select(test("^[0-9]"))]
           | map(sub("^v";""))
           | sort_by(split(".") | map(tonumber? // 0))
           | reverse | first // empty')

  if [[ -n "$prerelease" ]]; then
    local newer
    newer=$(printf "%s\n%s" "${latest#v}" "${prerelease#v}" | sort -V | tail -n1)
    if [[ "$newer" == "${prerelease#v}" ]]; then
      echo "v${newer}"
      return
    fi
  fi
  echo "$latest"
}

is_up_to_date() {
  local task="$1"
  local new_ver="$2"

  if [[ -z "$new_ver" || "$new_ver" == "null" ]]; then
    echo "==> [警告] 未能获取到 ${task} 的有效版本号，跳过更新" >&2
    return 0
  fi

  if [[ "$FORCE_UPDATE" == "true" ]]; then
    echo "==> [强制更新] ${task} 最新版本为: ${new_ver}"
    return 1
  fi

  local old_ver
  old_ver=$(jq -r --arg k "$task" '.version[$k] // empty' "$LOCAL_CONFIG" 2>/dev/null || echo "")

  if [[ -n "$old_ver" && "$old_ver" == "$new_ver" ]]; then
    echo "==> [已是最新] ${task} (${old_ver}) 无变更，跳过"
    return 0
  fi

  echo "==> [发现更新] ${task}: ${old_ver:-未记录} -> ${new_ver}"
  return 1
}

process_github_release() {
  local task="$1"
  local repo="$2"
  local version="$3"
  local inner_binary="$4"
  local target_name="$5"
  local amd64_file="$6"
  local arm64_file="$7"

  echo "==> [构建开始] ${target_name} (${version})"

  local pids=()
  for plat in "${PLATFORMS[@]}"; do
    (
      local file=""
      [[ "$plat" == "linux-amd64" ]] && file="$amd64_file"
      [[ "$plat" == "linux-arm64" ]] && file="$arm64_file"

      local work_dir="dist/${plat}"
      local url="https://github.com/${repo}/releases/download/${version}/${file}"
      curl -fsSL --retry 3 "$url" -o "${work_dir}/${file}"

      case "$file" in
        *.zip)
          unzip -qo -j "${work_dir}/${file}" "${inner_binary}" -d "${work_dir}"
          if [[ "${inner_binary}" != "${target_name}" ]]; then
            mv -f "${work_dir}/${inner_binary}" "${work_dir}/${target_name}"
          fi
          rm -f "${work_dir}/${file}"
          ;;
        *.tar.gz|*.tgz)
          tar -xzf "${work_dir}/${file}" -C "${work_dir}" "${inner_binary}"
          if [[ "${inner_binary}" != "${target_name}" ]]; then
            mv -f "${work_dir}/${inner_binary}" "${work_dir}/${target_name}"
          fi
          rm -f "${work_dir}/${file}"
          ;;
        *)
          if [[ "${file}" != "${target_name}" ]]; then
            mv -f "${work_dir}/${file}" "${work_dir}/${target_name}"
          fi
          ;;
      esac

      chmod +x "${work_dir}/${target_name}"
      echo "${work_dir}/${target_name}" >> "dist/.upload_${plat#linux-}"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  echo "$version" > "dist/.versions/${task}"
}

# ==================== 业务任务分支 ====================
run_task() {
  local task="$1"
  case "$task" in
    dpanel)
      local ver
      ver=$(fetch_latest "donknap/dpanel")
      if is_up_to_date "dpanel" "$ver"; then return 0; fi
      process_github_release "dpanel" "donknap/dpanel" "$ver" \
        "" "dpanel" \
        "dpanel-ce-musl-amd64" "dpanel-ce-musl-arm64"
      ;;

    eooce)
      echo "==> 执行 eooce (并发下载与 SHA256 检测)"
      local pids=()
      for plat in "${PLATFORMS[@]}"; do
        (
          local subdomain=$([[ "$plat" == "linux-amd64" ]] && echo "amd64" || echo "arm64")
          curl -fsSL --retry 3 "https://${subdomain}.ssss.nyc.mn/agent" -o "dist/${plat}/v0"
          curl -fsSL --retry 3 "https://${subdomain}.ssss.nyc.mn/v1" -o "dist/${plat}/v1"
          chmod +x "dist/${plat}/v0" "dist/${plat}/v1"
        ) &
        pids+=($!)
      done
      for pid in "${pids[@]}"; do
        wait "$pid"
      done

      local eooce_changed=false
      for plat in "${PLATFORMS[@]}"; do
        local arch="${plat#linux-}"
        for bin in "v0" "v1"; do
          local fpath="dist/${plat}/${bin}"
          local key="eooce_${arch}_${bin}"
          local cur_hash
          cur_hash=$(sha256sum "$fpath" | awk '{print $1}')
          local old_hash
          old_hash=$(jq -r --arg k "$key" '.sha256[$k] // empty' "$LOCAL_CONFIG" 2>/dev/null || echo "")

          if [[ "$cur_hash" != "$old_hash" || "$FORCE_UPDATE" == "true" ]]; then
            echo "==> [发现更新] eooce (${arch} ${bin}): ${old_hash:0:10}... -> ${cur_hash:0:10}..."
            eooce_changed=true
            echo "$cur_hash" > "dist/.sha256_updates/${key}"
            echo "$fpath" >> "dist/.upload_${arch}"
          else
            echo "==> [已是最新] eooce (${arch} ${bin}) 哈希未变"
          fi
        done
      done

      if [[ "$eooce_changed" == "true" ]]; then
        touch "dist/.versions/eooce"
      fi
      ;;

    rules)
      echo "==> [rules] 开始全量并发下载规则与数据文件..."
      declare -A files_to_download=(
        ["ips-v4.txt"]="https://subhubpg1.yyyrspeed.nyc.mn/perm4.txt?token=workers-xh"
        ["ips-v6.txt"]="https://subhubpg1.yyyrspeed.nyc.mn/perm64.txt?token=workers-xh"
        ["adaway_domain_list.txt"]="https://raw.githubusercontent.com/NethServer/dns-community-blacklist/master/adaway.dns"
        ["china_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/china-list.txt"
        ["cn_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/domain-list-custom/release/cn.txt"
        ["geocn_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/domain-list-custom/release/geolocation-cn.txt"
        ["direct_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"
        ["reject_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt"
        ["mobiletrackers_domain_list.txt"]="https://raw.githubusercontent.com/craiu/mobiletrackers/master/list.txt"
        ["adhosts_domain_list.txt"]="https://raw.githubusercontent.com/symbuzzer/Turkish-Ad-Hosts/main/dns"
        ["blocklist_domain_list.txt"]="https://raw.githubusercontent.com/zebpalmer/dns_blocklists/master/blocklist.txt"
        ["iosblock_domain_list.txt"]="https://raw.githubusercontent.com/BlackJack8/iOSAdblockList/master/Regular%20Hosts.txt"
        ["ads_domain_list.txt"]="https://raw.githubusercontent.com/v2fly/domain-list-community/release/category-ads-all.txt"
        ["soteria_ads_domain_list.txt"]="https://raw.githubusercontent.com/soteria-nou/domain-list/master/ads.txt"
        ["pmkol_ads_domain_list.txt"]="https://raw.githubusercontent.com/pmkol/easymosdns/main/rules/ad_domain_list.txt"
        ["proxy_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
        ["gfw_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
        ["not_geocn_domain_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/domain-list-custom/release/geolocation-!cn.txt"
        ["china_ip_list.txt"]="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/cn.txt"
        ["gfw_ip_list.txt"]="https://raw.githubusercontent.com/pmkol/easymosdns/main/rules/gfw_ip_list.txt"
        ["cdn_domain_list.txt"]="https://raw.githubusercontent.com/pmkol/easymosdns/main/rules/cdn_domain_list.txt"
        ["geoip-only-cn-private.dat"]="https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip-only-cn-private.dat"
        ["geoip.dat"]="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip.dat"
        ["geosite.dat"]="https://github.com/Loyalsoldier/domain-list-custom/releases/latest/download/geosite.dat"
      )

      local pids=()
      for fname in "${!files_to_download[@]}"; do
        local url="${files_to_download[$fname]}"
        (
          curl -fsSL --retry 3 "$url" -o "dist/rules/$fname"
        ) &
        pids+=($!)
      done
      for pid in "${pids[@]}"; do
        wait "$pid"
      done

      local rules_changed=false
      for fname in "${!files_to_download[@]}"; do
        local fpath="dist/rules/$fname"
        [[ -s "$fpath" ]] || continue
        local cur_hash
        cur_hash=$(sha256sum "$fpath" | awk '{print $1}')
        local old_hash
        old_hash=$(jq -r --arg k "$fname" '.sha256[$k] // empty' "$LOCAL_CONFIG" 2>/dev/null || echo "")

        if [[ "$cur_hash" != "$old_hash" || "$FORCE_UPDATE" == "true" ]]; then
          echo "==> [发现更新] rules ($fname): ${old_hash:0:10}... -> ${cur_hash:0:10}..."
          rules_changed=true
          echo "$cur_hash" > "dist/.sha256_updates/${fname}"
          touch "dist/.rules_changed/${fname}"
        fi
      done

      if [[ "$rules_changed" == "true" ]]; then
        echo "==> [rules] 规则库有变动，正在重新打包 rules.tar.gz"
        (cd dist/rules && tar -czf rules.tar.gz *.txt)
        touch "dist/.versions/rules"
      else
        echo "==> [已是最新] rules 所有规则与数据文件哈希均未变化，跳过上传"
      fi
      ;;

    agent)
      local ver
      ver=$(fetch_latest "nezhahq/agent")
      if is_up_to_date "agent" "$ver"; then return 0; fi
      process_github_release "agent" "nezhahq/agent" "$ver" \
        "nezha-agent" "nezha-agent-v1" \
        "nezha-agent_linux_amd64.zip" "nezha-agent_linux_arm64.zip"
      ;;

    dashboard)
      local ver
      ver=$(fetch_latest "nezhahq/nezha")
      if is_up_to_date "dashboard" "$ver"; then return 0; fi
      echo "==> [构建开始] dashboard (${ver})"
      local pids=()
      for plat in "${PLATFORMS[@]}"; do
        (
          local file="dashboard-${plat}.zip"
          curl -fsSL --retry 3 "https://github.com/nezhahq/nezha/releases/download/${ver}/${file}" -o "dist/${plat}/${file}"
          unzip -qo -j "dist/${plat}/${file}" "dashboard-${plat}" -d "dist/${plat}"
          mv -f "dist/${plat}/dashboard-${plat}" "dist/${plat}/dashboard"
          chmod +x "dist/${plat}/dashboard"
          rm -f "dist/${plat}/${file}"
          echo "dist/${plat}/dashboard" >> "dist/.upload_${plat#linux-}"
        ) &
        pids+=($!)
      done
      for pid in "${pids[@]}"; do
        wait "$pid"
      done
      echo "$ver" > "dist/.versions/dashboard"
      ;;

    xray)
      local ver
      ver=$(fetch_compare_prerelease "XTLS/Xray-core")
      if is_up_to_date "xray" "$ver"; then return 0; fi
      process_github_release "xray" "XTLS/Xray-core" "$ver" \
        "xray" "xray" \
        "Xray-linux-64.zip" "Xray-linux-arm64-v8a.zip"
      ;;

    argo)
      local ver
      ver=$(fetch_latest "cloudflare/cloudflared")
      if is_up_to_date "argo" "$ver"; then return 0; fi
      process_github_release "argo" "cloudflare/cloudflared" "$ver" \
        "" "argo" \
        "cloudflared-linux-amd64" "cloudflared-linux-arm64"
      ;;

    mosdns4)
      local ver
      ver=$(fetch_latest "pmkol/mosdns-x")
      if is_up_to_date "mosdns4" "$ver"; then return 0; fi
      process_github_release "mosdns4" "pmkol/mosdns-x" "$ver" \
        "mosdns" "mosdns4" \
        "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
      ;;

    mosdns5)
      local ver
      ver=$(fetch_latest "IrineSistiana/mosdns")
      if is_up_to_date "mosdns5" "$ver"; then return 0; fi
      process_github_release "mosdns5" "IrineSistiana/mosdns" "$ver" \
        "mosdns" "mosdns5" \
        "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
      ;;

    alist)
      local ver
      ver=$(fetch_latest "AlistGo/alist")
      if is_up_to_date "alist" "$ver"; then return 0; fi
      process_github_release "alist" "AlistGo/alist" "$ver" \
        "alist" "alist" \
        "alist-linux-amd64.tar.gz" "alist-linux-arm64.tar.gz"
      ;;

    openlist)
      local ver
      ver=$(fetch_latest "OpenListTeam/OpenList")
      if is_up_to_date "openlist" "$ver"; then return 0; fi
      process_github_release "openlist" "OpenListTeam/OpenList" "$ver" \
        "openlist" "openlist" \
        "openlist-linux-amd64.tar.gz" "openlist-linux-arm64.tar.gz"
      ;;

    gost)
      local ver
      ver=$(fetch_latest "go-gost/gost")
      if is_up_to_date "gost" "$ver"; then return 0; fi
      local ver_num="${ver#v}"
      process_github_release "gost" "go-gost/gost" "$ver" \
        "gost" "gost" \
        "gost_${ver_num}_linux_amd64v3.tar.gz" "gost_${ver_num}_linux_arm64.tar.gz"
      ;;

    wireproxy)
      local ver
      ver=$(fetch_latest "windtf/wireproxy")
      if is_up_to_date "wireproxy" "$ver"; then return 0; fi
      process_github_release "wireproxy" "windtf/wireproxy" "$ver" \
        "wireproxy" "wireproxy" \
        "wireproxy_linux_amd64.tar.gz" "wireproxy_linux_arm64.tar.gz"
      ;;

    aria2)
      local ver
      ver=$(fetch_latest "AnInsomniacy/aria2-next")
      if is_up_to_date "aria2" "$ver"; then return 0; fi
      local ver_clean="${ver#v}"
      process_github_release "aria2" "AnInsomniacy/aria2-next" "$ver" \
        "" "aria2c" \
        "aria2-next-${ver_clean}-linux-x86_64" "aria2-next-${ver_clean}-linux-aarch64"
      ;;

    *)
      echo "错误: 未识别的任务: $task" >&2
      exit 1
      ;;
  esac
}

# ==================== 主流程控制 ====================
main() {
  init_release_json

  echo "=========================================================="
  echo "阶段 1: 并发检测版本/哈希并构建目标资产..."
  echo "=========================================================="

  if [[ "$TARGET" == "all" ]]; then
    local main_pids=()
    for t in "${ALL_TASKS[@]}"; do
      run_task "$t" &
      main_pids+=($!)
    done
    for pid in "${main_pids[@]}"; do
      wait "$pid"
    done
  else
    run_task "$TARGET"
  fi

  echo "=========================================================="
  echo "阶段 2: 批量推送构建产物到 GitHub Release..."
  echo "=========================================================="

  if [[ -f dist/.upload_amd64 ]]; then
    mapfile -t amd64_list < <(sort -u dist/.upload_amd64)
    if (( ${#amd64_list[@]} > 0 )); then
      echo "==> 批量上传 [linux-amd64] 变动资产: ${amd64_list[*]}"
      gh_upload_with_retry "linux-amd64" "${amd64_list[@]}"
    fi
  fi

  if [[ -f dist/.upload_arm64 ]]; then
    mapfile -t arm64_list < <(sort -u dist/.upload_arm64)
    if (( ${#arm64_list[@]} > 0 )); then
      echo "==> 批量上传 [linux-arm64] 变动资产: ${arm64_list[*]}"
      gh_upload_with_retry "linux-arm64" "${arm64_list[@]}"
    fi
  fi

  if [[ -f dist/.versions/rules ]]; then
    local rules_files=()
    for flag in dist/.rules_changed/*; do
      [[ -f "$flag" ]] || continue
      local fname
      fname=$(basename "$flag")
      [[ -f "dist/rules/${fname}" ]] && rules_files+=("dist/rules/${fname}")
    done
    [[ -f "dist/rules/rules.tar.gz" ]] && rules_files+=("dist/rules/rules.tar.gz")

    if (( ${#rules_files[@]} > 0 )); then
      echo "==> 批量上传 [rules] 变更资产 (${#rules_files[@]} 个): ${rules_files[*]}"
      gh_upload_with_retry "rules" "${rules_files[@]}"
    fi
  fi

  echo "=========================================================="
  echo "阶段 3: 并发推送更新文件至 NAS WebDAV (仅推变动文件)..."
  echo "=========================================================="

  for vf in dist/.versions/*; do
    [[ -f "$vf" ]] || continue
    local updated_task
    updated_task=$(basename "$vf")
    queue_task_webdav_uploads "$updated_task"
  done
  wait

  print_webdav_summary
  sync_release_json
  trigger_nginx_restarts

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "updated_count=${UPDATED_COUNT}" >> "$GITHUB_OUTPUT"
    echo "release_json=$(jq -c .version "$LOCAL_CONFIG" 2>/dev/null || echo '{}')" >> "$GITHUB_OUTPUT"
  fi
}
