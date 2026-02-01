#!/bin/bash

set -euo pipefail
# CLEAN SYSTEM-WIDE CUDA 12.8 INSTALLATION

echo "=========================================="
echo "CLEAN INSTALL: CUDA 12.8 (Overwriting 13.0)"
echo "=========================================="

# 1. REMOVE ALL EXISTING CUDA PACKAGES AND SOURCES
echo "Step 1: Removing existing CUDA installations..."
sudo apt purge "cuda*" "nvidia-cuda*" "libcudnn*" -y
sudo apt autoremove -y

# Clean up any leftover CUDA files
sudo rm -rf /usr/local/cuda*
sudo rm -rf /opt/cuda
sudo rm -rf /etc/apt/sources.list.d/*cuda*
sudo rm -rf /etc/apt/sources.list.d/*nvidia*
sudo rm -f /usr/share/keyrings/cuda-archive-keyring.gpg
sudo rm -f /etc/apt/trusted.gpg.d/cuda-archive-keyring.gpg

# 2. DOWNLOAD AND INSTALL CUDA 12.8 RUNFILE
echo "Step 2: Downloading CUDA 12.8 runfile installer..."
wget https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda_12.8.0_570.86.10_linux.run
chmod +x cuda_12.8.0_570.86.10_linux.run

echo "Step 3: Installing CUDA 12.8 (this takes 2-5 minutes)..."
# INSTALL ONLY TOOLKIT (skip driver if you already have one)
sudo ./cuda_12.8.0_570.86.10_linux.run \
    --silent \
    --toolkit \
    --toolkitpath=/usr/local/cuda-12.8 \
    --no-opengl-libs \
    --override

# 3. FORCE SYSTEM-WIDE SYMLINK UPDATE
echo "Step 4: Forcing system-wide symlink to CUDA 12.8..."
sudo rm -f /usr/local/cuda
sudo ln -sf /usr/local/cuda-12.8 /usr/local/cuda

# 4. OVERWRITE ENVIRONMENT FOR ALL USERS
echo "Step 5: Setting global environment variables..."

# Overwrite global profile (not append)
sudo tee /etc/profile.d/cuda.sh > /dev/null << 'EOF'
#!/bin/sh
# System-wide CUDA configuration - OVERWRITES PREVIOUS
export CUDA_HOME=/usr/local/cuda
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:$LD_LIBRARY_PATH
EOF

# Update system library paths
sudo tee /etc/ld.so.conf.d/cuda.conf > /dev/null << 'EOF'
/usr/local/cuda/lib64
/usr/local/cuda/extras/CUPTI/lib64
EOF

# 5. IMMEDIATELY APPLY CHANGES
echo "Step 6: Applying changes immediately..."
# Update library cache
sudo ldconfig

# Force PATH update in current shell
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH

# 6. VERIFICATION
echo ""
echo "=========================================="
echo "VERIFICATION:"
echo "=========================================="

# Check installation
if [ -d "/usr/local/cuda-12.8" ]; then
    echo "✓ CUDA 12.8 installed at: /usr/local/cuda-12.8"
else
    echo "✗ CUDA 12.8 NOT found!"
    exit 1
fi

# Check symlink
SYMLINK_TARGET=$(readlink -f /usr/local/cuda)
if [ "$SYMLINK_TARGET" = "/usr/local/cuda-12.8" ]; then
    echo "✓ System symlink points to CUDA 12.8"
else
    echo "✗ Symlink incorrect: $SYMLINK_TARGET"
fi

echo ""
echo "Run these commands to verify:"
echo "1. nvcc --version    (should show 12.8)"
echo "2. ls -l /usr/local/cuda"
echo "3. echo \$PATH | grep cuda"
echo ""
echo "If still showing 13.0, REBOOT or open a NEW terminal."
echo "=========================================="

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
torch_backend=cu128
# Convert versions like "12.7" and "12.8" to integers "127" and "128" for comparison
cuda_version_int=$(echo "$cuda_version" | awk -F. '{printf "%d%d", $1, $2}')
threshold_version_int=128
if (( cuda_version_int < threshold_version_int )); then
    torch_backend=cu126
fi

uv pip install torch==${TORCH_VERSION:-2.7.1} torchvision torchaudio --torch-backend="${TORCH_BACKEND:-$torch_backend}"
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


curl -o big-files-print https://raw.githubusercontent.com/spinal-cord/misc-scripts/refs/heads/main/big-files-print
chmod +x big-files-print
mv big-files-print /usr/local/bin/big-files-print

# Create Wan2GP restart scripts
cat > /usr/local/bin/restart << 'EOL'
#!/bin/bash
supervisorctl restart wan2gp
EOL

chmod +x /usr/local/bin/restart

cd /workspace/Wan2GP/
git clone https://github.com/spinal-cord/SageAttention.git
cd SageAttention
python setup.py install
