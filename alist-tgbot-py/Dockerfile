# syntax=docker/dockerfile:1.4

# 第一阶段：通用构建环境（自动适配架构）
ARG PY_VERSION=3.11
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.3.0 AS xx

FROM --platform=$BUILDPLATFORM python:${PY_VERSION}-alpine AS builder

# 交叉编译工具链配置
COPY --from=xx / /
RUN apk add --no-cache musl-dev gcc
RUN xx-apk --no-cache add musl-dev gcc

# 架构相关环境变量
ARG TARGETARCH
ENV CFLAGS="-O3" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# 安装架构特定依赖（示例）
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      xx-apk --no-cache --arch arm64 add python3-dev; \
    else \
      apk add --no-cache python3-dev; \
    fi

# 复制代码并安装依赖
WORKDIR /app
COPY alist-tgbot-py/requirements.txt .
RUN xx-pip install --no-cache-dir -r requirements.txt

# 构建配置（自动识别目标架构）
COPY alist-tgbot-py/tgbot.py .
RUN mkdir -p /app/dist

# PyInstaller 交叉编译关键配置
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      xx-pip install pyinstaller && \
      xx-pyinstaller --onefile \
        --name alist-tgbot-py \
        --workpath /app/build \
        --distpath /app/dist \
        tgbot.py; \
    else \
      pip install pyinstaller && \
      pyinstaller --onefile \
        --name alist-tgbot-py \
        --workpath /app/build \
        --distpath /app/dist \
        tgbot.py; \
    fi

# 第二阶段：按架构优化的最终镜像
FROM --platform=$TARGETPLATFORM alpine:3.18 AS runtime

# 安装最小运行时依赖
RUN apk add --no-cache libstdc++
COPY --from=builder /app/dist/alist-tgbot-py /app/

# 架构特定的优化配置
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      echo "Applying ARM64 optimizations..." && \
      apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/main arm64/openssl3; \
    else \
      apk add --no-cache openssl; \
    fi

ENTRYPOINT ["/app/alist-tgbot-py"]
