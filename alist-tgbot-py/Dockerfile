# syntax=docker/dockerfile:1.4
# 第一阶段：构建环境
FROM --platform=$TARGETPLATFORM ubuntu:24.04 AS builder

# 安装核心依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    python3-dev \
    python3-venv \
    python3-pip \
    zlib1g-dev \
    libjpeg-dev \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# 配置虚拟环境和静态编译
ENV VENV_PATH="/app/venv" \
    PATH="/app/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    LDFLAGS="-static"

WORKDIR /app

# 创建虚拟环境并升级工具
RUN python3 -m venv $VENV_PATH && \
    pip install --upgrade pip wheel && \
    echo "Python 版本: $(python3 --version)" && \
    export PYTHON_VER=$(python3 -c "import sys; print(f'python{sys.version_info.major}.{sys.version_info.minor}')") && \
    echo "Python 库路径: $VENV_PATH/lib/$PYTHON_VER/site-packages"

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
                --add-data "$VENV_PATH/lib/$PYTHON_VER/site-packages:." \
                tgbot.py

# 第二阶段：最小化运行时镜像
FROM scratch
COPY --from=builder /app/dist/alist-tgbot-py /
ENTRYPOINT ["/alist-tgbot-py"]
