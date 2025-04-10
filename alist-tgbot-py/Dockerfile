# syntax=docker/dockerfile:1.4
# 第一阶段：构建环境
FROM --platform=$TARGETPLATFORM alpine:3.21 AS builder

# 安装 Zig 编译器和构建工具
RUN apk add --no-cache \
    build-base \
    python3-dev \
    py3-pip \
    zlib-dev \
    libffi-dev \
    jpeg-dev \
    openssl-dev \
    musl-dev \
    zig

# 配置 Zig 为默认编译器
ENV CC="zig cc" \
    CXX="zig c++" \
    LDFLAGS="-static" \
    CFLAGS="-static" \
    PYTHONUNBUFFERED=1

# 创建隔离的虚拟环境
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:$PATH"

# 安装依赖
COPY alist-tgbot-py/requirements.txt .
RUN pip install --no-cache-dir --no-deps -r requirements.txt

# 安装 PyInstaller 和静态加固工具
RUN pip install --no-cache-dir \
    "pyinstaller>=6.12.0" \
    "staticx>=0.15.0"

# 复制源码并打包
COPY alist-tgbot-py/tgbot.py .
RUN pyinstaller --onefile \
    --name alist-tgbot-py \
    --workpath /tmp/build \
    --distpath /app/dist \
    --specpath /tmp/spec \
    --clean \
    tgbot.py

# 二次静态加固
RUN staticx /app/dist/alist-tgbot-py /app/dist/alist-tgbot-py-static

# 第二阶段：最小化运行时镜像
FROM scratch
COPY --from=builder /app/dist/alist-tgbot-py-static /
ENTRYPOINT ["/alist-tgbot-py-static"]
