# Terminal Finder 工作区镜像：rclone + fuse + bash，供对象存储终端挂载使用。
FROM debian:bookworm-slim

ARG TARGETARCH

RUN apt-get -o Acquire::Retries=3 \
      -o Acquire::http::Timeout=30 \
      -o Acquire::https::Timeout=30 \
      update \
 && DEBIAN_FRONTEND=noninteractive apt-get \
      -o Acquire::Retries=3 \
      -o Acquire::http::Timeout=30 \
      -o Acquire::https::Timeout=30 \
      install -y --no-install-recommends \
      bash zsh coreutils ca-certificates fuse3 curl unzip \
 && case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) rclone_arch="amd64" ;; \
      arm64) rclone_arch="arm64" ;; \
      *) echo "unsupported rclone architecture: ${TARGETARCH:-$(dpkg --print-architecture)}" >&2; exit 1 ;; \
    esac \
 && curl --fail --show-error --location \
      --connect-timeout 15 --max-time 300 \
      --retry 3 --retry-delay 2 --retry-all-errors \
      "https://downloads.rclone.org/rclone-current-linux-${rclone_arch}.zip" \
      -o /tmp/rclone.zip \
 && unzip -j /tmp/rclone.zip 'rclone-*/rclone' -d /usr/local/bin \
 && chmod +x /usr/local/bin/rclone \
 && rm -rf /tmp/rclone.zip /var/lib/apt/lists/* \
 # 允许 --allow-other（多 exec 用户访问挂载点）。
 && echo 'user_allow_other' > /etc/fuse.conf

# 挂载根目录。容器以 root 跑 rclone mount（fuse 需要），交互 shell 也在容器内。
RUN mkdir -p /mnt
WORKDIR /mnt
CMD ["sleep", "infinity"]
