# syntax=docker/dockerfile:1.4
FROM --platform=$TARGETPLATFORM alpine:3.21 AS builder

# 添加 scons 和完整构建工具链
RUN apk add --no-cache \
    build-base \
    python3-dev \
    py3-pip \
    zlib-dev \
    libffi-dev \
    jpeg-dev \
    openssl-dev \
    musl-dev \
    scons \
    zig

# 配置静态编译环境
ENV CC="zig cc" \
    CXX="zig c++" \
    LDFLAGS="-static" \
    CFLAGS="-static" \
    PYTHONUNBUFFERED=1

# 创建虚拟环境
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"

# 安装依赖（固定版本避免兼容性问题）
COPY alist-tgbot-py/requirements.txt .
RUN pip install --no-cache-dir --no-deps -r requirements.txt && \
    pip install --no-cache-dir \
        "pyinstaller>=6.12.0" \
        "staticx>=0.13.0"

# 复制源码并构建
COPY alist-tgbot-py/tgbot.py .
RUN pyinstaller --onefile \
    --name alist-tgbot-py \
    --workpath /tmp/build \
    --distpath /app/dist \
    --specpath /tmp/spec \
    --clean \
    tgbot.py && \
    staticx /app/dist/alist-tgbot-py /app/dist/alist-tgbot-py-static

# 最终镜像
FROM scratch
COPY --from=builder /app/dist/alist-tgbot-py-static /
ENTRYPOINT ["/alist-tgbot-py-static"]
