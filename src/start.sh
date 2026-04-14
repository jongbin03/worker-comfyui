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

# ── Network Volume custom_nodes 복사 ──────────────────────────
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