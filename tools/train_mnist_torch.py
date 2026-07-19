#!/usr/bin/env python3
"""Trains the Stage 6 interop fixture (docs/projects/torch.md): a small
MNIST MLP in PyTorch, exported as tests/data/mnist_mlp.safetensors in
torch's native state_dict layout (fc*.weight is (out_features,
in_features); the W loader does the transpose, proving it reads real
torch checkpoints as-is).

Besides the four weight tensors the file carries the oracle the W test
asserts against, so CI never needs Python or torch:
  probe_input   (8, 784)  the first 8 t10k images, exactly as fed to torch
  probe_logits  (8, 10)   torch's logits for those images
  test_acc      (1,)      torch's own t10k accuracy

The safetensors writer is hand-rolled (JSON header + contiguous LE f32
data) to keep this script dependency-light: torch + numpy only.

Usage: python3 tools/train_mnist_torch.py   (after tools/fetch_mnist.sh;
writes tests/data/mnist_mlp.safetensors; deterministic via manual_seed)
"""
import json
import struct
import sys

import numpy as np
import torch
import torch.nn as nn


def load_idx_images(path):
    with open(path, "rb") as f:
        raw = f.read()
    magic, count, rows, cols = struct.unpack(">iiii", raw[:16])
    assert magic == 0x803, path
    data = np.frombuffer(raw, dtype=np.uint8, offset=16)
    return (data.reshape(count, rows * cols).astype(np.float32)) / 255.0


def load_idx_labels(path):
    with open(path, "rb") as f:
        raw = f.read()
    magic, count = struct.unpack(">ii", raw[:8])
    assert magic == 0x801, path
    return np.frombuffer(raw, dtype=np.uint8, offset=8).astype(np.int64)


def save_safetensors(path, tensors):
    """tensors: ordered {name: np.float32 array}."""
    header = {}
    offset = 0
    blobs = []
    for name, arr in tensors.items():
        arr = np.ascontiguousarray(arr, dtype=np.float32)
        blob = arr.tobytes()
        header[name] = {
            "dtype": "F32",
            "shape": list(arr.shape),
            "data_offsets": [offset, offset + len(blob)],
        }
        offset += len(blob)
        blobs.append(blob)
    hjson = json.dumps(header, separators=(",", ":")).encode()
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(hjson)))
        f.write(hjson)
        for blob in blobs:
            f.write(blob)


def main():
    torch.manual_seed(0)

    xtr = torch.from_numpy(load_idx_images("bin/mnist/train-images-idx3-ubyte"))
    ytr = torch.from_numpy(load_idx_labels("bin/mnist/train-labels-idx1-ubyte"))
    xte = torch.from_numpy(load_idx_images("bin/mnist/t10k-images-idx3-ubyte"))
    yte = torch.from_numpy(load_idx_labels("bin/mnist/t10k-labels-idx1-ubyte"))

    model = nn.Sequential(nn.Linear(784, 32), nn.ReLU(), nn.Linear(32, 10))
    opt = torch.optim.SGD(model.parameters(), lr=0.1)
    loss_fn = nn.CrossEntropyLoss()

    batch = 100
    for epoch in range(5):
        perm = torch.randperm(len(xtr))
        total = 0.0
        for i in range(0, len(xtr), batch):
            idx = perm[i : i + batch]
            opt.zero_grad()
            loss = loss_fn(model(xtr[idx]), ytr[idx])
            loss.backward()
            opt.step()
            total += loss.item()
        print(f"epoch {epoch}: loss {total / (len(xtr) / batch):.4f}")

    model.eval()
    with torch.no_grad():
        logits = model(xte)
        acc = (logits.argmax(dim=1) == yte).float().mean().item()
        probe_logits = model(xte[:8])
    print(f"test accuracy {acc:.4f}")

    sd = model.state_dict()
    save_safetensors(
        "tests/data/mnist_mlp.safetensors",
        {
            "fc1.weight": sd["0.weight"].numpy(),
            "fc1.bias": sd["0.bias"].numpy(),
            "fc2.weight": sd["2.weight"].numpy(),
            "fc2.bias": sd["2.bias"].numpy(),
            "probe_input": xte[:8].numpy(),
            "probe_logits": probe_logits.numpy(),
            "test_acc": np.array([acc], dtype=np.float32),
        },
    )
    print("wrote tests/data/mnist_mlp.safetensors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
