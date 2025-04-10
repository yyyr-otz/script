# syntax=docker/dockerfile:1.4

# 第一阶段：交叉编译基础环境
ARG PY_VERSION=3.11
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.3.0 AS xx

FROM --platform=$BUILDPLATFORM python:${PY_VERSION}-alpine AS builder

# 初始化交叉编译环境（关键修复步骤）
COPY --from=xx / /
ARG TARGETPLATFORM
RUN xx-apk --no-cache add musl-dev gcc && \
    xx-apk update --arch $(xx-info arch)

# 动态配置目标架构参数
ARG TARGETARCH
ENV XX_TARGETARCH=$TARGETARCH

# 智能安装架构相关依赖
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      xx-apk --arch arm64 add python3-dev --repository http://dl-cdn.alpinelinux.org/alpine/edge/main; \
    else \
      apk add --no-cache python3-dev; \
    fi

# 构建步骤（保持原有逻辑）
WORKDIR /app
COPY alist-tgbot-py/requirements.txt .
RUN xx-pip install --no-cache-dir -r requirements.txt

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

# 最终镜像阶段保持不变
FROM --platform=$TARGETPLATFORM alpine:3.18 AS runtime
RUN apk add --no-cache libstdc++
COPY --from=builder /app/dist/alist-tgbot-py /app/
ENTRYPOINT ["/app/alist-tgbot-py"]
