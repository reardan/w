#!/bin/sh
# Fetches the tiny-shakespeare corpus (~1.1MB of char-level training
# text, the canonical nanoGPT dataset) into bin/shakespeare.txt from
# karpathy's char-rnn repository. Used by the opt-in gpt_train_gpu_test
# target; cached across runs because bin/ persists until `rm -rf bin`.
set -e
mkdir -p bin
if [ ! -f bin/shakespeare.txt ]; then
	curl -fsSL "https://raw.githubusercontent.com/karpathy/char-rnn/master/data/tinyshakespeare/input.txt" -o bin/shakespeare.txt
fi
