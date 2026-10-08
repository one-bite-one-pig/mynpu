# EGO1 / XC7A35T FPGA 验证指导

适用工程：本仓库。保留原始 `lab3-ST/` 不变，FPGA 文件可新增在 `fpga/ego1/`。

这是一份上板实施指导。完整 CPU+NPU SoC 已在 `rtl/mynpu_soc_top.sv` 实现，并通过 VCS 功能仿真，见 [验证记录](../../docs/verification.md)。尚未创建完整 FPGA 板级顶层或 bitstream，也没有完成综合、布局布线、下载或板级测试。

**1. 验证顺序与第一版配置**

建议按以下顺序推进，每一步通过后再增加新的模块：

| 阶段 | FPGA 内的设计 | 验收内容 |
|---|---|---|
| A | 时钟、复位、LED、ILA | 下载、时钟、复位正常 |
| B | NPU + 同步 BRAM + 测试控制 FSM | 一个固定向量的硬件输出严格等于整数 RTL 仿真 |
| C | 原有 Debug Module SBA + NPU | 可以动态写输入、启动、读取全部输出 |
| D | CV32E40P + AXI + CPU BRAM + NPU | CPU 启动、MMIO、模型推理通过 |
| E | 动态输入接口 + 多样本测试 | 真实 MNIST 样本、重复推理、精度和周期统计 |

第一版建议 `SRAM_BYTES=8192`、`LANES=1` 或 4、CPU BRAM=8192 字节、CPU/NPU 共用一个由 MMCM 生成的 25 MHz 时钟。25 MHz 是调试目标，不是已经验证的最高频率。存储带宽做好后再比较 LANES=8/16，资源和时序以实际 Vivado 报告为准。

