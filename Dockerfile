# 定义构建参数
ARG TARGETARCH
ARG BUILD_PREVIEW=false
ARG BUILD_COMPAT=false

# ==================== 构建阶段 ====================
FROM --platform=linux/${TARGETARCH} rustlang/rust:nightly-trixie-slim AS builder

ARG TARGETARCH
ARG BUILD_PREVIEW
ARG BUILD_COMPAT

WORKDIR /build

# 安装构建依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc nodejs npm lld musl-tools wget ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    case "$TARGETARCH" in \
        amd64) rustup target add x86_64-unknown-linux-musl ;; \
        arm64) rustup target add aarch64-unknown-linux-musl ;; \
        *) echo "Unsupported architecture: $TARGETARCH" && exit 1 ;; \
    esac

# 复制仓库所有文件
COPY . .

# 执行编译
RUN \
    case "$TARGETARCH" in \
        amd64) \
            TARGET_TRIPLE="x86_64-unknown-linux-musl"; \
            TARGET_CPU="x86-64-v3" ;; \
        arm64) \
            TARGET_TRIPLE="aarch64-unknown-linux-musl"; \
            TARGET_CPU="neoverse-n1" ;; \
    esac && \
    \
    FEATURES="" && \
    if [ "$BUILD_PREVIEW" = "true" ]; then FEATURES="$FEATURES __preview_locked"; fi && \
    if [ "$BUILD_COMPAT" = "true" ]; then FEATURES="$FEATURES __compat"; fi && \
    FEATURES=$(echo "$FEATURES" | xargs) && \
    \
    RUSTFLAGS_BASE="-C link-arg=-s -C link-arg=-fuse-ld=lld -C target-feature=+crt-static -A unused" && \
    if [ "$BUILD_COMPAT" = "true" ]; then \
        export RUSTFLAGS="$RUSTFLAGS_BASE"; \
    else \
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=$TARGET_CPU"; \
    fi && \
    \
    if [ -n "$FEATURES" ]; then \
        cargo build --bin cursor-api --release --target=$TARGET_TRIPLE --features "$FEATURES"; \
    else \
        cargo build --bin cursor-api --release --target=$TARGET_TRIPLE; \
    fi && \
    \
    # --- 关键：准备交付文件夹 ---
    mkdir -p /app_out && \
    cp target/$TARGET_TRIPLE/release/cursor-api /app_out/ && \
    # 强制将 frontend.zip 移入交付目录
    if [ -f "frontend.zip" ]; then \
        cp frontend.zip /app_out/; \
    else \
        echo "Warning: frontend.zip not found in build context, attempting to download..."; \
        wget -O /app_out/frontend.zip https://github.com/wisdgod/cursor-api/releases/download/v0.4.0-pre.21/frontend.zip; \
    fi && \
    # 如果有 .env 也带走
    if [ -f ".env" ]; then cp .env /app_out/; fi

# ==================== 运行阶段 ====================
# 使用 scratch 追求极致体积
FROM scratch

# 设置工作目录
WORKDIR /app

# 从 builder 阶段的 /app_out 复制所有内容到当前目录 (.)
# 这确保了 cursor-api 和 frontend.zip 在同一层级
COPY --chown=1001:1001 --chmod=0700 --from=builder /app_out/ .

# 环境变量设置
ENV PORT=3000
ENV FRONTEND_PATH=frontend.zip

EXPOSE ${PORT}

# 使用非 root 用户运行
USER 1001

# 启动命令：直接执行当前目录下的二进制
ENTRYPOINT ["./cursor-api"]
