#!/bin/bash

# Exit on error
set -e

echo "=== Pulling manylinux image ==="
docker pull quay.io/pypa/manylinux2014_x86_64:latest

echo "=== Building Docker image with CUDA 13.0 ==="
docker build -t manylinux-cuda13 -f Dockerfile.manylinux-cuda13 .

echo "=== Building SageAttention wheel ==="
# Run container with current directory mounted
docker run --rm -it \
    --gpus all \
    -v $(pwd):/app \
    -w /app \
    -e TORCH_CUDA_ARCH_LIST="12.0" \
    -e FORCE_CUDA=1 \
    manylinux-cuda13

echo "=== Build completed ==="
echo "Wheels are in: wheelhouse/"
echo ""
echo "To install on target system:"
echo "pip install wheelhouse/sageattention-*.whl"