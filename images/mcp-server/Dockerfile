# Support-tools MCP server (streamable HTTP on :8000/mcp).
# Base pinned by digest; dependencies pinned *and* hash-checked
# (requirements.txt is `uv pip compile --generate-hashes` of requirements.in).
FROM python:3.13.17-slim-trixie@sha256:fe14fd57a4c0361110eaa0c284112b189750bcb43fb04bb5d1ee7b7744027ccf

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --require-hashes --no-deps -r requirements.txt
COPY server.py .

USER 65532:65532
EXPOSE 8000
CMD ["python", "server.py"]
