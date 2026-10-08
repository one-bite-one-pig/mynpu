# 完整 SoC 验证记录

日期：2026-10-08。模拟器：VCS Q-2020.03-SP2-7，Linux。PyTorch checkpoint 重新导出使用 2.2.2+cpu / FBGEMM，生成的 8KB 参数镜像与仓库镜像逐字节相同。

## 完整 SoC 参数配置

| CPU SRAM | NPU SRAM | LANES | 结果 | 单轮 NPU CYCLE |
|---|---|---:|---|---:|
| 8KB | 8KB | 1 | PASS | 54132 |
| 8KB | 8KB | 8 | PASS | 10704 |
| 8KB | 16KB | 16 | PASS | 9882 |

每项包含 JTAG IDCODE、DMI/SBA 读写 CPU/NPU SRAM、真实 CPU 启动、halt/x31 读写及恢复、两轮六层推理、第一轮轮询、第二轮中断处理和清中断。每层全部 1794 个输出 byte 对独立整数参考严格相等；每轮也对 PyTorch 的逐层 code 检查绝对差 ≤1。测试要求 IRQ 恰好产生一次、CPU handler 恰好处理一次，最终 mailbox 为 `0xc0dec0de`。

周期计数不含 CPU 加载参数/输入、JTAG 操作或读回结果的开销。它来自当前多访问功能数组后端，换成同步 SRAM 后必须重测。提高 LANES 到 16 收益有限，因为前四层输出通道数均 ≤8，尾层通道余数也影响利用率。

## PyTorch 与固定点参考

采用 exporter 中的确定性输入：784 个 FP32 值在 -0.4241..2.8200 均匀排列，reshape 为 1×1×28×28 后由 checkpoint QuantStub 产生输入 code。这是用于功能验证的固定向量，不是 MNIST 测试集评估。

| 层 | 输出 byte 数 | 与 PyTorch 不同的 byte 数 | 最大绝对差 |
|---|---:|---:|---:|
| Conv1 | 392 | 0 | 0 |
| Conv2 | 784 | 1 | 1 |
| Conv3 | 392 | 1 | 1 |
| Conv4 裁剪后 | 72 | 1 | 1 |
| Conv5 | 144 | 4 | 1 |
| FC | 10 | 1 | 1 |

```text
PyTorch / FBGEMM: 68 49 82 68 55 80 75 63 76 59
Integer / RTL:   68 50 82 68 55 80 75 63 76 59
Argmax: 2
```

整数参考由 `tools/build_firmware.py` 中独立的 Python Conv/FC 循环计算，处理 zero-point、padding、INT32 bias/累加回绕、Q31 requant、ReLU 和 clamp。PyTorch reference 由 exporter 实际执行 checkpoint 的 quantized ConvReLU/Linear 取得，包含 Conv4 的裁剪。两种参考分别保存为 `integer_layers.hex` 与 `pytorch_layers.hex`，testbench 同时检查。

checkpoint 的元数据记录 FP32 accuracy=99.07%、INT8 accuracy=99.01%、下降约 0.06 个百分点。这些是模型作者记录的数据，本次未重新运行完整测试集；尤其不能把它作为当前 Q31 RTL 的全测试集精度。

## 已知边界

VCS 启动时出现原 CPU `unique case` 在 time 0 未匹配的 warning，复位后自测通过。测试编译定义 `SYNTHESIS`，用于避开原项目中非必要的仿真辅助逻辑；新增 testbench 的断言、逐层比较和 CPU 自测仍实际执行。Vivado 2023.2 XSim elaboration 失败于原 AXI 的 `default disable iff`，未将其列为通过的后端。

尚未覆盖大量随机输入、全 MNIST 测试集、异常 descriptor、AXI 随机压力、多 hart、真实探针、FPGA 或物理 SRAM 宏。FBGEMM bit-exact、单物理 SRAM 共享、面积/功耗/最高频率也尚未完成。
