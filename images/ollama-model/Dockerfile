# Ollama with the model baked in, so the ai-models namespace never needs
# internet egress. Built locally (`make build-images`) and imported into k3d as
# localhost/secure-ai-gateway/ollama:<ollama version>-<model tag>.
ARG OLLAMA_IMAGE=ollama/ollama:0.40.8@sha256:2b8eecdb85aa6ea67c381c8ecffec04b2658496cf2821a8f88b0485bdff198e8

# --- build stage: start a throwaway server and pull the model into /models
FROM ${OLLAMA_IMAGE} AS pull
ARG MODEL=qwen2.5:1.5b
ENV OLLAMA_MODELS=/models
RUN ollama serve >/tmp/serve.log 2>&1 & \
    for i in $(seq 1 30); do ollama list >/dev/null 2>&1 && break; sleep 1; done; \
    ollama pull "${MODEL}" && ollama list

# --- final stage: the official image's Ubuntu base + the CPU runtime only.
# The upstream image is ~7 GB, 3.6 GB of it CUDA/JetPack libraries that a
# CPU-only k3d node never loads (and `k3d image import` copies to every node).
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac
COPY --from=pull /usr/bin/ollama /usr/bin/ollama
COPY --from=pull /usr/lib/ollama/lib* /usr/lib/ollama/llama-* /usr/lib/ollama/
COPY --from=pull /usr/lib/ollama/*LICENSE /usr/share/doc/ollama/
COPY --from=pull --chown=0:0 --chmod=0755 /models /models
ENV OLLAMA_MODELS=/models \
    OLLAMA_HOST=0.0.0.0:11434 \
    # Ollama writes its identity key under $HOME/.ollama; point it at an emptyDir.
    HOME=/home/ollama \
    # Never touch the baked-in blobs (the model dir is read-only at runtime).
    OLLAMA_NOPRUNE=1 \
    OLLAMA_KEEP_ALIVE=30m
USER 65532:65532
EXPOSE 11434
ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
