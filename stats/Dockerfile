# Pinned by patch for reproducible builds. For full reproducibility pin by
# digest instead, e.g.:
#   FROM python:3.13.11-slim@sha256:<digest>
FROM python:3.13-slim

# Observability + predictable, network-resilient builds.
ENV \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=60

# Dedicated non-root identity. Avoids the homeless `nobody` account and gives a
# stable uid/gid for host bind-mounts.
RUN groupadd --system --gid 10001 appgroup \
    && useradd --system --uid 10001 --gid appgroup --home-dir /app --no-create-home appuser

WORKDIR /app

# Install dependencies into an isolated virtualenv. psycopg ships manylinux
# wheels, so no compiler toolchain is required.
COPY requirements.txt /tmp/requirements.txt
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && python -m venv /opt/venv \
    && /opt/venv/bin/python -m pip install --no-cache-dir --requirement /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt
ENV PATH="/opt/venv/bin:${PATH}"

# Application code (cached until src/ changes).
COPY --chown=appuser:appgroup src/ /app/src/
# Make the working dir writable so the sqlite fallback can persist data.
RUN chown appuser:appgroup /app
ENV PYTHONPATH=/app/src

USER appuser

# Document the backend bind port (STATS_APP_PORT, default 8088); not a security
# boundary, and does not grant host access.
EXPOSE 8088

LABEL \
    org.opencontainers.image.title="xray-relay-mesh stats" \
    org.opencontainers.image.description="Central stats collector for xray-relay-mesh" \
    org.opencontainers.image.source="https://github.com/Kisialeu/xray-relay-mesh"

# /api/health returns 200 without auth and reads STATS_APP_PORT at runtime.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('STATS_APP_PORT',os.environ.get('STATS_WEB_PORT','8088'))+'/api/health', timeout=3)"

CMD ["python", "/app/src/__main__.py"]
