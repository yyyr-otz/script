# syntax=docker/dockerfile:1.4

# 第一阶段：交叉编译基础环境
ARG PY_VERSION=3.11
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.4.0 AS xx

FROM --platform=$BUILDPLATFORM python:${PY_VERSION}-alpine AS builder

# 初始化交叉编译环境
COPY --from=xx / /
RUN xx-apk update

# 安装基础依赖
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      xx-apk add --arch arm64 gcc musl-dev python3-dev \
        --repository http://dl-cdn.alpinelinux.org/alpine/v3.23/main \
        --repository http://dl-cdn.alpinelinux.org/alpine/v3.23/community; \
    else \
      apk add --no-cache gcc musl-dev python3-dev; \
    fi

# 复制代码并安装依赖
WORKDIR /app
COPY alist-tgbot-py/requirements.txt .
RUN xx-pip install --no-cache-dir -r requirements.txt

# 构建配置
COPY alist-tgbot-py/tgbot.py .
RUN mkdir -p /app/dist

# 使用PyInstaller构建二进制文件
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
FROM --platform=$TARGETPLATFORM alpine:latest AS runner

# 安装最小运行时依赖
RUN apk add --no-cache libstdc++
COPY --from=builder /app/dist/alist-tgbot-py /app/
ENTRYPOINT ["/app/alist-tgbot-py"]
