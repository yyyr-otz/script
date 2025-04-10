# syntax=docker/dockerfile:1.4

# --- 第一阶段：交叉编译基础环境 ---
ARG PY_VERSION=3.11
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.4.0 AS xx

FROM --platform=$BUILDPLATFORM python:${PY_VERSION}-alpine AS builder

# 初始化交叉编译环境
COPY --from=xx / /
ARG TARGETPLATFORM
ENV XX_TARGETPLATFORM=$TARGETPLATFORM

# --- 动态设置交叉编译工具链前缀 ---
ARG REPO_URL=http://dl-cdn.alpinelinux.org/alpine/latest-stable
RUN \
  # 根据架构选择包管理工具前缀
  if [ "$TARGETARCH" = "arm64" ]; then \
    PKG_MANAGER="xx-apk --arch arm64 --repository $REPO_URL/main --repository $REPO_URL/community"; \
  else \
    PKG_MANAGER="apk --no-cache"; \
  fi && \
  # 统一安装依赖
  $PKG_MANAGER add gcc musl-dev python3-dev py3-pip

# --- 安装 Python 依赖 ---
WORKDIR /app
COPY alist-tgbot-py/requirements.txt .
RUN ${PKG_MANAGER%% *}-pip install --no-cache-dir -r requirements.txt

# --- 构建二进制文件（动态化 PyInstaller 命令）---
ARG PYINSTALLER_ARGS=--onefile --name alist-tgbot-py --workpath /app/build --distpath /out
COPY alist-tgbot-py/tgbot.py .
RUN mkdir -p /out && \
  # 安装 PyInstaller
  ${PKG_MANAGER%% *}-pip install pyinstaller && \
  # 动态执行构建命令
  ${PKG_MANAGER%% *}-pyinstaller $PYINSTALLER_ARGS tgbot.py

# --- 验证产物静态兼容性 ---
RUN xx-verify --static /out/alist-tgbot-py

# --- 第二阶段：运行时镜像 ---
FROM --platform=$TARGETPLATFORM alpine:3.19 AS runner
RUN apk add --no-cache libstdc++
COPY --from=builder /out/alist-tgbot-py /app/
ENTRYPOINT ["/app/alist-tgbot-py"]
