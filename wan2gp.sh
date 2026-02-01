#!/bin/bash

set -euo pipefail

echo "Downloading CUDA 12.8 runfile installer..."
wget https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda_12.8.0_570.86.10_linux.run

echo "Installing CUDA Toolkit (this may take a few minutes)..."
sudo sh cuda_12.8.0_570.86.10_linux.run --silent --toolkit --override

echo "Setting up environment variables..."
echo 'export PATH=/usr/local/cuda-12.8/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc

# Apply changes to current shell
export PATH=/usr/local/cuda-12.8/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:$LD_LIBRARY_PATH
sudo ldconfig

echo "CUDA 12.8 installation complete."

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
