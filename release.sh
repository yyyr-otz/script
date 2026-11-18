#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-all}"
FORCE_UPDATE="${FORCE_UPDATE:-false}"
PLATFORMS=("linux-amd64" "linux-arm64")
RELEASE_JSON="release.json"
UPDATED_COUNT=0

# ==================== WebDAV 配置解析 ====================
WEBDAV_CONFIG="${WEBDAV_CONFIG:-}"
WEBDAV_ENABLED=false
WEBDAV_URL=""
WEBDAV_USER=""
WEBDAV_PASS=""

if [[ -n "$WEBDAV_CONFIG" ]] && jq empty <<< "$WEBDAV_CONFIG" 2>/dev/null; then
  WEBDAV_URL=$(jq -r '.webdav.url // .url // empty' <<< "$WEBDAV_CONFIG")
  WEBDAV_USER=$(jq -r '.webdav.username // .username // .user // empty' <<< "$WEBDAV_CONFIG")
  WEBDAV_PASS=$(jq -r '.webdav.password // .password // .pass // empty' <<< "$WEBDAV_CONFIG")
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

# WebDAV 单文件上传核心函数（带简洁进度条与 MB/s 测速）
upload_to_webdav() {
  local local_file="$1"
  local target_url="$2"

  if [[ ! -f "$local_file" ]]; then
    echo "==> [跳过 WebDAV] 本地文件不存在: $local_file"
    return 0
  fi

  local file_name
  file_name=$(basename "$local_file")
  local file_size
  file_size=$(du -h "$local_file" | cut -f1)

  echo "--------------------------------------------------------"
  echo "==> 正在推送 [${file_name}] (${file_size}) 到 NAS WebDAV..."
  echo "    目标: ${target_url}"

  local result
  result=$(curl -# -f \
    --connect-timeout 15 \
    -u "${WEBDAV_USER}:${WEBDAV_PASS}" \
    -T "${local_file}" \
    "${target_url}" \
    -w "TIME:%{time_total}|SPEED:%{speed_upload}" 2>&1) || {
      echo "==> [警告] 上传到 WebDAV 失败: ${file_name} (请检查路径或网络连接)" >&2
      echo "--------------------------------------------------------"
      return 0
    }

  local time_total speed_bytes speed_mb
  time_total=$(echo "$result" | grep -o 'TIME:[^|]*' | cut -d: -f2)
  speed_bytes=$(echo "$result" | grep -o 'SPEED:.*' | cut -d: -f2)
  speed_mb=$(awk "BEGIN {printf \"%.2f\", ${speed_bytes:-0}/1024/1024}")

  echo "==> 推送成功! 耗时: ${time_total}s | 平均速度: ${speed_mb} MB/s"
  echo "--------------------------------------------------------"
}

