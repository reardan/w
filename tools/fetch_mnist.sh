#!/bin/sh
# Fetches the four MNIST IDX files into bin/mnist/ (skipping any that are
# already present) from PyTorch's S3 mirror of the original LeCun files.
# Used by the opt-in mnist_train_gpu_test target; ~11MB total download,
# cached across runs because bin/mnist/ persists until `rm -rf bin`.
set -e
mkdir -p bin/mnist
for f in train-images-idx3-ubyte train-labels-idx1-ubyte t10k-images-idx3-ubyte t10k-labels-idx1-ubyte; do
	if [ ! -f "bin/mnist/$f" ]; then
		curl -fsSL "https://ossci-datasets.s3.amazonaws.com/mnist/$f.gz" -o "bin/mnist/$f.gz"
		gunzip -f "bin/mnist/$f.gz"
	fi
done
