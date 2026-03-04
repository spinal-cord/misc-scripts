#!/bin/bash

set -euo pipefail

. /venv/main/bin/activate

# Get total number of packages (skip header lines)
total_packages=$(uv pip list 2>/dev/null | awk 'NR>2' | wc -l)
# Run uv pip list, skip header lines, extract package names, and join with semicolons
packages=$(uv pip list 2>/dev/null | awk 'NR>2 {print $1 "==" $2}' | paste -sd ';' -)

# Check if we got any output
if [ -n "$packages" ]; then
    echo "SETUP: Total number of packages in the UV environment: $total_packages"
    echo "SETUP: Packages in the UV environment: $packages"
else
    echo "SETUP: No packages found or uv command failed."
fi

# Function to calculate and format time difference
# Usage: time_diff <start_seconds> [<end_seconds>]
# If end_seconds is omitted, the current time is used.
time_diff() {
    local start=$1
    local end=${2:-$(date +%s)}
    local diff=$((end - start))

    local minutes=$((diff / 60))
    local seconds=$((diff % 60))

    if (( minutes > 0 )); then
        echo "${minutes}m${seconds}s passed from start"
    else
        echo "${seconds}s passed from start"
    fi
}

start_time=$(date +%s)



cd "$WORKSPACE"
echo 'SETUP: Cloning git repo'
[[ -d "${WORKSPACE}/ai-toolkit" ]] || git clone https://github.com/spinal-cord/ai-toolkit.git
cd ai-toolkit
elapsed=$(time_diff "$start_time")
echo "SETUP: $elapsed (git clone)"
git checkout wan

if [ -z "$HF_PACKAGES" ]; then
    echo "SETUP: HF_PACKAGES is not set or is empty"
    uv pip install torch==2.8.0+cu129 torchvision==0.23.0+cu129 torchaudio==2.8.0+cu129 --index-url https://download.pytorch.org/whl/cu129
    uv pip install setuptools==69.5.1
    uv pip install https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.11/flash_attn-2.8.3+cu129torch2.8-cp312-cp312-linux_x86_64.whl
    uv pip install -r requirements.txt
else
    hf auth login --token "$HF_PACKAGES"
    # HF username extraction
    # hf auth whoami 2>&1 | cat -A
    # ^[[1muser: ^[[0m username123$
    # ^[[1morgs: ^[[0m orgname123$
    HF_USERNAME=$(hf auth whoami 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | awk '/^user:/ {print $2}')
    echo 'SETUP: Downloading HF packages'
    hf download "$HF_USERNAME"/packages_cu129_torch28 --local-dir ./packages_cu129_torch28
    elapsed=$(time_diff "$start_time")
    echo "SETUP: $elapsed (HF packages download)"
    HF_USERNAME=""
    echo 'SETUP: Installing HF packages'
    uv pip install --find-links ./packages_cu129_torch28 --torch-backend=auto -r cu129_torch28_requirements.txt --no-index
    elapsed=$(time_diff "$start_time")
    echo "SETUP: $elapsed (HF packages installation)"
fi


#uv pip install torch==2.10.0 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130

# uv pip install torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu130
# uv pip install torch torchvision torchaudio --torch-backend="${TORCH_BACKEND:-cu130}"
# uv pip install https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.8.3+cu130torch2.10-cp312-cp312-linux_x86_64.whl

# uv pip install https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.6.3+cu130torch2.9-cp312-cp312-linux_x86_64.whl
# uv pip install https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.6.3+cu130torch2.9-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl
# uv pip install timm==1.0.2



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

# cp pipeline_wan.py /venv/main/lib/python3.12/site-packages/diffusers/pipelines/wan/pipeline_wan.py

build_sage_attention () {
    echo 'building sage2'
    cd /workspace/ai-toolkit/
    git clone https://github.com/spinal-cord/SageAttention.git
    cd SageAttention
    uv pip install wheel build
    uv pip install --force-reinstall setuptools
    export TORCH_CUDA_ARCH_LIST="12.0"
    python setup.py bdist_wheel

    #python setup.py install
}

SCRIPT_DL_NAME='big-files-print'
curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/"$SCRIPT_DL_NAME"
chmod +x "$SCRIPT_DL_NAME"
mv "$SCRIPT_DL_NAME" /usr/local/bin/"$SCRIPT_DL_NAME"

SCRIPT_DL_NAME='sha256-verify'
curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/"$SCRIPT_DL_NAME"
chmod +x "$SCRIPT_DL_NAME"
mv "$SCRIPT_DL_NAME" /usr/local/bin/"$SCRIPT_DL_NAME"

cd /workspace/ai-toolkit/

# wget https://github.com/spinal-cord/SageAttention/releases/download/v2.2.0/sageattention-2.2.0-1.cuda12.9.1.torch2.8.0-cp312-cp312-linux_x86_64.whl

# SAGE2_FILE="sageattention-2.2.0-1.cuda12.9.1.torch2.8.0-cp312-cp312-linux_x86_64.whl"
# CHECKSUM_FILE="${SAGE2_FILE}.checksum.sha256"

# echo 'f823084209725f345c455bfebd9f909288dee307b8bbbbef80ce7a0be5e7c062  sageattention-2.2.0-1.cuda12.9.1.torch2.8.0-cp312-cp312-linux_x86_64.whl' > "$CHECKSUM_FILE"

# sha256-verify "$SAGE2_FILE" "$CHECKSUM_FILE" && ( uv pip install "$SAGE2_FILE" && echo 'installed sage2 from wheel' || build_sage_attention ) || echo 'checksum verification FAILED'

if [ -z "$HF_PACKAGES" ]; then
    echo "SETUP: HF_PACKAGES is not set or is empty"
    uv pip install "numpy>=1.22.4,<1.29.0" --force-reinstall
    uv pip install --force-reinstall scipy
else
    echo 'SETUP: Setup complete'
fi

elapsed=$(time_diff "$start_time")
echo "SETUP: $elapsed (Setup complete)"
