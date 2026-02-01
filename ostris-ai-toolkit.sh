#!/bin/bash

set -euo pipefail

. /venv/main/bin/activate

cd "$WORKSPACE"
[[ -d "${WORKSPACE}/ai-toolkit" ]] || git clone https://github.com/spinal-cord/ai-toolkit.git
cd ai-toolkit
git checkout i2v-main


uv pip install torch==2.10.0 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130
# uv pip install torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu130
# uv pip install torch torchvision torchaudio --torch-backend="${TORCH_BACKEND:-cu130}"
uv pip install https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.8.3+cu130torch2.10-cp312-cp312-linux_x86_64.whl
# uv pip install https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.6.3+cu130torch2.9-cp312-cp312-linux_x86_64.whl
# uv pip install https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.6.3+cu130torch2.9-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl
# uv pip install timm==1.0.2
uv pip install -r requirements.txt



# export CUDA_HOME=/usr/local/cuda-13.0  # Point to CUDA 13.0
# export TORCH_CUDA_ARCH_LIST="10.0+PTX"  # Blackwell compute capability
# FLASH_ATTENTION_FORCE_BUILD=TRUE MAX_JOBS=8 uv pip install flash-attn --no-build-isolation


# Create AI Toolkit startup script
cat > /opt/supervisor-scripts/ai-toolkit.sh << 'EOL'
#!/bin/bash

kill_subprocesses() {
    local pid=$1
    local subprocesses=$(pgrep -P "$pid")
    
    for process in $subprocesses; do
        kill_subprocesses "$process"
    done
    
    if [[ -n "$subprocesses" ]]; then
        kill -TERM $subprocesses 2>/dev/null
    fi
}

cleanup() {
    kill_subprocesses $$
    sleep 2
    pkill -KILL -P $$ 2>/dev/null
    exit 0
}

trap cleanup EXIT INT TERM

# User can configure startup by removing the reference in /etc/portal.yaml - So wait for that file and check it
while [ ! -f "$(realpath -q /etc/portal.yaml 2>/dev/null)" ]; do
    echo "Waiting for /etc/portal.yaml before starting ${PROC_NAME}..." | tee -a "/var/log/portal/${PROC_NAME}.log"
    sleep 1
done

# Check for Wan Text in the portal config
search_term="AI Toolkit"
search_pattern=$(echo "$search_term" | sed 's/[ _-]/[ _-]/g')
if ! grep -qiE "^[^#].*${search_pattern}" /etc/portal.yaml; then
    echo "Skipping startup for ${PROC_NAME} (not in /etc/portal.yaml)" | tee -a "/var/log/portal/${PROC_NAME}.log"
    exit 0
fi

echo "Starting AI Toolkit" | tee "/var/log/portal/${PROC_NAME}.log"
. /venv/main/bin/activate
. /opt/nvm/nvm.sh

cd "${WORKSPACE}/ai-toolkit/ui"
${AI_TOOLKIT_START_CMD:-npm run build_and_start} 2>&1 | tee "/var/log/portal/${PROC_NAME}.log"

EOL

chmod +x /opt/supervisor-scripts/ai-toolkit.sh

# Generate the supervisor config files
cat > /etc/supervisor/conf.d/ai-toolkit.conf << 'EOL'
[program:ai-toolkit]
environment=PROC_NAME="%(program_name)s"
command=/opt/supervisor-scripts/ai-toolkit.sh
autostart=true
autorestart=true
exitcodes=0
startsecs=0
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=10
# This is necessary for Vast logging to work alongside the Portal logs (Must output to /dev/stdout)
stdout_logfile=/dev/stdout
redirect_stderr=true
stdout_events_enabled=true
stdout_logfile_maxbytes=0
stdout_logfile_backups=0
EOL

# Update supervisor to start the new service
supervisorctl reread
supervisorctl update

curl -o big-files-print https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/big-files-print
chmod +x big-files-print
mv big-files-print /usr/local/bin/big-files-print
