# Source provenance

`third_party/lab3` contains 206 unmodified files imported from the user's local `lab3-ST/SoC_cv32e40p` baseline. The byte SHA256 of each imported file is recorded in `third_party/lab3/SOURCE_MANIFEST.json`. No upstream lab3 Git revision was available in that local directory. The original lab top and simple NPU are retained for provenance; `sim/soc.f` selects the new integration and CNN NPU instead.

The imported components include CORE-V CV32E40P, PULP AXI/common cells and the RISC-V Debug Module. Original copyright headers, SPDX identifiers and supplied license files are retained. Licensing varies by source file, including Solderpad 0.51, Solderpad 2.1 / Apache-2.0 options, and licenses in the fpnew vendor tree. No new blanket license is assigned to imported material.

`model/main_mnist.py`, `model/quantize.py`, `model/train.py`, `model/example.py`, `model/requirements.txt` and the INT8 checkpoint come from [CatalpaEel/tiny_MNIST](https://github.com/CatalpaEel/tiny_MNIST/tree/pool-stride2-fp32-int8), branch `pool-stride2-fp32-int8`, local source revision `c8ee23508b44a72e8ab7fb06ae20e8fc6b7752b7`. These files retain their upstream attribution; no model training or new dataset accuracy result is claimed by this integration.

`cnn_npu_int8` is the separately developed NPU from the user's workspace. `rtl`, `sw`, `sim/tb_mynpu_soc.sv` and the build/verification scripts contain the new SoC integration work. The new top is derived from the lab3 top and continues to depend on its licensed modules.
