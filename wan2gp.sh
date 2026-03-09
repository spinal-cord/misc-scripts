#!/bin/bash

set -euo pipefail
. /venv/main/bin/activate

# Get total number of packages (skip header lines)
total_packages=$(uv pip list 2>/dev/null | awk 'NR>2' | wc -l)
# Run uv pip list, skip header lines, extract package names, and join with semicolons
packages=$(uv pip list 2>/dev/null | awk 'NR>2 {print $1 "==" $2}' | paste -sd ';' -)

# Check if we got any output
if [ -n "$packages" ]; then
    echo "SETUP: Total number of packages in the initial UV environment: $total_packages"
    echo "SETUP: Packages in the initial UV environment: $packages"
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
[[ -d "${WORKSPACE}/Wan2GP" ]] || git clone https://github.com/spinal-cord/Wan2GP
cd Wan2GP
elapsed=$(time_diff "$start_time")
echo "SETUP: $elapsed (git clone)"
[[ -n "{WAN2GP_VERSION:-}" ]] && git checkout main

# Find the most appropriate backend given W2GP's torch version restrictions
if [[ -z "${CUDA_VERSION:-}" ]]; then
    echo "Error: CUDA_VERSION is not set or is empty." >&2
    exit 1
fi
cuda_version=$(echo "$CUDA_VERSION" | cut -d. -f1,2)
torch_backend=cu128
# Convert versions like "12.7" and "12.8" to integers "127" and "128" for comparison
cuda_version_int=$(echo "$cuda_version" | awk -F. '{printf "%d%d", $1, $2}')
threshold_version_int=128
if (( cuda_version_int < threshold_version_int )); then
    torch_backend=cu126
fi

apt-get install -y \
    libasound2-dev \
    pulseaudio-utils \
    --no-install-recommends

if [ -z "$HF_PACKAGES" ]; then
    echo "SETUP: HF_PACKAGES is not set or is empty"
    uv pip install torch==${TORCH_VERSION:-2.7.1} torchvision torchaudio --torch-backend="${TORCH_BACKEND:-$torch_backend}"
    uv pip install -r requirements.txt
else
    hf auth login --token "$HF_PACKAGES"
    # HF username extraction
    # hf auth whoami 2>&1 | cat -A
    # ^[[1muser: ^[[0m username123$
    # ^[[1morgs: ^[[0m orgname123$
    HF_USERNAME=$(hf auth whoami 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | awk '/^user:/ {print $2}')
    echo 'SETUP: Downloading HF packages'
    hf download "$HF_USERNAME"/python_requirements --local-dir ./python_requirements
    hf download "$HF_USERNAME"/packages_cu128_torch27 --local-dir ./packages_cu128_torch27
    
    hf download "$HF_USERNAME"/attention_py_wheels 'flash_attn-2.7.4+cu128torch2.7-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl' --local-dir ./attention_py_wheels
    hf download "$HF_USERNAME"/attention_py_wheels 'xformers-0.0.32+eb0946a3.d20260308-1.cuda12.8.torch2.7.1-cp39-abi3-linux_x86_64.whl' --local-dir ./attention_py_wheels
    hf download "$HF_USERNAME"/attention_py_wheels 'sageattention-2.2.0-1.cuda12.8.torch2.7.1-cp312-cp312-linux_x86_64.whl' --local-dir ./attention_py_wheels
    hf download "$HF_USERNAME"/attention_py_wheels 'sageattn3-1.0.0-1.cuda12.8.torch2.7.1-cp312-cp312-linux_x86_64.whl' --local-dir ./attention_py_wheels

    elapsed=$(time_diff "$start_time")
    echo "SETUP: $elapsed (HF packages download)"
    HF_USERNAME=""
    echo 'SETUP: Installing HF packages'
    # RTX 5090
    uv pip install --find-links ./packages_cu128_torch27 --torch-backend=auto -r ./python_requirements/wan2gp_2026-02-22_cu128_torch27-requirements.txt --no-index
    uv pip install --find-links ./attention_py_wheels --find-links ./packages_cu128_torch27 --torch-backend=auto flash_attn xformers sageattention sageattn3 --no-index
fi

elapsed=$(time_diff "$start_time")
echo "SETUP: $elapsed (HF packages installation)"

# Create Wan2GP startup scripts
cat > /opt/supervisor-scripts/wan2gp.sh << 'EOL'
#!/bin/bash

utils=/opt/supervisor-scripts/utils
. "${utils}/logging.sh"
. "${utils}/cleanup_generic.sh"
. "${utils}/environment.sh"
. "${utils}/exit_serverless.sh"
. "${utils}/exit_portal.sh" "Wan2GP"

echo "Starting Wan2GP"

. /etc/environment
. /venv/main/bin/activate

cd "${WORKSPACE}/Wan2GP"
export XDG_RUNTIME_DIR=/tmp
export SDL_AUDIODRIVER=dummy
python wgp.py 2>&1

EOL

chmod +x /opt/supervisor-scripts/wan2gp.sh

# Generate the supervisor config files
cat > /etc/supervisor/conf.d/wan2gp.conf << 'EOL'
[program:wan2gp]
environment=PROC_NAME="%(program_name)s"
command=/opt/supervisor-scripts/wan2gp.sh
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

SCRIPT_DL_NAME='big-files-print'
curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/"$SCRIPT_DL_NAME"
chmod +x "$SCRIPT_DL_NAME"
mv "$SCRIPT_DL_NAME" /usr/local/bin/"$SCRIPT_DL_NAME"

