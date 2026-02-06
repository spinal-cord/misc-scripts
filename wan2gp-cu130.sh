#!/bin/bash

set -euo pipefail

. /venv/main/bin/activate

apt-get install -y \
    libasound2-dev \
    pulseaudio-utils \
    --no-install-recommends

cd "$WORKSPACE"
[[ -d "${WORKSPACE}/Wan2GP" ]] || git clone https://github.com/spinal-cord/Wan2GP
cd Wan2GP
[[ -n "{WAN2GP_VERSION:-}" ]] && git checkout "$WAN2GP_VERSION"

# Find the most appropriate backend given W2GP's torch version restrictions
if [[ -z "${CUDA_VERSION:-}" ]]; then
    echo "Error: CUDA_VERSION is not set or is empty." >&2
    exit 1
fi
cuda_version=$(echo "$CUDA_VERSION" | cut -d. -f1,2)
torch_backend=cu130
# Convert versions like "12.7" and "12.8" to integers "127" and "128" for comparison
cuda_version_int=$(echo "$cuda_version" | awk -F. '{printf "%d%d", $1, $2}')
threshold_version_int=130
if (( cuda_version_int < threshold_version_int )); then
    torch_backend=cu130
fi

uv pip install torch==${TORCH_VERSION:-2.10.0} torchvision torchaudio --torch-backend="${TORCH_BACKEND:-$torch_backend}"
uv pip install -r requirements.txt

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

# Create Wan2GP restart scripts
cat > /usr/local/bin/restart << 'EOL'
#!/bin/bash
supervisorctl restart wan2gp
EOL

chmod +x /usr/local/bin/restart

uv pip install torchcodec

build_sage_attention () {
    echo 'building sage2'
    cd /workspace/Wan2GP/
    git clone https://github.com/spinal-cord/SageAttention.git
    cd SageAttention
    uv pip install wheel build
    export TORCH_CUDA_ARCH_LIST="12.0"
    python setup.py bdist_wheel

    #python setup.py install
}

build_sage_attention_docker () {
    cd /workspace/Wan2GP/
    git clone https://github.com/spinal-cord/SageAttention.git
    cd SageAttention

    SCRIPT_DL_NAME='setup_docker.sh'
    curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/docker/$SCRIPT_DL_NAME
    chmod +x "$SCRIPT_DL_NAME"

    SCRIPT_DL_NAME='Dockerfile.manylinux-cuda13'
    curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/docker/$SCRIPT_DL_NAME
    chmod +x "$SCRIPT_DL_NAME"

    SCRIPT_DL_NAME='build_manylinux_wheel.sh'
    curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/docker/$SCRIPT_DL_NAME
    chmod +x "$SCRIPT_DL_NAME"

    SCRIPT_DL_NAME='build_wheel.sh'
    curl -o "$SCRIPT_DL_NAME" https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/docker/$SCRIPT_DL_NAME
    chmod +x "$SCRIPT_DL_NAME"

    ./setup_docker.sh
    ./build_manylinux_wheel.sh
}

cd /workspace/Wan2GP/

wget https://github.com/spinal-cord/SageAttention/releases/download/v2.2.0/sageattention-2.2.0-1.cuda13.0.torch2.10.0-cp312-cp312-linux_x86_64.whl

SAGE2_FILE="sageattention-2.2.0-1.cuda13.0.torch2.10.0-cp312-cp312-linux_x86_64.whl"
CHECKSUM_FILE="${SAGE2_FILE}.checksum.sha256"

echo 'cb654f3aac0df90ebf5191ec0dabb95f729c13eeba7652d25069f7d603eedbc6  sageattention-2.2.0-1.cuda13.0.torch2.10.0-cp312-cp312-linux_x86_64.whl' > "$CHECKSUM_FILE"

sha256-verify "$SAGE2_FILE" "$CHECKSUM_FILE" && ( uv pip install "$SAGE2_FILE" && echo 'installed sage2 from wheel' || build_sage_attention ) || echo 'checksum verification FAILED'

restart