# 推送任务文件到 WebDAV
push_task_to_webdav() {
  local task="$1"
  if [[ "$WEBDAV_ENABLED" != "true" ]]; then
    return 0
  fi

  local targets_json
  targets_json=$(jq -c --arg t "$task" '.tasks[$t] // empty' <<< "$WEBDAV_CONFIG" 2>/dev/null || echo "")

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
      # 如果配置的是 *.txt、rules.tar.gz 或 *，则将所有 mosdns 规则 txt 全部上传到目标文件夹
      if [[ "$file" == "*.txt" || "$file" == "rules.tar.gz" || "$file" == "*" ]]; then
        echo "==> 正在将全部规则文本文件逐个推送到 WebDAV: ${dir}"
        for rf in dist/rules/*.txt; do
          local bname
          bname=$(basename "$rf")
          # 排除 cf 专用的 ips 文件
          if [[ "$bname" == "ips-v4.txt" || "$bname" == "ips-v6.txt" ]]; then
            continue
          fi
          local target_url
          target_url=$(resolve_webdav_url "$dir" "$bname")
          upload_to_webdav "$rf" "$target_url"
        done
      else
        # 单个文件上传 (例如 ips-v4.txt, ips-v6.txt, geoip.dat 等)
        local local_file="dist/rules/${file}"
        local target_url
        target_url=$(resolve_webdav_url "$dir" "$file")
        upload_to_webdav "$local_file" "$target_url"
      fi
    else
      # 二进制文件上传
      local local_file="dist/${arch}/${file}"
      local target_url
      target_url=$(resolve_webdav_url "$dir" "$file")
      upload_to_webdav "$local_file" "$target_url"
    fi
  done
}

get_webdav_version_url() {
  if [[ "$WEBDAV_ENABLED" != "true" ]]; then
    echo ""
    return
  fi
  local dir
  dir=$(jq -r '.version_file.dir // "/root/etc/"' <<< "$WEBDAV_CONFIG")
  local file
  file=$(jq -r '.version_file.file // .version_file.filename // "release_version.json"' <<< "$WEBDAV_CONFIG")
  resolve_webdav_url "$dir" "$file"
}

# ==================== 任务列表与基础工具 ====================
VERSIONED_TASKS=("agent" "dashboard" "xray" "argo" "mosdns4" "mosdns5" "alist" "gost" "wireproxy" "aria2")
UNVERSIONED_TASKS=("eooce" "rules")

gh_curl() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -sL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
  else
    curl -sL "$url"
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

init_release_json() {
  local loaded=false
  local webdav_version_url
  webdav_version_url=$(get_webdav_version_url)

  if [[ -n "$webdav_version_url" ]]; then
    echo "==> 尝试从 WebDAV 读取版本文件: ${webdav_version_url}"
    if curl -fsSL --connect-timeout 10 -u "${WEBDAV_USER}:${WEBDAV_PASS}" "${webdav_version_url}" -o "$RELEASE_JSON" 2>/dev/null; then
      if jq empty "$RELEASE_JSON" >/dev/null 2>&1; then
        echo "==> 成功从 WebDAV 加载已有版本配置"
        loaded=true
      fi
    fi
  fi

  if [[ "$loaded" != "true" && ! -f "$RELEASE_JSON" ]]; then
    echo "==> 尝试从 GitHub Release (linux-amd64) 下载 ${RELEASE_JSON}..."
    gh release download "linux-amd64" -p "$RELEASE_JSON" 2>/dev/null || true
    if [[ -f "$RELEASE_JSON" ]] && jq empty "$RELEASE_JSON" >/dev/null 2>&1; then
      loaded=true
    fi
  fi

  if [[ ! -f "$RELEASE_JSON" ]] || ! jq empty "$RELEASE_JSON" >/dev/null 2>&1; then
    echo "{}" > "$RELEASE_JSON"
  fi
}

sync_release_json() {
  if [[ ! -f "$RELEASE_JSON" ]]; then
    return
  fi

  local formatted
  formatted=$(jq . "$RELEASE_JSON") && echo "$formatted" > "$RELEASE_JSON"
  echo "当前 ${RELEASE_JSON} 内容:"
  cat "$RELEASE_JSON"

  if [[ "$UPDATED_COUNT" -gt 0 || "$FORCE_UPDATE" == "true" ]]; then
    local webdav_version_url
    webdav_version_url=$(get_webdav_version_url)
    if [[ -n "$webdav_version_url" ]]; then
      echo "==> 正在同步更新版本文件到 WebDAV..."
      upload_to_webdav "$RELEASE_JSON" "$webdav_version_url"
    fi

    echo "==> 正在上传 ${RELEASE_JSON} 到 GitHub Release (linux-amd64)..."
    gh release upload "linux-amd64" "$RELEASE_JSON" --clobber || true
  else
    echo "==> 本次无软件更新，无需同步上传版本记录"
  fi
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
  old_ver=$(jq -r --arg k "$task" '.[$k] // empty' "$RELEASE_JSON" 2>/dev/null || echo "")

  if [[ -n "$old_ver" && "$old_ver" == "$new_ver" ]]; then
    echo "==> [已是最新] ${task} (版本 ${old_ver}) 无变更，跳过"
    return 0
  fi

  echo "==> [发现更新] ${task}: ${old_ver:-未记录} -> ${new_ver}"
  return 1
}

save_version() {
  local task="$1"
  local ver="$2"
  local tmp
  tmp=$(jq --arg k "$task" --arg v "$ver" '.[$k] = $v' "$RELEASE_JSON")
  echo "$tmp" > "$RELEASE_JSON"
  UPDATED_COUNT=$((UPDATED_COUNT + 1))
}

process_github_release() {
  local repo="$1"
  local version="$2"
  local inner_binary="$3"
  local target_name="$4"
  local amd64_file="$5"
  local arm64_file="$6"

  echo "==> 正在下载与构建 ${target_name} (版本: ${version})"

  for plat in "${PLATFORMS[@]}"; do
    local file=""
    [[ "$plat" == "linux-amd64" ]] && file="$amd64_file"
    [[ "$plat" == "linux-arm64" ]] && file="$arm64_file"

    local work_dir="dist/${plat}"
    mkdir -p "$work_dir"

    local url="https://github.com/${repo}/releases/download/${version}/${file}"
    echo "正在下载 [${plat}]: ${url}"
    curl -sL "$url" -o "${work_dir}/${file}"

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

    echo "正在上传到 Release: ${plat}"
    gh release upload "$plat" "${work_dir}/${target_name}" --clobber
  done
}

# ==================== 业务任务分支 ====================
run_task() {
  local task="$1"
  case "$task" in
    eooce)
      echo "==> 执行 eooce (不检查版本，直接更新)"
      for plat in "${PLATFORMS[@]}"; do
        mkdir -p "dist/${plat}"
        local subdomain=$([[ "$plat" == "linux-amd64" ]] && echo "amd64" || echo "arm64")
        curl -sL "https://${subdomain}.ssss.nyc.mn/agent" -o "dist/${plat}/v0"
        curl -sL "https://${subdomain}.ssss.nyc.mn/v1" -o "dist/${plat}/v1"
        chmod +x "dist/${plat}/v0" "dist/${plat}/v1"
        gh release upload "$plat" "dist/${plat}/v0" "dist/${plat}/v1" --clobber
      done
      UPDATED_COUNT=$((UPDATED_COUNT + 1))
      ;;

    rules)
      echo "==> 执行 rules (规则与数据文件，直接更新)"
      mkdir -p dist/rules

      declare -A files_to_download=(
        ["ips-v4.txt"]="https://subhubpg1.yyyrspeed.nyc.mn/cidr4?token=yyyr"
        ["ips-v6.txt"]="https://subhubpg1.yyyrspeed.nyc.mn/cidr6?token=yyyr"
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

      # 1. 下载全部文件
      for fname in "${!files_to_download[@]}"; do
        local url="${files_to_download[$fname]}"
        echo "正在下载: $fname"
        curl -sL --retry 3 "$url" -o "dist/rules/$fname"
      done

      # 2. 【关键】：在打包成 rules.tar.gz 之前，将规则全都发送到 WebDAV 各指定目录
      echo "==> [WebDAV] 在打包 rules.tar.gz 之前先行推送规则文件到 NAS..."
      push_task_to_webdav "rules"

      # 3. 将 mosdns 规则 txt 打包为 rules.tar.gz (排除 ips-*.txt)
      echo "==> 正在将 txt 文件打包为 rules.tar.gz"
      (cd dist/rules && tar -czf rules.tar.gz --exclude="ips-*.txt" *.txt)

      # 4. 上传至 Release 资产
      local upload_files=()
      for file in dist/rules/*; do
        [[ -f "$file" ]] && upload_files+=("$file")
      done

      echo "正在推送所有规则文件（txt、dat 及 rules.tar.gz）到 Release: rules"
      gh release upload "rules" "${upload_files[@]}" --clobber
      UPDATED_COUNT=$((UPDATED_COUNT + 1))
      ;;

    agent)
      local ver
      ver=$(fetch_latest "nezhahq/agent")
      if is_up_to_date "agent" "$ver"; then return 0; fi
      process_github_release "nezhahq/agent" "$ver" \
        "nezha-agent" "nezha-agent-v1" \
        "nezha-agent_linux_amd64.zip" "nezha-agent_linux_arm64.zip"
      push_task_to_webdav "agent"
      save_version "agent" "$ver"
      ;;

    dashboard)
      local ver
      ver=$(fetch_latest "nezhahq/nezha")
      if is_up_to_date "dashboard" "$ver"; then return 0; fi
      echo "==> 处理 dashboard (版本: ${ver})"
      for plat in "${PLATFORMS[@]}"; do
        mkdir -p "dist/${plat}"
        local file="dashboard-${plat}.zip"
        curl -sL "https://github.com/nezhahq/nezha/releases/download/${ver}/${file}" -o "dist/${plat}/${file}"
        unzip -qo -j "dist/${plat}/${file}" "dashboard-${plat}" -d "dist/${plat}"
        mv -f "dist/${plat}/dashboard-${plat}" "dist/${plat}/dashboard"
        chmod +x "dist/${plat}/dashboard"
        rm -f "dist/${plat}/${file}"
        gh release upload "$plat" "dist/${plat}/dashboard" --clobber
      done
      push_task_to_webdav "dashboard"
      save_version "dashboard" "$ver"
      ;;

    xray)
      local ver
      ver=$(fetch_compare_prerelease "XTLS/Xray-core")
      if is_up_to_date "xray" "$ver"; then return 0; fi
      process_github_release "XTLS/Xray-core" "$ver" \
        "xray" "xray" \
        "Xray-linux-64.zip" "Xray-linux-arm64-v8a.zip"
      push_task_to_webdav "xray"
      save_version "xray" "$ver"
      ;;

    argo)
      local ver
      ver=$(fetch_latest "cloudflare/cloudflared")
      if is_up_to_date "argo" "$ver"; then return 0; fi
      process_github_release "cloudflare/cloudflared" "$ver" \
        "" "argo" \
        "cloudflared-linux-amd64" "cloudflared-linux-arm64"
      push_task_to_webdav "argo"
      save_version "argo" "$ver"
      ;;

    mosdns4)
      local ver
      ver=$(fetch_latest "pmkol/mosdns-x")
      if is_up_to_date "mosdns4" "$ver"; then return 0; fi
      process_github_release "pmkol/mosdns-x" "$ver" \
        "mosdns" "mosdns4" \
        "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
      push_task_to_webdav "mosdns4"
      save_version "mosdns4" "$ver"
      ;;

    mosdns5)
      local ver
      ver=$(fetch_latest "IrineSistiana/mosdns")
      if is_up_to_date "mosdns5" "$ver"; then return 0; fi
      process_github_release "IrineSistiana/mosdns" "$ver" \
        "mosdns" "mosdns5" \
        "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
      push_task_to_webdav "mosdns5"
      save_version "mosdns5" "$ver"
      ;;

    alist)
      local ver
      ver=$(fetch_latest "AlistGo/alist")
      if is_up_to_date "alist" "$ver"; then return 0; fi
      process_github_release "AlistGo/alist" "$ver" \
        "alist" "alist" \
        "alist-linux-amd64.tar.gz" "alist-linux-arm64.tar.gz"
      push_task_to_webdav "alist"
      save_version "alist" "$ver"
      ;;

    gost)
      local ver
      ver=$(fetch_latest "go-gost/gost")
      if is_up_to_date "gost" "$ver"; then return 0; fi
      local ver_num="${ver#v}"
      process_github_release "go-gost/gost" "$ver" \
        "gost" "gost" \
        "gost_${ver_num}_linux_amd64v3.tar.gz" "gost_${ver_num}_linux_arm64.tar.gz"
      push_task_to_webdav "gost"
      save_version "gost" "$ver"
      ;;

    wireproxy)
      local ver
      ver=$(fetch_latest "windtf/wireproxy")
      if is_up_to_date "wireproxy" "$ver"; then return 0; fi
      process_github_release "windtf/wireproxy" "$ver" \
        "wireproxy" "wireproxy" \
        "wireproxy_linux_amd64.tar.gz" "wireproxy_linux_arm64.tar.gz"
      push_task_to_webdav "wireproxy"
      save_version "wireproxy" "$ver"
      ;;

    aria2)
      local ver
      ver=$(fetch_latest "AnInsomniacy/aria2-next")
      if is_up_to_date "aria2" "$ver"; then return 0; fi
      local ver_clean="${ver#v}"
      process_github_release "AnInsomniacy/aria2-next" "$ver" \
        "" "aria2c" \
        "aria2-next-${ver_clean}-linux-x86_64" "aria2-next-${ver_clean}-linux-aarch64"
      push_task_to_webdav "aria2"
      save_version "aria2" "$ver"
      ;;

    *)
      echo "错误: 未识别的任务: $task" >&2
      exit 1
      ;;
  esac
}

# ==================== 主程序 ====================
main() {
  init_release_json

  if [[ "$TARGET" == "all" ]]; then
    echo "=========================================="
    echo "开始增量检测与更新全部任务..."
    echo "=========================================="
    for t in "${UNVERSIONED_TASKS[@]}" "${VERSIONED_TASKS[@]}"; do
      run_task "$t"
    done
  else
    run_task "$TARGET"
  fi

  echo "=========================================="
  echo "任务完成! 本次更新组件数: ${UPDATED_COUNT}"
  echo "=========================================="

  sync_release_json

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "updated_count=${UPDATED_COUNT}" >> "$GITHUB_OUTPUT"
    echo "release_json=$(jq -c . "$RELEASE_JSON" 2>/dev/null || echo '{}')" >> "$GITHUB_OUTPUT"
  fi
}

main
