# 第一阶段：构建环境
FROM --platform=$TARGETPLATFORM alpine:3.18 AS builder
WORKDIR /app

# 安装编译依赖
RUN apk add --no-cache musl-dev gcc python3-dev py3-pip

# 复制代码
COPY alist-tgbot-py/requirements.txt .
RUN pip install --user -r requirements.txt
COPY alist-tgbot-py/tgbot.py .

# 关键修复：显式创建输出目录
RUN mkdir -p /app/dist

# 编译二进制
RUN pip install pyinstaller && \
    pyinstaller --onefile \
      --name alist-tgbot-py \
      --workpath /app/build \
      --distpath /app/dist \
      tgbot.py

# 第二阶段：提取二进制文件
FROM scratch
COPY --from=builder /app/dist/alist-tgbot-py /
