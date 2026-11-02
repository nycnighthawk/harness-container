# Claude Code development sandbox for rootless Podman.
#
# Build (defaults: Node 22 + Python 3 + build tools):
#   podman build -t claude-sandbox .
# Customize:
#   podman build -t claude-sandbox \
#     --build-arg NODE_MAJOR=20 \
#     --build-arg EXTRA_APT="golang postgresql-client" \
#     --build-arg CLAUDE_VERSION=stable .
# Set NODE_MAJOR=none to skip Node.

FROM docker.io/library/debian:bookworm-slim

ARG CLAUDE_VERSION=stable
ARG NODE_MAJOR=22
ARG EXTRA_APT=""
ARG USERNAME=claude
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

# Base dev toolchain. Add what your project needs via EXTRA_APT or edit this list.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget git git-lfs openssh-client gnupg \
        ripgrep fd-find jq less procps tree unzip zip xz-utils file \
        build-essential pkg-config make cmake \
        python3 python3-pip python3-venv pipx \
        vim-tiny nano sqlite3 \
        ${EXTRA_APT} \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Node.js from the official nodejs.org tarball (Debian's is too old).
RUN set -eux; \
    if [ "${NODE_MAJOR}" != "none" ]; then \
      case "$(dpkg --print-architecture)" in amd64) a=x64;; arm64) a=arm64;; *) echo "unsupported arch"; exit 1;; esac; \
      base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"; \
      f="$(curl -fsSL "$base/SHASUMS256.txt" | awk -v a="linux-$a.tar.xz" '$2 ~ a"$" {print $2}')"; \
      curl -fsSLO "$base/$f"; \
      curl -fsSL "$base/SHASUMS256.txt" | grep " $f\$" | sha256sum -c -; \
      tar -xJf "$f" -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE; \
      rm "$f"; node --version; npm --version; \
    fi

# Non-root user (Claude Code refuses --dangerously-skip-permissions as root).
RUN groupadd -g "${GID}" "${USERNAME}" \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}" \
    && mkdir -p /workspace "/home/${USERNAME}/.claude" "/home/${USERNAME}/.cache" \
    && chown -R "${UID}:${GID}" /workspace "/home/${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Claude Code via the official native installer -> ~/.local/bin/claude
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"

# CLAUDE_CONFIG_DIR keeps all Claude state (settings, .claude.json, .credentials.json)
# in one directory so one named volume persists your login.
# npm/pip globals go to the user's home; caches go to ~/.cache (a separate volume).
ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.npm-global/bin:${PATH}" \
    CLAUDE_CONFIG_DIR="/home/${USERNAME}/.claude" \
    DISABLE_AUTOUPDATER=1 \
    NPM_CONFIG_PREFIX="/home/${USERNAME}/.npm-global" \
    NPM_CONFIG_CACHE="/home/${USERNAME}/.cache/npm" \
    PIP_CACHE_DIR="/home/${USERNAME}/.cache/pip"

COPY --chmod=0755 sandbox-entrypoint.sh /usr/local/bin/sandbox-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
