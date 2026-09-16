import json, os, torch
from safetensors.torch import save_file

# tiny-random-LlamaForCausalLM: hidden_size 16, 2 layers, 4 heads x head_dim 64
HID, LAYERS, HEADS, HEAD_DIM = 16, 2, 4, 64
OUT = HEADS * HEAD_DIM          # q_proj / v_proj out_features
R, ALPHA = 8, 16
torch.manual_seed(0)

tensors = {}
for i in range(LAYERS):
    for mod in ("q_proj", "v_proj"):
        p = "base_model.model.model.layers.%d.self_attn.%s" % (i, mod)
        # Standard PEFT init: A ~ small random, B zeros. B=0 makes the adapter a
        # mathematical no-op, which is exactly what a routing test wants -- the
        # adapter must load and be *addressable*, not change the output.
        tensors[p + ".lora_A.weight"] = (torch.randn(R, HID) * 0.01).to(torch.float32)
        tensors[p + ".lora_B.weight"] = torch.zeros(OUT, R, dtype=torch.float32)

cfg = {
    "peft_type": "LORA", "task_type": "CAUSAL_LM",
    "base_model_name_or_path": "hmellor/tiny-random-LlamaForCausalLM",
    "r": R, "lora_alpha": ALPHA, "lora_dropout": 0.0,
    "target_modules": ["q_proj", "v_proj"],
    "bias": "none", "fan_in_fan_out": False, "inference_mode": True,
    "modules_to_save": None, "init_lora_weights": True,
}
import sys
# One adapter per name given on the command line, else four.
names = sys.argv[1:] or ["ceil-a%d" % i for i in range(1, 5)]
for name in names:
    d = "/out/" + name
    os.makedirs(d, exist_ok=True)
    save_file(tensors, d + "/adapter_model.safetensors")
    json.dump(cfg, open(d + "/adapter_config.json", "w"), indent=2)
    print("wrote", d, "%.1f KB" % (os.path.getsize(d + "/adapter_model.safetensors")/1024))
