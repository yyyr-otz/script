# syntax=docker/dockerfile:1.4

# --- 第一阶段：交叉编译基础环境 ---
ARG PY_VERSION=3.11
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.4.0 AS xx

FROM --platform=$BUILDPLATFORM python:${PY_VERSION}-alpine AS builder

# 初始化交叉编译环境
COPY --from=xx / /
ARG TARGETPLATFORM
ENV XX_TARGETPLATFORM=$TARGETPLATFORM

# --- 动态设置命令前缀 ---
ARG REPO_URL=http://dl-cdn.alpinelinux.org/alpine/latest-stable
RUN \
  # 根据架构设置包管理器和 pip 前缀
  if [ "$TARGETARCH" = "arm64" ]; then \
    PKG_MANAGER="xx-apk --arch arm64 --repository $REPO_URL/main --repository $REPO_URL/community"; \
    PIP_CMD="xx-pip"; \
  else \
    PKG_MANAGER="apk --no-cache"; \
    PIP_CMD="pip"; \
  fi && \
  # 安装系统依赖
  $PKG_MANAGER add gcc musl-dev python3-dev py3-pip

# --- 安装 Python 依赖 ---
WORKDIR /app
COPY alist-tgbot-py/requirements.txt .
RUN $PIP_CMD install --no-cache-dir -r requirements.txt

# --- 构建二进制文件 ---
ARG PYINSTALLER_ARGS=--onefile --name alist-tgbot-py --workpath /app/build --distpath /out
COPY alist-tgbot-py/tgbot.py .
RUN mkdir -p /out && \
  $PIP_CMD install pyinstaller && \
  # 根据架构选择 PyInstaller 命令
  if [ "$TARGETARCH" = "arm64" ]; then \
    xx-pyinstaller $PYINSTALLER_ARGS tgbot.py; \
  else \
    pyinstaller $PYINSTALLER_ARGS tgbot.py; \
  fi

# --- 验证产物静态兼容性 ---
RUN xx-verify --static /out/alist-tgbot-py

# --- 第二阶段：运行时镜像 ---
FROM --platform=$TARGETPLATFORM alpine:3.19 AS runner
RUN apk add --no-cache libstdc++
COPY --from=builder /out/alist-tgbot-py /app/
ENTRYPOINT ["/app/alist-tgbot-py"]
