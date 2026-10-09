"""Export the validated tiny_MNIST INT8 checkpoint for cnn_npu_int8.

The exporter writes a byte-per-line SRAM image and a JSON manifest.  It also
runs the actual PyTorch quantized operators on the same deterministic input;
the RTL testbench compares its ten output activation codes with that golden
result.  The memory image is intentionally independent of the .pt pickle.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path

import torch


LAYER_NAMES = ["conv1", "conv2", "conv3", "conv4", "conv5", "fc1"]
DESC_BYTES = 36
Q31 = 1 << 31


class FloatNet(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = torch.nn.Sequential(torch.nn.Conv2d(1, 2, 3, 2, 1, bias=False), torch.nn.BatchNorm2d(2), torch.nn.ReLU())
        self.conv2 = torch.nn.Sequential(torch.nn.Conv2d(2, 4, 3, 1, 1, bias=False), torch.nn.BatchNorm2d(4), torch.nn.ReLU())
        self.conv3 = torch.nn.Sequential(torch.nn.Conv2d(4, 8, 3, 2, 1, bias=False), torch.nn.BatchNorm2d(8), torch.nn.ReLU())
        self.conv4 = torch.nn.Sequential(torch.nn.Conv2d(8, 8, 3, 2, 1, bias=False), torch.nn.BatchNorm2d(8), torch.nn.ReLU())
        self.conv5 = torch.nn.Sequential(torch.nn.Conv2d(8, 16, 3, 1, 1, bias=False), torch.nn.BatchNorm2d(16), torch.nn.ReLU())
        self.fc1 = torch.nn.Linear(16 * 3 * 3, 10)

    def forward(self, x):
        x = self.conv1(x); x = self.conv2(x); x = self.conv3(x)
        x = self.conv4(x)[:, :, :3, :3]; x = self.conv5(x)
        return self.fc1(x.reshape(-1, 16 * 3 * 3))


class QuantWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.quant = torch.ao.quantization.QuantStub()
        self.model = model
        self.dequant = torch.ao.quantization.DeQuantStub()

    def forward(self, x):
        return self.dequant(self.model(self.quant(x)))


def build_quantized(state_dict):
    model = FloatNet().eval()
    for n in ("conv1", "conv2", "conv3", "conv4", "conv5"):
        torch.ao.quantization.fuse_modules(getattr(model, n), [["0", "1", "2"]], inplace=True)
    wrapper = QuantWrapper(model).eval()
    torch.backends.quantized.engine = "fbgemm"
    wrapper.qconfig = torch.ao.quantization.get_default_qconfig("fbgemm")
    prepared = torch.ao.quantization.prepare(wrapper, inplace=False)
    quantized = torch.ao.quantization.convert(prepared, inplace=False)
    quantized.load_state_dict(state_dict)
    return quantized


def pack_u32(buf: bytearray, addr: int, value: int):
    buf[addr:addr + 4] = struct.pack("<I", value & 0xFFFFFFFF)


def pack_i32(buf: bytearray, addr: int, value: int):
    buf[addr:addr + 4] = struct.pack("<i", int(value))


def reserve(cursor: int, size: int, align: int = 4):
    cursor = (cursor + align - 1) // align * align
    return cursor, cursor + size


def put_descriptor(buf, base, values):
    for i, value in enumerate(values):
        pack_u32(buf, base + 4 * i, value)


def get_weight(state, name):
    q = state[name]
    return q.int_repr().to(torch.int16).flatten().tolist(), q.q_per_channel_scales().tolist()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", type=Path, default=Path(__file__).resolve().parents[2] / "model/checkpoints/model_int8.pt")
    ap.add_argument("--out-dir", type=Path, default=Path("generated"))
    ap.add_argument("--sram-bytes", type=int, default=16 * 1024)
    ap.add_argument("--lanes", type=int, default=16)
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    checkpoint = torch.load(args.checkpoint, map_location="cpu")
    state = checkpoint["state_dict"]
    quantized = build_quantized(state)
    quantized.eval()

    # A deterministic normalized input exercises both the input zero point and
    # the upper end of the FBGEMM reduced activation range.
    x = torch.linspace(-0.4241, 2.8200, 28 * 28, dtype=torch.float32).reshape(1, 1, 28, 28)
    with torch.no_grad():
        q = quantized.quant(x)
        input_codes = q.int_repr().flatten().tolist()
        layer_outputs = []
        y = q
        for name in ("conv1", "conv2", "conv3", "conv4", "conv5"):
            y = getattr(quantized.model, name)(y)
            if name == "conv4":
                y = y[:, :, :3, :3]
            layer_outputs.append(y)
        y = quantized.model.fc1(y.reshape(1, 144))
        final_codes = y.int_repr().flatten().tolist()

    if max(input_codes) > 127:
        raise RuntimeError(f"reduced-range input unexpectedly exceeds 127: {max(input_codes)}")

    mem = bytearray(args.sram_bytes)
    cursor = 0
    if args.sram_bytes >= 16 * 1024:
        desc_base, act_a, act_b = 12 * 1024, 8 * 1024, 10 * 1024
    elif args.sram_bytes >= 8 * 1024:
        # Buffer A reserves 1536 bytes and B 512 bytes before descriptors.
        # This model's peak live activation set is 1176 bytes.
        desc_base, act_a, act_b = 7168, 5120, 6656
    else:
        raise RuntimeError("cnn_npu_int8 requires at least 8 KB local SRAM")
    if desc_base + 6 * DESC_BYTES > args.sram_bytes:
        raise RuntimeError("SRAM too small for descriptor region")

    layer_meta = []
    in_base = act_a
    # The FC engine consumes the channel-major 3x3x16 tensor as a flat 144
    # element vector, so its descriptor uses H=W=1, Cin=144.
    shapes = [(28, 28, 1), (14, 14, 2), (14, 14, 4), (7, 7, 8), (3, 3, 8), (1, 1, 144)]
    out_shapes = [(14, 14, 2), (14, 14, 4), (7, 7, 8), (3, 3, 8), (3, 3, 16), (1, 1, 10)]
    strides = [2, 1, 2, 2, 1, 1]

    # Parameters are placed before the descriptor/activation reservation.
    for index, name in enumerate(LAYER_NAMES):
        if name == "fc1":
            packed_weight, packed_bias = state["model.fc1._packed_params._packed_params"]
            weight_q = packed_weight.int_repr().to(torch.int16).flatten().tolist()
            scales = packed_weight.q_per_channel_scales().tolist()
            bias_fp = packed_bias.detach().tolist()
            weight_shape = (10, 144)
            weight_key = "model.fc1._packed_params._packed_params"
            out_scale = float(state["model.fc1.scale"])
            out_zp = int(state["model.fc1.zero_point"])
        else:
            weight_key = f"model.{name}.0.weight"
            weight_q, scales = get_weight(state, weight_key)
            bias_fp = state[f"model.{name}.0.bias"].detach().tolist()
            weight_shape = tuple(state[weight_key].shape)
            out_scale = float(state[f"model.{name}.0.scale"])
            out_zp = int(state[f"model.{name}.0.zero_point"])

        previous_scale_key = (f"model.{LAYER_NAMES[index-1]}.0.scale" if index <= 5 else "")
        previous_zp_key = (f"model.{LAYER_NAMES[index-1]}.0.zero_point" if index <= 5 else "")
        in_scale = float(state["quant.scale"]) if index == 0 else float(state[previous_scale_key])
        in_zp = int(state["quant.zero_point"]) if index == 0 else int(state[previous_zp_key])

        w_addr, cursor = reserve(cursor, len(weight_q), 4)
        for i, value in enumerate(weight_q):
            mem[w_addr + i] = int(value) & 0xFF
        b_addr, cursor = reserve(cursor, 4 * len(bias_fp), 4)
        m_addr, cursor = reserve(cursor, 4 * len(scales), 4)
        s_addr, cursor = reserve(cursor, len(scales), 4)
        out_c = out_shapes[index][2]
        for i, (bias, scale) in enumerate(zip(bias_fp, scales)):
            b_i32 = int(round(float(bias) / (in_scale * float(scale))))
            pack_i32(mem, b_addr + 4 * i, b_i32)
            real_m = in_scale * float(scale) / out_scale
            if not 0 <= real_m < 1:
                raise RuntimeError(f"{name} channel {i}: fixed shift=31 requires multiplier in [0,1), got {real_m}")
            multiplier = int(round(real_m * Q31))
            multiplier = min(max(multiplier, 0), Q31 - 1)
            pack_u32(mem, m_addr + 4 * i, multiplier)
            mem[s_addr + i] = 31

        out_base = act_b if (index % 2 == 0) else act_a
        if index == 5:
            out_base = act_a
        ih, iw, ic = shapes[index]
        oh, ow, oc = out_shapes[index]
        flags = (1 if name == "fc1" else 0) | (2 if name != "fc1" else 0)
        values = [in_base, out_base, w_addr, b_addr, m_addr, s_addr,
                  ih | (iw << 8) | (ic << 16) | (oc << 24),
                  oh | (ow << 8) | (strides[index] << 16) | (flags << 24),
                  in_zp | (out_zp << 8) | (127 << 16)]
        put_descriptor(mem, desc_base + index * DESC_BYTES, values)
        layer_meta.append({"name": name, "weight": w_addr, "bias": b_addr, "multiplier": m_addr, "shift": s_addr,
                           "in_base": in_base, "out_base": out_base, "input_zp": in_zp, "output_zp": out_zp,
                           "input_scale": in_scale, "output_scale": out_scale})
        in_base = out_base

    mem[act_a:act_a + len(input_codes)] = bytes(input_codes)
    hex_path = args.out_dir / "cnn_npu_mem.hex"
    with hex_path.open("w", encoding="ascii") as f:
        for value in mem:
            f.write(f"{value:02x}\n")
    # Word-packed image for the synchronous 2048x32 FPGA/ASIC SRAM backend.
    # Each line is little-endian, matching the byte-addressed image above.
    with (args.out_dir / "npu_word.hex").open("w", encoding="ascii") as f:
        for address in range(0, len(mem), 4):
            f.write(f"{int.from_bytes(mem[address:address+4], 'little'):08x}\n")
    with (args.out_dir / "input_codes.hex").open("w", encoding="ascii") as f:
        for value in input_codes:
            f.write(f"{value:02x}\n")

    golden = {
        "checkpoint": str(args.checkpoint),
        "backend": checkpoint.get("backend"),
        "sram_bytes": args.sram_bytes,
        "lanes": args.lanes,
        "descriptor_base": desc_base,
        "activation_a": act_a,
        "activation_b": act_b,
        "input_codes": input_codes,
        "expected_output_codes": final_codes,
        "pytorch_output_dequant": y.dequantize().flatten().tolist(),
        "layers": layer_meta,
        "observed_activation_max": [int(t.int_repr().max()) for t in layer_outputs],
        "pytorch_layer_codes": [t.int_repr().flatten().tolist() for t in layer_outputs],
        "state_accuracy": {k: checkpoint.get(k) for k in ("fp32_accuracy", "int8_accuracy", "accuracy_drop")},
    }
    (args.out_dir / "golden.json").write_text(json.dumps(golden, indent=2), encoding="utf-8")
    svh = "// Generated by export_model.py\nfunction automatic [7:0] golden_output(input integer idx);\n"
    svh += "  begin case (idx)\n"
    for idx, value in enumerate(final_codes):
        svh += f"    {idx}: golden_output = 8'd{int(value)};\n"
    svh += "    default: golden_output = 8'd0;\n  endcase end\nendfunction\n"
    (args.out_dir / "golden.svh").write_text(svh, encoding="ascii")
    print(json.dumps({"hex": str(hex_path), "golden": str(args.out_dir / 'golden.json'),
                      "output_codes": final_codes, "activation_max": golden["observed_activation_max"]}, indent=2))


if __name__ == "__main__":
    main()
