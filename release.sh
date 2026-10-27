#!/usr/bin/env bash
set -euo pipefail

TASK="${1:-}"
PLATFORMS=("linux-amd64" "linux-arm64")

if [[ -z "$TASK" ]]; then
  echo "Error: 请指定任务名" >&2
  exit 1
fi

fetch_latest() {
  local repo="$1"
  curl -sL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

fetch_compare_prerelease() {
  local repo="$1"
  local latest
  latest=$(fetch_latest "$repo")

  local prerelease
  prerelease=$(curl -sL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${repo}/releases" | \
    jq -r '[.[] | select(.prerelease == true) | .tag_name | sub("^v";"") | select(test("[0-9]"))]
           | map(sub("^v";""))
           | sort_by(split(".") | map(tonumber))
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

process_github_release() {
  local repo="$1"
  local version="$2"
  local inner_binary="$3"
  local target_name="$4"
  local amd64_file="$5"
  local arm64_file="$6"

  echo "==> 处理 ${TASK} (版本: ${version})"

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

case "$TASK" in
  eooce)
    for plat in "${PLATFORMS[@]}"; do
      mkdir -p "dist/${plat}"
      subdomain=$([[ "$plat" == "linux-amd64" ]] && echo "amd64" || echo "arm64")
      curl -sL "https://${subdomain}.ssss.nyc.mn/agent" -o "dist/${plat}/v0"
      curl -sL "https://${subdomain}.ssss.nyc.mn/v1" -o "dist/${plat}/v1"
      chmod +x "dist/${plat}/v0" "dist/${plat}/v1"
      gh release upload "$plat" "dist/${plat}/v0" "dist/${plat}/v1" --clobber
    done
    ;;

  agent)
    ver=$(fetch_latest "nezhahq/agent")
    process_github_release "nezhahq/agent" "$ver" \
      "nezha-agent" "nezha-agent-v1" \
      "nezha-agent_linux_amd64.zip" "nezha-agent_linux_arm64.zip"
    ;;

  dashboard)
    ver=$(fetch_latest "nezhahq/nezha")
    for plat in "${PLATFORMS[@]}"; do
      mkdir -p "dist/${plat}"
      file="dashboard-${plat}.zip"
      curl -sL "https://github.com/nezhahq/nezha/releases/download/${ver}/${file}" -o "dist/${plat}/${file}"
      unzip -qo -j "dist/${plat}/${file}" "dashboard-${plat}" -d "dist/${plat}"
      mv -f "dist/${plat}/dashboard-${plat}" "dist/${plat}/dashboard"
      chmod +x "dist/${plat}/dashboard"
      rm -f "dist/${plat}/${file}"
      gh release upload "$plat" "dist/${plat}/dashboard" --clobber
    done
    ;;

  xray)
    ver=$(fetch_compare_prerelease "XTLS/Xray-core")
    process_github_release "XTLS/Xray-core" "$ver" \
      "xray" "xray" \
      "Xray-linux-64.zip" "Xray-linux-arm64-v8a.zip"
    ;;

  argo)
    ver=$(fetch_latest "cloudflare/cloudflared")
    process_github_release "cloudflare/cloudflared" "$ver" \
      "" "argo" \
      "cloudflared-linux-amd64" "cloudflared-linux-arm64"
    ;;

  mosdns4)
    ver=$(fetch_latest "pmkol/mosdns-x")
    process_github_release "pmkol/mosdns-x" "$ver" \
      "mosdns" "mosdns4" \
      "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
    ;;

  mosdns5)
    ver=$(fetch_latest "IrineSistiana/mosdns")
    process_github_release "IrineSistiana/mosdns" "$ver" \
      "mosdns" "mosdns5" \
      "mosdns-linux-amd64.zip" "mosdns-linux-arm64.zip"
    ;;

  alist)
    ver=$(fetch_latest "AlistGo/alist")
    process_github_release "AlistGo/alist" "$ver" \
      "alist" "alist" \
      "alist-linux-amd64.tar.gz" "alist-linux-arm64.tar.gz"
    ;;

  gost)
    ver=$(fetch_latest "go-gost/gost")
    ver_num="${ver#v}"
    process_github_release "go-gost/gost" "$ver" \
      "gost" "gost" \
      "gost_${ver_num}_linux_amd64v3.tar.gz" "gost_${ver_num}_linux_arm64.tar.gz"
    ;;

  wireproxy)
    ver=$(fetch_latest "windtf/wireproxy")
    process_github_release "windtf/wireproxy" "$ver" \
      "wireproxy" "wireproxy" \
      "wireproxy_linux_amd64.tar.gz" "wireproxy_linux_arm64.tar.gz"
    ;;

  aria2)
    ver=$(fetch_latest "AnInsomniacy/aria2-next")
    # 去除 tag 开头的 'v'（如果存在），拼接对应文件名
    ver_clean="${ver#v}"
    process_github_release "AnInsomniacy/aria2-next" "$ver" \
      "" "aria2c" \
      "aria2-next-${ver_clean}-linux-x86_64" "aria2-next-${ver_clean}-linux-aarch64"
    ;;


  *)
    echo "未识别的任务: $TASK" >&2
    exit 1
    ;;
esac
