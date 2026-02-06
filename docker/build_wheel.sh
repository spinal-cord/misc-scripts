#!/bin/bash

# Exit on error
set -e

echo "=== Building SageAttention wheel ==="

# Clean previous builds
rm -rf build/ dist/ *.egg-info/

# Set build environment
export TORCH_CUDA_ARCH_LIST="12.0"
export FORCE_CUDA=1
export CUDA_HOME=/usr/local/cuda-13.0
export MAX_JOBS=8

# Build the wheel using the manylinux Python
/opt/python/cp312-cp312/bin/python setup.py bdist_wheel

echo "=== Wheel built successfully ==="
ls -la dist/

echo "=== Repairing wheel with auditwheel ==="
/opt/python/cp312-cp312/bin/pip install auditwheel
for whl in dist/*.whl; do
    echo "Repairing $whl"
    /opt/python/cp312-cp312/bin/auditwheel repair "$whl" --plat manylinux_2_17_x86_64
done

echo "=== Final wheels ==="
ls -la wheelhouse/