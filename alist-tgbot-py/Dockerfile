# syntax=docker/dockerfile:1.4

# 第一阶段：构建环境
FROM --platform=$TARGETPLATFORM alpine:3.21 AS builder

# 安装编译依赖（兼容多架构）
RUN <<EOF
  apk update
  apk add --no-cache \
    musl-dev \
    gcc \
    python3-dev \
    py3-pip \
    py3-setuptools \
    zlib-dev \
    jpeg-dev \
    libffi-dev
EOF

# 配置静态编译环境
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    LDFLAGS="-static" \
    CFLAGS="-static"

WORKDIR /app

# 安装 Python 依赖
COPY alist-tgbot-py/requirements.txt .
RUN pip install --user --no-deps -r requirements.txt

# 复制源码
COPY alist-tgbot-py/tgbot.py .
COPY alist-tgbot-py/requirements.txt .

# 静态编译二进制
RUN <<EOF
  pip install --user pyinstaller
  ~/.local/bin/pyinstaller \
    --onefile \
    --name alist-tgbot-py \
    --workpath /tmp/build \
    --distpath /app/dist \
    --add-data "/usr/lib/python3.11/site-packages:." \
    tgbot.py
EOF

# 第二阶段：最小化运行时镜像
FROM scratch
COPY --from=builder /app/dist/alist-tgbot-py /
ENTRYPOINT ["/alist-tgbot-py"]
