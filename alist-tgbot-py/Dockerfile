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
    patchelf \
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
RUN pip install --no-cache-dir \
    -r requirements.txt \
    pyinstaller>=6.12.0 \
    staticx>=0.13.0 && \
    pip install --force-reinstall --no-deps \
    urllib3>=2.0.7 \
    chardet>=5.2.0 \
    idna>=3.6

# 复制源码并构建
RUN pyinstaller --onefile \
    --name alist-tgbot-py \
    --hidden-import urllib3 \
    --hidden-import chardet \
    --hidden-import idna \
    --hidden-import charset_normalizer \
    --collect-all requests \
    --collect-all urllib3 \
    --collect-all chardet \
    --collect-all idna \
    --add-data "$(python -c 'import requests; print(requests.__path__[0])'):requests" \
    --workpath /tmp/build \
    --distpath /app/dist \
    --specpath /tmp/spec \
    --clean \
    tgbot.py
    staticx /app/dist/alist-tgbot-py /app/dist/alist-tgbot-py-static

# 最终镜像
FROM scratch
COPY --from=builder /app/dist/alist-tgbot-py-static /alist-tgbot-py
ENTRYPOINT ["/alist-tgbot-py-static"]
