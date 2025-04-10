# syntax=docker/dockerfile:1.4

# 第一阶段：交叉编译基础环境
ARG PY_VERSION=3.11
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.4.0 AS xx

FROM --platform=$BUILDPLATFORM python:${PY_VERSION}-alpine AS builder

# 初始化交叉编译环境（关键修复点1：传递平台参数）
COPY --from=xx / /
ARG TARGETPLATFORM
ENV XX_TARGETPLATFORM=$TARGETPLATFORM

# 安装基础依赖（关键修复点2：使用稳定仓库源）
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

# 验证环境（关键修复点3：分步验证）
RUN xx-verify --static /usr/bin/xx-pip  # 显式指定验证对象
RUN which xx-pip
RUN xx-env

# 安装Python依赖
WORKDIR /app
COPY alist-tgbot-py/requirements.txt .
RUN xx-pip install --no-cache-dir -r requirements.txt

# 构建二进制
COPY alist-tgbot-py/tgbot.py .
RUN mkdir -p /app/dist

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

# 第二阶段：运行时镜像
FROM --platform=$TARGETPLATFORM alpine:3.21 AS runner  # 使用稳定版本
RUN apk add --no-cache libstdc++
COPY --from=builder /app/dist/alist-tgbot-py /app/
ENTRYPOINT ["/app/alist-tgbot-py"]
