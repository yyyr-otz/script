# syntax=docker/dockerfile:1.4

# 第一阶段：构建环境
FROM --platform=$TARGETPLATFORM alpine:3.21 AS builder

# 安装编译依赖（兼容多架构）
RUN apk update && \
    apk add --no-cache \
    musl-dev \
    gcc \
    python3-dev \
    py3-pip \
    zlib-dev \
    jpeg-dev \
    libffi-dev

# 配置虚拟环境和静态编译
ENV VENV_PATH="/app/venv" \
    PATH="/app/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    LDFLAGS="-static"

WORKDIR /app

# 创建虚拟环境（无需 py3-venv 包）
RUN python3 -m venv $VENV_PATH

# 复制并安装依赖
COPY alist-tgbot-py/requirements.txt .
RUN pip install --no-cache-dir --no-deps -r requirements.txt

# 复制源码
COPY alist-tgbot-py/tgbot.py .

# 静态编译二进制
RUN pip install pyinstaller && \
    pyinstaller --onefile \
      --name alist-tgbot-py \
      --workpath /tmp/build \
      --distpath /app/dist \
      --add-data "$VENV_PATH/lib/python3.11/site-packages:." \
      tgbot.py

# 第二阶段：最小化运行时镜像
FROM scratch
COPY --from=builder /app/dist/alist-tgbot-py /
ENTRYPOINT ["/alist-tgbot-py"]
