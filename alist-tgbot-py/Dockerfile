# syntax=docker/dockerfile:1.4

# 第一阶段：交叉编译基础环境
ARG PY_VERSION=3.11
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.4.0 AS xx

FROM --platform=$BUILDPLATFORM python:${PY_VERSION}-alpine AS builder

# 初始化交叉编译环境
COPY --from=xx / /
ARG TARGETPLATFORM
ENV XX_TARGETPLATFORM=$TARGETPLATFORM

# 安装基础依赖
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      xx-apk update --arch arm64 --repository http://dl-cdn.alpinelinux.org/alpine/latest-stable/main && \
      xx-apk add --arch arm64 \
        gcc \
        musl-dev \
        python3-dev \
        py3-pip \
        --repository http://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
        --repository http://dl-cdn.alpinelinux.org/alpine/latest-stable/community; \
    else \
      apk add --no-cache gcc musl-dev python3-dev py3-pip; \
    fi

# 安装 Python 依赖
WORKDIR /app
COPY alist-tgbot-py/requirements.txt .
RUN xx-pip install --no-cache-dir -r requirements.txt

# 构建二进制文件（关键调整点：指定输出到 /out）
COPY alist-tgbot-py/tgbot.py .
RUN mkdir -p /out  # 创建统一输出目录

RUN if [ "$TARGETARCH" = "arm64" ]; then \
      xx-pip install pyinstaller && \
      xx-pyinstaller --onefile \
        --name alist-tgbot-py \
        --workpath /app/build \
        --distpath /out \  # 输出到 /out
        alist-tgbot-py/tgbot.py; \
    else \
      pip install pyinstaller && \
      pyinstaller --onefile \
        --name alist-tgbot-py \
        --workpath /app/build \
        --distpath /out \  # 输出到 /out
        alist-tgbot-py/tgbot.py; \
    fi

# 验证产物兼容性
RUN xx-verify --static /out/alist-tgbot-py

# 第二阶段：运行时镜像（仅用于调试）
FROM --platform=$TARGETPLATFORM alpine:3.19 AS runner
RUN apk add --no-cache libstdc++
COPY --from=builder /out/alist-tgbot-py /app/
ENTRYPOINT ["/app/alist-tgbot-py"]
