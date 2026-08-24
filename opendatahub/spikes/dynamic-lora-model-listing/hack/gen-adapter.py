#!/usr/bin/env python3
"""Generate a tiny LoRA adapter using only the standard library.

A safetensors file is an 8-byte header length, a JSON header, then raw tensor
bytes - writable directly, which keeps setup.sh free of torch and peft.

Shaped for hmellor/tiny-random-LlamaForCausalLM: hidden 16, 2 layers,
q_proj/v_proj out 256, rank 8.

lora_B is zeros, standard PEFT init and a mathematical no-op. The adapter loads
and is addressable without changing output, so routing and listing assertions
do not have to account for generated text.

Usage:  ./hack/gen-adapter.py OUTDIR NAME [NAME...]
"""
import json
import os
import struct
import sys

HIDDEN = 16      # lora_A in_features
OUT = 256        # q_proj / v_proj out_features
RANK = 8
LAYERS = 2
BASE = "hmellor/tiny-random-LlamaForCausalLM"

CONFIG = {
    "peft_type": "LORA",
    "task_type": "CAUSAL_LM",
    "base_model_name_or_path": BASE,
    "r": RANK,
    "lora_alpha": 16,
    "lora_dropout": 0.0,
    "target_modules": ["q_proj", "v_proj"],
    "bias": "none",
    "fan_in_fan_out": False,
    "inference_mode": True,
    "modules_to_save": None,
    "init_lora_weights": True,
}


def tensors():
    """(name, shape) in the order safetensors will lay them out."""
    for layer in range(LAYERS):
        for proj in ("q_proj", "v_proj"):
            stem = f"base_model.model.model.layers.{layer}.self_attn.{proj}"
            yield f"{stem}.lora_A.weight", [RANK, HIDDEN]
            yield f"{stem}.lora_B.weight", [OUT, RANK]


def build():
    header, blob, offset = {}, bytearray(), 0
    for name, shape in tensors():
        nbytes = shape[0] * shape[1] * 4          # float32
        header[name] = {"dtype": "F32", "shape": shape,
                        "data_offsets": [offset, offset + nbytes]}
        # lora_A gets a tiny deterministic value so the file is not entirely
        # zeros (some loaders treat an all-zero A as a degenerate adapter);
        # lora_B stays zero, which is what makes the adapter a no-op.
        if ".lora_A." in name:
            blob += struct.pack("<f", 1e-4) * (shape[0] * shape[1])
        else:
            blob += b"\x00" * nbytes
        offset += nbytes

    raw = json.dumps(header, separators=(",", ":")).encode()
    pad = (-len(raw)) % 8                          # header must be 8-byte aligned
    raw += b" " * pad
    return struct.pack("<Q", len(raw)) + raw + bytes(blob)


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    outdir, names = sys.argv[1], sys.argv[2:]
    payload = build()
    for name in names:
        d = os.path.join(outdir, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "adapter_config.json"), "w") as fh:
            json.dump(CONFIG, fh, indent=2)
        with open(os.path.join(d, "adapter_model.safetensors"), "wb") as fh:
            fh.write(payload)
        print(f"{d}  ({len(payload)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
