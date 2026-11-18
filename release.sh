#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-all}"
FORCE_UPDATE="${FORCE_UPDATE:-false}"
PLATFORMS=("linux-amd64" "linux-arm64")
RELEASE_JSON="release.json"
UPDATED_COUNT=0

# WebDAV 相关参数处理
WEBDAV_FILE="${WEBDAV_FILE:-release_version.json}"

# 组装 WebDAV 完整 URL
get_webdav_url() {
  if [[ -z "${WEBDAV_URL:-}" ]]; then
    echo ""
    return
  fi
  local base="${WEBDAV_URL%/}"
  local dir="${WEBDAV_DIR:-}"
  dir="${dir#/}"
  dir="${dir%/}"

  if [[ -n "$dir" ]]; then
    echo "${base}/${dir}/${WEBDAV_FILE}"
  else
    echo "${base}/${WEBDAV_FILE}"
  fi
}

WEBDAV_FULL_URL=$(get_webdav_url)

# 需要比对版本并记录的任务列表
VERSIONED_TASKS=("agent" "dashboard" "xray" "argo" "mosdns4" "mosdns5" "alist" "gost" "wireproxy" "aria2")
# 不需要比对版本、直接更新的任务列表
UNVERSIONED_TASKS=("eooce" "rules")

# 带 Token 的安全 Curl
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

# 初始化 / 从 WebDAV 或本地或 Release 下载 JSON
init_release_json() {
  local loaded=false

  # 1. 优先尝试从 WebDAV 获取
  if [[ -n "$WEBDAV_FULL_URL" && -n "${WEBDAV_USER:-}" && -n "${WEBDAV_PASS:-}" ]]; then
    echo "==> 尝试从 WebDAV 读取版本文件: ${WEBDAV_FULL_URL}"
    if curl -fsSL -u "${WEBDAV_USER}:${WEBDAV_PASS}" "${WEBDAV_FULL_URL}" -o "$RELEASE_JSON" 2>/dev/null; then
      if jq empty "$RELEASE_JSON" >/dev/null 2>&1; then
        echo "==> 成功从 WebDAV 加载版本配置"
        loaded=true
      fi
    fi
    if [[ "$loaded" != "true" ]]; then
      echo "==> WebDAV 上暂无有效文件或读取失败，将尝试备用源"
    fi
  fi

  # 2. 若 WebDAV 没取到，尝试从 Release 资产取
  if [[ "$loaded" != "true" && ! -f "$RELEASE_JSON" ]]; then
    echo "==> 尝试从 GitHub Release (linux-amd64) 下载 ${RELEASE_JSON}..."
    gh release download "linux-amd64" -p "$RELEASE_JSON" 2>/dev/null || true
    if [[ -f "$RELEASE_JSON" ]] && jq empty "$RELEASE_JSON" >/dev/null 2>&1; then
      loaded=true
    fi
  fi

  # 3. 兜底初始化空 JSON
  if [[ ! -f "$RELEASE_JSON" ]] || ! jq empty "$RELEASE_JSON" >/dev/null 2>&1; then
    echo "{}" > "$RELEASE_JSON"
  fi
}

# 同步保存回 WebDAV 和 Release
sync_release_json() {
  if [[ ! -f "$RELEASE_JSON" ]]; then
    return
  fi

  # 格式化 JSON
  local formatted
  formatted=$(jq . "$RELEASE_JSON") && echo "$formatted" > "$RELEASE_JSON"
  echo "当前 ${RELEASE_JSON} 内容:"
  cat "$RELEASE_JSON"

  # 仅当有更新或强制构建时上传
  if [[ "$UPDATED_COUNT" -gt 0 || "$FORCE_UPDATE" == "true" ]]; then
    # 1. 上传至 WebDAV
    if [[ -n "$WEBDAV_FULL_URL" && -n "${WEBDAV_USER:-}" && -n "${WEBDAV_PASS:-}" ]]; then
      echo "==> 正在上传最新版本记录至 WebDAV: ${WEBDAV_FULL_URL}"
      if curl -fsS -u "${WEBDAV_USER}:${WEBDAV_PASS}" -T "$RELEASE_JSON" "${WEBDAV_FULL_URL}"; then
        echo "==> WebDAV 同步成功!"
      else
        echo "==> [警告] 上传到 WebDAV 失败，请检查账号密码或路径" >&2
      fi
    fi

    # 2. 同步上传一份到 GitHub Release 作为兜底
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

      for fname in "${!files_to_download[@]}"; do
        local url="${files_to_download[$fname]}"
        echo "正在下载: $fname"
        curl -sL --retry 3 "$url" -o "dist/rules/$fname"
      done

      echo "==> 正在将 txt 文件打包为 rules.tar.gz"
      (cd dist/rules && tar -czf rules.tar.gz *.txt)

      local upload_files=()
      for file in dist/rules/*; do
        [[ -f "$file" ]] && upload_files+=("$file")
      done

      echo "正在推送所有规则文件到 Release: rules"
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
      save_version "dashboard" "$ver"
      ;;

    xray)
      local ver
      ver=$(fetch_compare_prerelease "XTLS/Xray-core")
      if is_up_to_date "xray" "$ver"; then return 0; fi
      process_github_release "XTLS/Xray-core" "$ver" \
        "xray" "xray" \
        "Xray-linux-64.zip" "Xray-linux-arm64-v8a.zip"
      save_version "xray" "$ver"
      ;;

    argo)
      local ver
      ver=$(fetch_latest "cloudflare/cloudflared")
      if is_up_to_date "argo" "$ver"; then return 0; fi
      process_github_release "cloudflare/cloudflared" "$ver" \
        "" "argo" \
        "cloudflared-linux-amd64" "cloudflared-linux-arm64"
      save_version "argo" "$ver"
      ;;

    mosdns4)
      local ver
      ver=$(fetch_latest "pmkol/mosdns-x")
      if is_up_to_date "mosdns4" "$ver"; then return 0; fi
      process_github_release "pmkol/mosdns-x" "$ver" \
        "mosdns" "mosdns4" \
        "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
      save_version "mosdns4" "$ver"
      ;;

    mosdns5)
      local ver
      ver=$(fetch_latest "IrineSistiana/mosdns")
      if is_up_to_date "mosdns5" "$ver"; then return 0; fi
      process_github_release "IrineSistiana/mosdns" "$ver" \
        "mosdns" "mosdns5" \
        "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
      save_version "mosdns5" "$ver"
      ;;

    alist)
      local ver
      ver=$(fetch_latest "AlistGo/alist")
      if is_up_to_date "alist" "$ver"; then return 0; fi
      process_github_release "AlistGo/alist" "$ver" \
        "alist" "alist" \
        "alist-linux-amd64.tar.gz" "alist-linux-arm64.tar.gz"
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
      save_version "gost" "$ver"
      ;;

    wireproxy)
      local ver
      ver=$(fetch_latest "windtf/wireproxy")
      if is_up_to_date "wireproxy" "$ver"; then return 0; fi
      process_github_release "windtf/wireproxy" "$ver" \
        "wireproxy" "wireproxy" \
        "wireproxy_linux_amd64.tar.gz" "wireproxy_linux_arm64.tar.gz"
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
      save_version "aria2" "$ver"
      ;;

    *)
      echo "错误: 未识别的任务: $task" >&2
      exit 1
      ;;
  esac
}

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
