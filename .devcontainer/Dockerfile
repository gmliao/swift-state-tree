FROM swift:6.4.3-noble@sha256:4ed5e0210b244aab174450e0b79014c17db60c63c6daf0709347fe50c767293a

# Verify Swift installation
RUN swift --version && \
    which swift && \
    ls -la /usr/bin/swift* || echo "Swift verification completed"

# ShellCheck 0.11.0, the version CI pins (build-and-test.yml, the shellcheck job), so
# scripts/pre-push-checks.sh can run its shellcheck step here. The release asset for this
# architecture, checked against its sha256 before it is installed.
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    dir="$(mktemp -d)"; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x86_64; sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;; \
      arm64) arch=aarch64; sha=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;; \
      *) echo "no ShellCheck 0.11.0 asset for $(dpkg --print-architecture)"; exit 1 ;; \
    esac; \
    curl -sSfL --retry 3 --retry-all-errors -o "$dir/shellcheck.tar.xz" \
      "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.${arch}.tar.xz"; \
    echo "${sha}  $dir/shellcheck.tar.xz" | sha256sum -c -; \
    tar -xJf "$dir/shellcheck.tar.xz" -C "$dir"; \
    install -m 0755 "$dir/shellcheck-v0.11.0/shellcheck" /usr/local/bin/shellcheck; \
    rm -rf "$dir"; \
    shellcheck --version

# Create workspace directory
RUN mkdir -p /workspace

# Set working directory
WORKDIR /workspace

