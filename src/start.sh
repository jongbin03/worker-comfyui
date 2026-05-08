#!/usr/bin/env bash

export PATH="/opt/venv/bin:/comfyui/.venv/bin:${PATH}"

if [ -n "$PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh
    echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys
    for key_type in rsa ecdsa ed25519; do
        key_file="/etc/ssh/ssh_host_${key_type}_key"
        if [ ! -f "$key_file" ]; then
            ssh-keygen -t "$key_type" -f "$key_file" -q -N ''
        fi
    done
    service ssh start && echo "worker-comfyui: SSH server started" || echo "worker-comfyui: SSH server could not be started" >&2
fi

TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

echo "worker-comfyui: Checking GPU availability..."
if ! GPU_CHECK=$(/comfyui/.venv/bin/python -c "
import torch
try:
    torch.cuda.init()
    name = torch.cuda.get_device_name(0)
    print(f'OK: {name}')
except Exception as e:
    print(f'FAIL: {e}')
    exit(1)
" 2>&1); then
    echo "worker-comfyui: GPU is not available. PyTorch CUDA init failed:"
    echo "worker-comfyui: $GPU_CHECK"
    exit 1
fi
echo "worker-comfyui: GPU available — $GPU_CHECK"

comfy-manager-set-mode offline || echo "worker-comfyui - Could not set ComfyUI-Manager network_mode" >&2

# ── InsightFace model cache 연결 ─────────────────────────────
# IPAdapterInsightFaceLoader는 insightface 루트 아래 models/<model_name> 캐시를 확인한다.
# 현재 노드는 /comfyui/models/insightface/models/buffalo_l을 download_path로 쓰므로,
# 네트워크 볼륨의 buffalo_l을 이 경로에 연결하지 않으면 워크플로우 중 다시 다운로드한다.
INSIGHTFACE_MODEL_NAME="${INSIGHTFACE_MODEL_NAME:-buffalo_l}"
INSIGHTFACE_VOLUME_DIRS=(
    "/runpod-volume/runpod-slim/ComfyUI/models/insightface/models"
    "/runpod-volume/runpod-slim/ComfyUI/models/insightface"
    "/runpod-volume/models/insightface/models"
    "/runpod-volume/models/insightface"
)
INSIGHTFACE_CACHE_DIRS=(
    "/comfyui/models/insightface/models"
    "/root/.insightface/models"
)

echo "worker-comfyui: Checking InsightFace model cache for ${INSIGHTFACE_MODEL_NAME}..."
INSIGHTFACE_SOURCE=""
for dir in "${INSIGHTFACE_VOLUME_DIRS[@]}"; do
    if [ -d "${dir}/${INSIGHTFACE_MODEL_NAME}" ]; then
        INSIGHTFACE_SOURCE="${dir}/${INSIGHTFACE_MODEL_NAME}"
        break
    fi
    if [ -d "${dir}" ] && find "${dir}" -maxdepth 1 -type f -name "*.onnx" | grep -q .; then
        INSIGHTFACE_SOURCE="${dir}"
        break
    fi
done

if [ -n "${INSIGHTFACE_SOURCE}" ]; then
    for cache_dir in "${INSIGHTFACE_CACHE_DIRS[@]}"; do
        mkdir -p "${cache_dir}"
        if [ -e "${cache_dir}/${INSIGHTFACE_MODEL_NAME}" ]; then
            echo "worker-comfyui: InsightFace cache already exists: ${cache_dir}/${INSIGHTFACE_MODEL_NAME}"
        else
            ln -s "${INSIGHTFACE_SOURCE}" "${cache_dir}/${INSIGHTFACE_MODEL_NAME}"
            echo "worker-comfyui: Linked InsightFace model: ${cache_dir}/${INSIGHTFACE_MODEL_NAME} -> ${INSIGHTFACE_SOURCE}"
        fi
    done
else
    echo "worker-comfyui: InsightFace model not found on Network Volume; insightface may download ${INSIGHTFACE_MODEL_NAME} at runtime."
    for cache_dir in "${INSIGHTFACE_CACHE_DIRS[@]}"; do
        echo "worker-comfyui: Expected cache path: ${cache_dir}/${INSIGHTFACE_MODEL_NAME}"
    done
fi

# 기존 IPAdapter 노드는 이 경로를 download_path로 사용한다.
if [ -e "/comfyui/models/insightface/models/${INSIGHTFACE_MODEL_NAME}" ]; then
    if [ -L "/comfyui/models/insightface/models/${INSIGHTFACE_MODEL_NAME}" ]; then
        echo "worker-comfyui: Active InsightFace cache symlink target: $(readlink /comfyui/models/insightface/models/${INSIGHTFACE_MODEL_NAME})"
    else
        echo "worker-comfyui: Active InsightFace cache directory: /comfyui/models/insightface/models/${INSIGHTFACE_MODEL_NAME}"
    fi
fi
# ─────────────────────────────────────────────────────────────

# ── Network Volume custom_nodes 복사 ──────────────────────────
if [ "${COPY_CUSTOM_NODES_FROM_VOLUME:-false}" = "true" ]; then
    echo "worker-comfyui: Copying custom_nodes from Network Volume..."
    if [ -d "/runpod-volume/runpod-slim/ComfyUI/custom_nodes" ]; then
        rm -rf /comfyui/custom_nodes/custom_nodes
        cp -r /runpod-volume/runpod-slim/ComfyUI/custom_nodes/* /comfyui/custom_nodes/ 2>/dev/null \
            || echo "worker-comfyui: No custom nodes to copy"
        echo "worker-comfyui: Custom nodes copy done."
        ls -la /comfyui/custom_nodes/
    else
        echo "worker-comfyui: No custom_nodes dir in Network Volume."
    fi
else
    echo "worker-comfyui: Using baked-in custom_nodes."
fi
# ─────────────────────────────────────────────────────────────

echo "worker-comfyui: Starting ComfyUI"
: "${COMFY_LOG_LEVEL:=DEBUG}"
COMFY_PID_FILE="/tmp/comfyui.pid"

if [ "$SERVE_API_LOCALLY" == "true" ]; then
    /comfyui/.venv/bin/python -u /comfyui/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"
    echo "worker-comfyui: Starting RunPod Handler"
    /opt/venv/bin/python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    /comfyui/.venv/bin/python -u /comfyui/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"
    echo "worker-comfyui: Starting RunPod Handler"
    /opt/venv/bin/python -u /handler.py
fi
