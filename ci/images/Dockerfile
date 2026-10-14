# ============================================================
# deploy-tools — the image every deploy job runs in
# (helm + helmfile + helm-secrets + helm-diff + sops + kubectl + aws-cli).
#
# Build:  docker build -f docker/Dockerfile -t <registry>/deploy-tools:<ver> docker/
#
# ── WHY DEBIAN AND NOT ALPINE ───────────────────────────────────────────────
# This image used to be alpine-based, which silently produced a BROKEN aws:
# AWS CLI v2 ships only a dynamically glibc-linked binary, so on musl it dies at
# exec time with
#     failed to open elf at /lib64/ld-linux-x86-64.so.2
# `gcompat` does not rescue it either (verified). Since every deploy job starts
# with `aws sts assume-role`, the whole pipeline depended on a binary that could
# not run. debian:*-slim gives glibc; everything else here is a static Go binary
# and does not care.
# ============================================================
FROM debian:trixie-slim

# Pin every tool. Bump deliberately, then update DEPLOY_TOOLS_VERSION in the
# GitLab group CI/CD variables so jobs pick up the new image.
# helmfile is pinned to the version that produced the checked-in helmfile.lock
# files (`version: v1.4.2`) — a mismatch re-resolves chart versions on `deps`.
ARG HELM_VERSION=3.20.1
ARG HELMFILE_VERSION=1.4.2
ARG HELM_SECRETS_VERSION=4.7.7
ARG HELM_DIFF_VERSION=3.15.10
ARG SOPS_VERSION=3.13.3
ARG KUBECTL_VERSION=1.34.1
ARG AWS_CLI_VERSION=2.31.19

# Multi-arch: derive the vendor arch strings from the buildx TARGETARCH so the
# image builds on both amd64 CI runners and arm64 (Graviton / Apple silicon).
# The previous build hardcoded x86_64 and produced an unusable arm64 image.
ARG TARGETARCH

# ── Helm plugin location ────────────────────────────────────────────────────
# CRITICAL: plugins install into $HELM_PLUGINS. Without this, `helm plugin
# install` as root writes to /root/.local/share/helm/plugins, and the non-root
# `deploy` user below then looks in /home/deploy/.local/share/helm/plugins and
# finds NOTHING — every `helmfile diff` and every SOPS decrypt in CI fails with
# "plugin not found". Pinning it to a world-readable path fixes both users.
ENV HELM_PLUGINS=/usr/local/share/helm/plugins

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg age jq unzip; \
    rm -rf /var/lib/apt/lists/*; \
    case "${TARGETARCH:-amd64}" in \
      amd64) GOARCH=amd64; AWSARCH=x86_64 ;; \
      arm64) GOARCH=arm64; AWSARCH=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    # ── aws-cli v2 (official installer; alpine's aws-cli package is v1 only) ──
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSARCH}-${AWS_CLI_VERSION}.zip" -o /tmp/awscli.zip; \
    unzip -q /tmp/awscli.zip -d /tmp/awscli; \
    /tmp/awscli/aws/install; \
    rm -rf /tmp/awscli.zip /tmp/awscli; \
    \
    # ── helm (checksum-verified against the upstream .sha256sum) ──
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${GOARCH}.tar.gz" -o /tmp/helm.tgz; \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${GOARCH}.tar.gz.sha256sum" -o /tmp/helm.sha; \
    awk '{print $1"  /tmp/helm.tgz"}' /tmp/helm.sha | sha256sum -c -; \
    tar xz -C /usr/local/bin --strip-components=1 -f /tmp/helm.tgz "linux-${GOARCH}/helm"; \
    rm -f /tmp/helm.tgz /tmp/helm.sha; \
    \
    # ── helmfile (the checksums file covers every artifact of the release) ──
    curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${GOARCH}.tar.gz" -o /tmp/helmfile.tgz; \
    curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_checksums.txt" -o /tmp/helmfile.sha; \
    grep " helmfile_${HELMFILE_VERSION}_linux_${GOARCH}.tar.gz\$" /tmp/helmfile.sha \
      | awk '{print $1"  /tmp/helmfile.tgz"}' | sha256sum -c -; \
    tar xz -C /usr/local/bin -f /tmp/helmfile.tgz helmfile; \
    rm -f /tmp/helmfile.tgz /tmp/helmfile.sha; \
    \
    # ── sops ──
    curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${GOARCH}" -o /usr/local/bin/sops; \
    curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.checksums.txt" -o /tmp/sops.sha; \
    grep " sops-v${SOPS_VERSION}.linux.${GOARCH}\$" /tmp/sops.sha \
      | awk '{print $1"  /usr/local/bin/sops"}' | sha256sum -c -; \
    chmod +x /usr/local/bin/sops; rm -f /tmp/sops.sha; \
    \
    # ── kubectl (dl.k8s.io publishes a .sha256 next to every binary) ──
    curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl" -o /usr/local/bin/kubectl; \
    curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl.sha256" -o /tmp/kubectl.sha; \
    echo "$(cat /tmp/kubectl.sha)  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; rm -f /tmp/kubectl.sha; \
    \
    # ── helm plugins (pinned; land in $HELM_PLUGINS, readable by any user) ──
    mkdir -p "${HELM_PLUGINS}"; \
    helm plugin install https://github.com/jkroepke/helm-secrets --version "v${HELM_SECRETS_VERSION}"; \
    helm plugin install https://github.com/databus23/helm-diff  --version "v${HELM_DIFF_VERSION}"; \
    chmod -R a+rX "${HELM_PLUGINS}"; \
    \
    rm -rf /tmp/* /root/.cache

# Run as non-root. HELM_PLUGINS is an ENV so it is inherited here — this is what
# makes the plugins installed above visible to `deploy`.
RUN groupadd -r deploy && useradd -r -g deploy -m -d /home/deploy -s /bin/bash deploy
USER deploy
WORKDIR /home/deploy

# Sanity-check AS THE RUNTIME USER: catches both the glibc/aws regression and
# the plugin-path regression at build time instead of in a failing deploy job.
RUN aws --version \
    && helm version --short \
    && helmfile version \
    && sops --version \
    && kubectl version --client \
    && helm plugin list \
    && helm plugin list | grep -q secrets \
    && helm plugin list | grep -q diff

ENTRYPOINT ["/bin/bash"]