XC7A35T 有 90 个 DSP48E1 和 50 个 36 Kbit BRAM。16 KB 的逻辑 SRAM 容量本身并不大，但 CPU、crossbar、访存电路和调试核能否同时放下仍需综合确认。[AMD DS180](https://docs.amd.com/api/khub/documents/2LByHkO~nSZXcei2D55fTg/content)

**2. 板卡与外部接口**

依元素 EGO1 V2.2 文档给出的器件是 `XC7A35T-1CSG324C`，Vivado 对应 part 为 `xc7a35tcsg324-1`，板载 100 MHz 时钟接 P17，具有 USB-JTAG/UART。购买的实际板卡版本必须与随板原理图/XDC 对照，尤其是 USB 接口布局和复位极性。[EGO1 用户手册](https://e-elements.readthedocs.io/zh/ego1_v2.2/EGo1.html)

需要分清三个接口：

| 接口 | 用途 | 是否会自动控制 lab3 的 CPU |
|---|---|---|
| FPGA 自身的配置 JTAG | 下载 `.bit`，访问 ILA/VIO/JTAG-to-AXI | 不会 |
| lab3 RTL 的 RISC-V JTAG/DMI | Debug Module 控制 CPU、访问系统总线 | 需要额外连接和调试工具支持 |
| FPGA 内新增的 UART/SPI 控制通道 | 加载模型/输入，发命令，读回结果 | 取决于桥接设计或 CPU 固件 |

`mynpu_soc_top` 中的 `tck_i/tms_i/td_i/td_o` 是你设计的逻辑端口。不能直接认为板载用于 FPGA 配置的 JTAG 会驱动这些端口。若要测试原始 RISC-V JTAG，可将四个端口分配到普通扩展 GPIO，再接支持目标 TAP/DMI 的外部调试器；或者另外设计基于 FPGA BSCAN 的用户链桥接。后者涉及 TAP/DMI 适配和跨时钟处理，不能只连四根线。

本完整 SoC 优先保留原有 RISC-V Debug Module SBA 路径，它已在仿真中验证，无须新增 crossbar 请求入口。若为了方便 Vivado Hardware Manager 操作，也可选用 JTAG-to-AXI Master IP；它通过 FPGA 的配置调试链发出片内 AXI 读写，需要复用入口或扩展 crossbar，与 RISC-V JTAG 是两条不同路径。[AMD UG908](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/Hardware-System-Communication-Using-the-JTAG-to-AXI-Master-Debug-Core)

**3. 当前 RTL 上板前必须处理的地方**

`rtl/cnn_npu_top.sv` 当前用 `logic [7:0] mem[...]`，由 `rd8/rd32` 组合读取。描述符、bias、多个 lane 的权重、输出写回都可能在同一个周期访问多个地址。这是方便算法验证的存储行为模型，尚未确认 Vivado 的映射结果。

RAM 属性无法把任意多端口、异步读取行为变成一块单口或双口 BRAM。直接综合可能使用大量 LUT/寄存器、复制存储，或无法得到预期的 BRAM。应改成明确的同步存储接口：

```text
req / we / be / addr / wdata / rdata / rvalid
```

NPU 控制 FSM 根据读延迟等待 `rvalid`。若外侧沿用 lab3 的固定一拍读接口，应让 CPU 访问适配器保持这项约定；否则要同步修改 AXI 读响应时序，不能只在计算 FSM 增加等待。

推荐第一轮从以下实现开始：

- 描述符按 9 个 32-bit word 分拍加载，存入寄存器。
- 参数按 word 分拍读取，加载当前计算块的 bias/multiplier/shift。
- 每个输入 activation 读取后广播给所有 lane。
- 多 lane 的权重通过分 bank 或分拍预取到小缓存供应。激活广播不能替代权重带宽。
- 输出按存储端口宽度分拍写回，处理 byte enable。
- 在 NPU BUSY 期间，主机不访问 NPU 的数据 SRAM；状态寄存器仍可访问。

Artix-7 BRAM 的端口组织和 read-first/write-first/no-change 行为必须在仿真模型与硬件中一致。[Vivado RAM 推断](https://docs.amd.com/r/en-US/ug901-vivado-synthesis/Memory-Inference-Capabilities) [BRAM 读写模式](https://docs.amd.com/r/2024.1-English/ug901-vivado-synthesis/Block-RAM-Read/Write-Synchronization-Modes)

即使设 `LANES=1`，当前描述符的组合多字读取也仍需要改造。LANES 只控制计算并行度。

还要把 datapath 的 `integer` 明确成合理位宽。权重是 signed 8 bit，acc 是 signed 32 bit。若允许完整 unsigned 8-bit activation 和任意 8-bit zero-point，中心化后的输入需要 signed 9 bit，乘积需要 signed 17 bit；只有明确限定到 reduced range 时才可收窄。Q31 requant 的 32×32→64 bit 乘法也要考虑流水线或共享实现，不能只统计 8-bit MAC 使用的 DSP。

`SHARED_SRAM=1` 目前只会在 BUSY 时忽略 CPU 对 NPU 数组的写入，CPU 读仍存在，而且 NPU 本身有多次同拍访问。它不是物理单口 SRAM 仲裁器。若最终流片共用单口 SRAM，FPGA 必须用同样的仲裁、延迟和带宽来验证。

**4. 建议增加的文件，均为待实现项**

```text
cnn_npu_int8/
  fpga/ego1/
    ego1_npu_top.sv       板级时钟、复位、NPU、测试控制、LED/ILA
    ego1_soc_top.sv       CPU+NPU 板级集成顶层
    ego1.xdc             该板卡版本的引脚和时序约束
    create_project.tcl   创建 Vivado 工程
    hw_access.tcl        JTAG-to-AXI 模型加载和结果读取
    ip/                  Clocking Wizard、JTAG-to-AXI、ILA 配置
  rtl/mem/
    npu_mem_if.sv        固定的存储访问边界
    npu_bram.sv          FPGA 同步 BRAM 后端
  sw/
    startup.S
    linker.ld
    npu_driver.c
  host/
    run_vectors.py       上位机多向量测试
```

可以引用 lab3 中的 CPU/AXI 源码，但另建 SoC 顶层来实例化 `cnn_npu_subsystem`。原来的 lab3 顶层仍连接旧 NPU，直接把它加入工程不会得到新 CNN SoC。

**5. 时钟、复位与 XDC**

用 P17 的 100 MHz 时钟作为 Clocking Wizard 输入，生成 25 MHz 的 `sys_clk`；CPU、NPU、AXI、BRAM 先都使用 `sys_clk`。不要把普通计数器输出作为这些模块的时钟。

复位可以选通用按键 PB2，加入同步处理。复位释放须同步到 `sys_clk`，并等待 Clocking Wizard 的 `locked`。启动按键需要同步、消抖，再产生一次脉冲；不要按住时每拍启动。具体复位组合依顶层实现决定。

以下 XDC 是基于 EGO1 V2.2 手册的端口示例，顶层端口名必须一致；使用前与实际板卡约束核对。UART 的方向按 FPGA 视角命名，手册中的桥接芯片 RX/TX 名称相反。[EGO1 引脚表](https://e-elements.readthedocs.io/zh/ego1_v2.2/EGo1.html)

```tcl
set_property PACKAGE_PIN P17 [get_ports clk_100m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_100m]
create_clock -name board_clk -period 10.000 [get_ports clk_100m]

# PB2：按下为高；PB0：启动按键
set_property PACKAGE_PIN R15 [get_ports reset_btn]
set_property PACKAGE_PIN R11 [get_ports start_btn]
set_property IOSTANDARD LVCMOS33 [get_ports {reset_btn start_btn}]

# led[0..3] 可分别显示 heartbeat/busy/done/error
set_property PACKAGE_PIN K3 [get_ports {led[0]}]
set_property PACKAGE_PIN M1 [get_ports {led[1]}]
set_property PACKAGE_PIN L1 [get_ports {led[2]}]
set_property PACKAGE_PIN K6 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# 仅在实现 UART 后加入以下约束
# set_property PACKAGE_PIN N5 [get_ports uart_rx]
# set_property PACKAGE_PIN T4 [get_ports uart_tx]
# set_property IOSTANDARD LVCMOS33 [get_ports {uart_rx uart_tx}]
```

这不是完整时序约束文件。生成时钟由 IP 提供相关约束；按键/UART 等异步输入需要正确 CDC 和有针对性的约束。若使用外部 RISC-V JTAG，需增加 TCK 以及 DMI 跨域约束。不能给所有路径设 false path，或仅设异步 clock group 就认为 CDC 已解决。[AMD 异步时钟约束说明](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Recommended-Asynchronous-Clock-Groups-Constraints)

**6. 在 Vivado 创建工程**

改造前可先从工作区根目录复跑已有 8 KB、8 lane 功能仿真，作为算法基线。当前 testbench 的 golden include 是 16 KB 目录的固定向量；两套导出在该向量上 golden 相同，但以后更换输入时必须同步更新 golden，不能继续依赖这个巧合。

```powershell
iverilog -g2012 -s tb_cnn_npu -I cnn_npu_int8 `
  '-Ptb_cnn_npu.LANES=8' `
  '-Ptb_cnn_npu.SRAM_BYTES=8192' `
  '-Ptb_cnn_npu.DESC_BASE=7168' `
  '-Ptb_cnn_npu.OUTPUT_BASE=5120' `
  '-Ptb_cnn_npu.MEM_FILE="cnn_npu_int8/generated/8k/cnn_npu_mem.hex"' `
  -o cnn_npu_int8/out_cnn_8k.vvp `
  cnn_npu_int8/rtl/cnn_npu_top.sv `
  cnn_npu_int8/tb/tb_cnn_npu.sv
vvp cnn_npu_int8/out_cnn_8k.vvp
```

上述命令仍是功能仿真，不是 FPGA 综合。同步 BRAM 改造后要另跑对应 testbench，并确认输出没有改变。

先做 NPU-only 工程：

1. Create Project → RTL Project。
2. Device 选择 `xc7a35tcsg324-1`，不依赖安装 EGO1 board file。
3. Add Design Sources：NPU、同步 BRAM、访存调度、板级 wrapper、测试 FSM。
4. Add Simulation Sources：新的同步存储模型和对应 testbench。`tb_cnn_npu` 不能作为 FPGA 顶层。
5. Add Constraints：按实际板卡版本核对后的 XDC。
6. IP Catalog 加入 Clocking Wizard 与 ILA；动态测试阶段再加入 JTAG-to-AXI。
7. 检查 RAM 初始化文件的格式、工程路径和综合使用情况；当前 hex 一行是一个 byte，32-bit BRAM 初始化需要小端打包转换。
8. Run Synthesis → Run Implementation → Generate Bitstream。

CPU+NPU 工程再按 lab3 filelist 的顺序加入 packages、interfaces、AXI、debug、CPU。去掉仿真 testbench 和原来的 simple_npu，加入自己的 SoC 顶层。lab3 的 `cv32e40p_fpga_clock_gate.sv` 定义的是 `cv32e40p_clock_gate`，其当前实现为 `assign clk_o = clk_i`。第一轮可保留这个不关门控的 FPGA 调试实现，但 ASIC 门控要另验证，不要与仿真 clock gate 重复编译。CPU 的 FPU 仍关闭。[CV32E40P 集成说明](https://docs.openhwgroup.org/projects/cv32e40p-user-manual/en/cv32e40p_v1.7.0/integration.html)

综合后至少检查：

- LUT、FF、DSP、BRAM 利用率，确认模型存储真的使用 BRAM。
- RAM 有没有不期望的复制、锁存器或黑盒。
- 8 KB/16 KB 的逻辑可访问范围有没有因为 FPGA 实际 BRAM 更大而扩大。
- 实现后的 setup/hold 时序、未约束路径、CDC 和 DRC。
- ILA 使用的 BRAM 是否挤占目标逻辑存储。

可以在打开实现结果后执行 `report_utilization -hierarchical`、`report_timing_summary`、`report_drc`、`report_cdc`。不要以“生成 bit 成功”代替时序和功能验收。

**7. 第一次上板：固定输入自检**

在新设计的 BRAM 初始化机制中加载导出的 8 KB 镜像。FPGA 可以把支持的 RAM 初值放入 bitstream；这不是 ASIC SRAM 的上电加载机制。

板级测试 FSM 接到 NPU 总线端口，依次进行写寄存器、等待 DONE、读输出、比较结果。用寄存器状态、LED 和 ILA 观测结果。硬件 FSM 没有 `#delay`、`$display`、`$finish` 等仿真行为。

板级读写必须尊重 NPU 的请求/返回时序。例如写请求保持一个有效时钟沿，读取在适配器规定的返回周期捕获。错误路径和超时要由硬件 FSM 实际处理。

下载流程：USB 数据线接 USB-JTAG，Vivado → Open Hardware Manager → Open Target → Auto Connect → 选择 xc7a35t → Program Device。使用同次实现的 `.bit` 与 `.ltx`。随后按逻辑复位按钮并触发推理。这个按钮操作不会重新下载 bitstream；单纯复位也不会恢复已经被推理覆盖的 BRAM 输入。[EGO1 下载流程](https://e-elements.readthedocs.io/zh/ego1_v2.2/EGo13.html)

ILA 第一轮观察：`sys_reset_n`、START、state、BUSY/DONE/ERROR、layer index、访存 req/we/addr/rvalid、一个 lane 的 acc、requant 输出、cycle counter。触发条件选 START 或第一笔 MAC。捕获深度先用 1024/2048，观察指定阶段，避免把所有 lane 和所有周期一次抓满。

**8. 动态推理：JTAG-to-AXI**

NPU-only 连接路径：

```text
电脑/Vivado → FPGA 配置 JTAG → JTAG-to-AXI Master
    → AXI 适配器 → cnn_npu_subsystem → NPU BRAM
```

选择 32-bit memory-mapped AXI，并与适配器实际协议一致。若使用 AXI-Lite，必须有正确的 AXI-Lite 从接口/转换层，不要直接把缺失的完整 AXI 字段悬空。第一版一次传一个 32-bit word；单字读写验证后才加 burst。

NPU-only 不需要 lab3 的 3×4 crossbar。完整 SoC 中，若同时保留 CPU 指令、CPU 数据、RISC-V DM 三个 master，再加 JTAG-to-AXI master，需要 4 个入口。若使用选择/仲裁器复用调试入口，可保持 crossbar 的 3 个入口。两个 master 不能直接接到同一入口。

下面假设 NPU 仍映射在 `0x70000000`：

| 内容 | CPU/AXI 地址 | 8 KB 布局值 |
|---|---|---|
| CONTROL | `0x70000000` | bit0 START，bit1 IRQ enable，bit2 清状态 |
| STATUS | `0x70000004` | bit0 BUSY，bit1 DONE，bit2 ERROR |
| DESC_BASE | `0x70000010` | 写 `0x00001c00`，是 SRAM 内字节偏移 |
| LAYER_CFG | `0x70000014` | 写 6 |
| CYCLE | `0x70000018` | 读取硬件周期 |
| NPU SRAM 窗口起始 | `0x70004000` | 8192 字节 |
| activation A / 输入 / FC 输出 | `0x70005400` | SRAM 内 `0x1400` |
| activation B | `0x70005a00` | SRAM 内 `0x1a00` |
| 描述符存储 | `0x70005c00` | SRAM 内 `0x1c00` |

16 KB 布局是 activation A=`0x2000`、B=`0x2800`、DESC_BASE=`0x3000`。地址应以对应导出的 `golden.json` 为准，不混用两套镜像。

Hardware Manager 中连接并下载含 JTAG-to-AXI 的 bitstream 后，可用以下 Tcl 示例测试单字访问。仅为指导模板，尚未在硬件执行：

```tcl
set npu_axi [lindex [get_hw_axis] 0]
if {$npu_axi eq ""} { error "No JTAG-to-AXI core found" }

proc npu_wr32 {addr value} {
    global npu_axi
    create_hw_axi_txn npu_write $npu_axi -type WRITE -len 1 \
        -address [format %08X $addr] -data [format %08X $value] -force
    run_hw_axi [get_hw_axi_txns npu_write]
}

proc npu_rd32_report {addr} {
    global npu_axi
    create_hw_axi_txn npu_read $npu_axi -type READ -len 1 \
        -address [format %08X $addr] -force
    run_hw_axi [get_hw_axi_txns npu_read]
    puts [report_hw_axi_txn npu_read -w 32]
}

# 先在确认空闲、尚未加载镜像时验证一个 SRAM word
npu_wr32 0x70004000 0x03020100
npu_rd32_report 0x70004000

# 之后必须加载完整模型/输入镜像，覆盖上述测试写入
# 镜像第 i 个 byte 写到 0x70004000+i
# 4 个 byte b0,b1,b2,b3 小端打包为 b0|(b1<<8)|(b2<<16)|(b3<<24)

npu_wr32 0x70000000 4
npu_wr32 0x70000010 0x1c00
npu_wr32 0x70000014 6
npu_wr32 0x70000000 1
npu_rd32_report 0x70000004

# 等 STATUS bit1=1；bit2=1 时报错。自动脚本应设置超时。
# 完成后读以下三个 word，按小端提取前 10 个 byte。
npu_rd32_report 0x70005400
npu_rd32_report 0x70005404
npu_rd32_report 0x70005408
npu_rd32_report 0x70000018
```

Tcl transaction 创建和执行方式依据 [AMD create_hw_axi_txn](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/create_hw_axi_txn) 与 [AMD run_hw_axi](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/run_hw_axi)。自动化脚本还需检查 AXI 错误响应、确认镜像读回、轮询超时，并保存数据。

首次推理的输入是固定的 784-byte 量化向量。推理过程中 A/B 缓冲会被覆盖，因此每次重新推理都要重新写入 784-byte 输入，不能只再次写 START。

**9. CPU+NPU 整机验证**

创建新 SoC 顶层，把 lab3 的原 NPU 实例替换成 `cnn_npu_subsystem`，传递 byte enable。CPU 和 NPU SRAM 分开时先按各 8 KB 实现。CPU 固件的最小工作流：

```c
#define NPU_BASE 0x70000000u
#define MMIO32(offset) (*(volatile unsigned int *)(NPU_BASE + (offset)))

/* 模型、描述符和输入已经加载，以下是最小轮询驱动片段。 */
MMIO32(0x00) = 4u;
MMIO32(0x10) = 0x1c00u;
MMIO32(0x14) = 6u;
MMIO32(0x00) = 1u;

unsigned int timeout = 1000000u;
unsigned int status = 0u;
while (timeout != 0u) {
    status = MMIO32(0x04);
    if ((status & 6u) != 0u) break; /* DONE 或 ERROR */
    --timeout;
}
/* 必须处理 ERROR 或 timeout==0 的情况，再读取输出 SRAM。 */
```

固件要有 startup、linker、栈和 `.bss` 初始化，保证程序/数据/栈不超 8 KB。模型保存在 NPU SRAM，避免复制一份大型模型到 CPU 的 8 KB SRAM。

FPGA 首轮可以在 bitstream 中初始化 CPU BRAM 与 NPU BRAM；随后再验证运行时加载程序和模型。ASIC 不依赖 FPGA 的 RAM 初始化。lab3 的 Boot RAM 当前直接跳 `0x80000000`，运行时加载需要设计启动等待/`boot_ready`，或者可靠的 halt/load/resume 流程。不要在未初始化 CPU SRAM 上直接放开取指。

优先轮询 DONE。轮询通过后，再连接 `irq_o` 到 CPU 可用 IRQ，编写 trap handler 并验证 enable/clear。当前 NPU IRQ 是 DONE 与使能的电平组合，要清 DONE 才会撤销。

可选 UART 动态测试：先设计带 length、命令、地址、payload、校验、ACK 的二进制协议，支持 READ/WRITE/START/STATUS。第一轮可用 115200、8N1；784 个输入 byte 的理论线速时间约为 `784*10/115200=68 ms`，不含协议和软件等待。支持更高波特率时以实测为准。UART 外设若由 CPU 访问，是新增从设备；UART-to-AXI 加载桥若主动访存，则是新增总线 master，两者的 crossbar 规模不同。

最终若选择 SPI 作为 ASIC 的外部推理接口，还需要在 FPGA 上单独验证同一 SPI 协议、收发、CDC 和错误恢复。JTAG-to-AXI 是开发调试通路，不能代替最终接口验收。

**10. Golden model 与测试覆盖**

分开报告两类比较：

| 比较 | 标准 | 回答的问题 |
|---|---|---|
| FPGA vs 同配置整数 RTL 仿真 / 整数软件 golden | 每一层、每个输出 byte 严格相等 | 上板、BRAM 时序和计算实现是否正确 |
| 整数 NPU vs PyTorch FBGEMM | 记录逐层差异、最终差异、argmax 和准确率 | Q31 模型与 FBGEMM 数值行为有什么差别 |

目前只验证了一个 linspace 固定输入，在最终 10 个输出上允许 ±1。这不证明全部 MNIST 输入都在 ±1 内，也不证明分类精度。FPGA vs 同一整数实现不能使用 ±1 容差。

当前 PyTorch 固定输入输出为 `[68,49,82,68,55,80,75,63,76,59]`，argmax 为 2；这不是有真实标签的 MNIST 图像。上板先与同配置整数仿真的实际输出比较，再与该 PyTorch 向量报告差异。

若继续使用 Q31，整数软件 golden 应使用已导出的 INT8 权重、INT32 bias、整数 multiplier、shift、zero-point 和 qmax，并复现符号扩展、累加位宽及 `(product + 2^(shift-1)) >> shift`。不要在软件 golden 中又改用浮点比例乘法。

真实 MNIST 输入应由电脑执行与 `tiny_MNIST/main_mnist.py` 中 `test_transforms` 完全一致的预处理，然后使用 checkpoint 的 QuantStub 生成 784 个 byte。硬件不执行浮点输入量化。输入保存为 8-bit code，中心化前按 unsigned 解读；权重才按 signed INT8 解读。

checkpoint 使用 reduce_range observer，但 FBGEMM 的物理输出仍是 quint8。当前导出器/RTL 设置了 qmax=127，不能把 observer 的 0..127 校准范围当作 FBGEMM 运行时对所有输入都饱和到 127。若要严格匹配 FBGEMM，除了 bias/multiplier/舍入路径，还要统一输出饱和范围与后续 MAC 的激活位宽。

建议依次测试：固定向量；10~100 张真实图像；全黑、全白、随机量化码、padding 和舍入边界；连续运行同一张输入（每次重写）；不同 LANES；8 KB/16 KB；CPU 与 NPU 共享单口的访问冲突；复位、超时、IRQ 清除。通过后跑完整 MNIST 测试集，输出实际准确率。

逐层调试可采用只执行第一层、前两层等方式，并在每次运行前重新加载输入/必要镜像，读取最后一层描述符指定的输出区。A/B 会交替复用，不能在最终推理完成后指望所有中间层还保存在 SRAM 中。

记录 `CYCLE` 的真实值来算 `T_compute=CYCLE/f_sys`。主机轮询次数受 USB/JTAG/UART 延迟影响，不能当作 NPU 周期。

**11. 常见问题与定位**

| 现象 | 首先检查 |
|---|---|
| Vivado 看不到板卡 | USB 数据线、板上电、JTAG 接口、线缆驱动 |
| 下载成功但 heartbeat 不动 | P17/100 MHz 约束、MMCM locked、复位极性 |
| get_hw_axis 为空 | 实现中是否加入 JTAG-to-AXI、下载的 bit 是否匹配、调试时钟是否运行 |
| AXI 操作卡住 | reset、AXI AR/AW/W/R/B 握手、适配器读延迟 |
| BUSY 不退 | ILA 查看 state、层描述符、存储 rvalid、通道/尺寸计数 |
| 第一层就不同 | 输入量化码、byte 小端打包、signed/unsigned、padding、权重布局 |
| FPGA vs 整数 RTL 相差 1 | 同步 RAM 读延迟、加法位宽、requant 流水线、读写冲突；不是 FBGEMM 容差问题 |
| 第一次正确，第二次错误 | activation A 已被覆盖，是否重写输入、是否清 DONE |
| 8 KB 正确，16 KB 错误 | 镜像、DESC_BASE、输入/输出地址和顶层参数是否一致 |
| 小 LANES 正确，大 LANES 错误 | lane 权重预取/分 bank、尾通道、输出写回仲裁 |
| 换频率后结果不稳定 | 实现时序、CDC、UART 分频、复位释放 |
| 综合资源暴涨 | byte 数组多端口读写、RAM 复制、大 mux、过宽 integer 乘法、ILA 深度 |

**12. 上板验证结束后应保留的结果**

保存 Vivado 版本、完整 part、板卡版本、LANES、逻辑 SRAM 容量、存储延迟、时钟频率、模型和输入文件校验值、bit/ltx、资源报告、时序报告、每张图像的 10 个输出码、argmax、cycle、比较结果和准确率。

FPGA 验证可以确认功能、软件交互和存储调度；FPGA 资源和频率不能直接当成 0.18 μm ASIC 的面积/时序/功耗。最终需接真实 SRAM 宏和工艺库验证；FPGA 专用 MMCM、ILA、JTAG-to-AXI 不属于流片逻辑。验证双端口 BRAM 的版本，也不等于验证了最终单口 SRAM 的性能。
