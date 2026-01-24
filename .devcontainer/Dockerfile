FROM swift:6.2

# Verify Swift installation
RUN swift --version && \
    which swift && \
    ls -la /usr/bin/swift* || echo "Swift verification completed"

# Create workspace directory
RUN mkdir -p /workspace

# Set working directory
WORKDIR /workspace