SCRIPT_DL_NAME='sha256-verify'
curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/"$SCRIPT_DL_NAME"
chmod +x "$SCRIPT_DL_NAME"
mv "$SCRIPT_DL_NAME" /usr/local/bin/"$SCRIPT_DL_NAME"

SCRIPT_DL_NAME='wanclear'
curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/"$SCRIPT_DL_NAME"
chmod +x "$SCRIPT_DL_NAME"
mv "$SCRIPT_DL_NAME" /usr/local/bin/"$SCRIPT_DL_NAME"

SCRIPT_DL_NAME='generate_index'
curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/"$SCRIPT_DL_NAME"
chmod +x "$SCRIPT_DL_NAME"
mv "$SCRIPT_DL_NAME" /usr/local/bin/"$SCRIPT_DL_NAME"

# Create Wan2GP restart scripts
cat > /usr/local/bin/restart << 'EOL'
#!/bin/bash

# Check if /usr/local/bin/wanclear exists
if [ -f "/usr/local/bin/wanclear" ]; then
    # Check if it's executable
    if [ -x "/usr/local/bin/wanclear" ]; then
        wanclear
    else
        echo "/usr/local/bin/wanclear exists but it is NOT executable"
        echo "You can make it executable with: chmod +x /usr/local/bin/wanclear"
    fi
else
    echo "/usr/local/bin/wanclear does not exist"
    echo "=== Searching in PATH ==="
    if command -v wanclear &> /dev/null; then
        # echo "wanclear found elsewhere in PATH: $(command -v wanclear)"
        wanclear
    else
        echo "wanclear not found anywhere in PATH"
    fi
fi

rm -rf /workspace/Wan2GP/outputs

supervisorctl restart wan2gp
EOL

chmod +x /usr/local/bin/restart

# Create uv environment unset script
cat > /usr/local/bin/uv_unset << 'EOL'
#!/bin/bash
# Remove the virtual environment activation from PATH
export PATH=$(echo $PATH | sed 's|/venv/test2/bin:||g')  # Adjust path if test2 is elsewhere

# Unset the virtual environment variable
unset VIRTUAL_ENV

# Reset the prompt
export PS1="\u@\h:\w\$ "

# Re-activate just conda if you want it
source /venv/main/bin/activate
EOL

chmod +x /usr/local/bin/uv_unset

cd /workspace/Wan2GP/
#git clone https://github.com/spinal-cord/SageAttention.git
#cd /workspace/Wan2GP/SageAttention
#python setup.py install

# wget https://github.com/spinal-cord/SageAttention/releases/download/v2.2.0/sageattention-2.2.0-1.cuda12.8.torch2.7.1-cp312-cp312-linux_x86_64.whl

# SAGE2_FILE="sageattention-2.2.0-1.cuda12.8.torch2.7.1-cp312-cp312-linux_x86_64.whl"
# CHECKSUM_FILE="${SAGE2_FILE}.checksum.sha256"

# echo 'b231d66b153b0fa0e7cd8648771b9fb85309de990418acc7766ec8deeaaa2553 sageattention-2.2.0-1.cuda12.8.torch2.7.1-cp312-cp312-linux_x86_64.whl' > "$CHECKSUM_FILE"

# sha256-verify "$SAGE2_FILE" "$CHECKSUM_FILE" && uv pip install "$SAGE2_FILE" || exit 1

restart

elapsed=$(time_diff "$start_time")
echo "SETUP: $elapsed (Setup complete)"
echo -n "SETUP: nvcc --version; cuda == " && nvcc --version | grep -oP 'release \K[\d.]+' | tr -d '.' | sed 's/^/cu/'
echo -n "SETUP: torch.version == " && python -c "import torch; print(torch.__version__)"
echo -n "SETUP: numpy.version == " && python -c "import numpy; print(numpy.__version__)"
echo -n "SETUP: flash-attn.version == " && python -c "import flash_attn; print(flash_attn.__version__)"
echo -n "SETUP: version('flash-attn-3') == " && python -c "from importlib.metadata import version; print(version('flash-attn-3'))"
echo -n "SETUP: pkg_resources.get_distribution('xformers').version == " && python -c "import pkg_resources; print(pkg_resources.get_distribution('xformers').version if pkg_resources.get_distribution('xformers') else 'No package metadata found')" 2>/dev/null || echo "Not found"
echo -n "SETUP: version('sageattention') == " && python -c "from importlib.metadata import version; print(version('sageattention'))"
echo -n "SETUP: version('sageattn3') == " && python -c "from importlib.metadata import version; print(version('sageattn3'))"

# wget https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.8.3+cu128torch2.7-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl
# FLASH2_FILE="flash_attn-2.8.3+cu128torch2.7-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl"
# uv pip install "$FLASH2_FILE"

# wget https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.7.16/flash_attn-2.7.4+cu128torch2.7-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl
# FLASH2_FILE="flash_attn-2.7.4+cu128torch2.7-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl"
# uv pip install "$FLASH2_FILE"

# wget https://github.com/spinal-cord/SageAttention/releases/download/v2.2.0/sageattn3-1.0.0-1.cuda12.8.torch2.7.1-cp312-cp312-linux_x86_64.whl
# SAGE3_FILE="sageattn3-1.0.0-1.cuda12.8.torch2.7.1-cp312-cp312-linux_x86_64.whl"
# uv pip install "$SAGE3_FILE"

# wget https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.8.2/flash_attn_3-3.0.0+cu128torch2.7gite2743ab-cp39-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl
# FLASH3_FILE="flash_attn_3-3.0.0+cu128torch2.7gite2743ab-cp39-abi3-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl"
# uv pip install "$FLASH3_FILE"