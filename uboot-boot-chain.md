# U-Boot 启动链学习笔记

## 一、整体目录结构

```
src/u-boot/
├── arch/          # 架构相关（arm, x86, riscv, mips...）
├── board/         # 板级相关（特定开发板初始化）
├── common/        # 通用逻辑（board_f.c, board_r.c, cli...）
├── drivers/       # 设备驱动（MMC, USB, Net, Serial...）
├── cmd/           # Shell 命令实现（bootm, env, mmc...）
├── env/           # 环境变量存储后端（nand, mmc, fat...）
├── fs/            # 文件系统（ext4, fat, ubifs...）
├── net/           # 网络协议（DHCP, TFTP, NFS...）
├── lib/           # 通用库（crypto, lzma, fdtdec...）
├── include/       # 头文件
├── configs/       # 板级 defconfig
└── dts/           # 设备树
```

---

## 二、为什么需要多级启动

芯片上电后只有片内 SRAM 可用，外部 DDR 需要初始化才能使用。但初始化 DDR 的代码本身需要运行在 RAM 里——这是鸡和蛋的问题，因此需要多级启动。

```
上电时的硬件状态：
  ✅ 片内 SRAM：可用（几十 KB ~ 几百 KB）
  ❌ 外部 DDR：不可用，需要初始化
  ❌ Flash：只能 XIP，不能当 RAM 用
```

---

## 三、启动阶段划分

```
阶段 0：BootROM（芯片固化，用户不可改）
  └── 从 Flash 加载 SPL 到片内 SRAM，跳转执行

阶段 1：SPL（Secondary Program Loader）
  └── 运行在片内 SRAM，体积极小
  └── 主要任务：初始化 DDR，加载 U-Boot proper 到 DRAM

阶段 2：ATF/OP-TEE（可选，安全相关平台）
  └── 建立安全世界，驻留 EL3/Secure EL1

阶段 3：U-Boot proper
  └── 运行在 DRAM，功能完整
  └── 初始化外设，加载 Linux 内核

阶段 4：Linux Kernel
```

---

## 四、SPL 与 U-Boot proper 的链接脚本差异

| 对比点 | `u-boot.lds`（proper） | `u-boot-spl.lds`（SPL） |
|--------|----------------------|------------------------|
| MEMORY 区域 | 无（地址从 0 开始） | 显式声明 `.sram` 和 `.sdram` |
| `.rela.dyn` 段 | 保留（支持运行时重定位） | `/DISCARD/` 丢弃（节省体积） |
| PSCI secure 段 | 有（EL3 安全世界代码） | 无 |
| 目的 | 支持重定位到 DRAM | 固定运行在 SRAM，体积极小 |

### SPL 运行地址适配

不同 SoC 的 SRAM 地址不同，通过 defconfig 配置：

```
CONFIG_SPL_TEXT_BASE=0x80080000   # SPL 加载地址（来自芯片手册）
CONFIG_SPL_MAX_SIZE=0x58000       # SRAM 大小限制
```

构建时 `Makefile.xpl` 将其注入链接脚本：
```makefile
LDPPFLAGS += -DIMAGE_TEXT_BASE=$(CONFIG_SPL_TEXT_BASE)
LDPPFLAGS += -DIMAGE_MAX_SIZE=$(CONFIG_SPL_MAX_SIZE)
```
超出 `MAX_SIZE` 则链接直接报错，防止被 BootROM 截断。

---

## 五、完整启动调用链

### 5.1 SPL 阶段（运行在 SRAM）

```
BootROM
  └── 从 Flash 加载 SPL 到 SRAM，跳转

arch/arm/cpu/armv8/start.S :: _start
  └── reset
        ├── lowlevel_init()          最早的 SoC 硬件初始化（时钟/电压）
        └── _main()                  跳到 crt0

arch/arm/lib/crt0_64.S :: _main
  ├── 建立初始栈（指向 SRAM）
  ├── board_init_f_alloc_reserve()   在栈上分配 gd（global_data）
  ├── board_init_f_init_reserve()    清零 gd
  ├── board_init_f(0)                SPL 版本：串口初始化、设备树早期解析
  └── board_init_r()                 SPL 版本（common/spl/spl.c）

common/spl/spl.c :: board_init_r()
  ├── spl_soc_init()                 SoC 级初始化
  ├── dram_init()                    ← 初始化 DDR（核心任务）
  ├── spl_board_init()               板级最小初始化
  ├── board_boot_order()             决定从哪个设备加载
  ├── boot_from_devices()
  │     └── spl_load_image()
  │           └── spl_load()         从 eMMC/NAND/SD 读镜像到 DRAM
  │                 └── spl_parse_image_header()  解析镜像，确定 os 类型
  │
  └── jump_to_image()                不再返回
        ├── [有 ATF]  spl_invoke_atf()
        │             把 bl32(OP-TEE)/bl33(U-Boot) 入口地址传给 ATF
        └── [无 ATF]  jump_to_image_no_args()  直接跳到 U-Boot proper
```

### 5.2 ATF + OP-TEE 阶段（可选）

```
ATF (BL31, EL3)
  ├── 初始化安全世界基础设施
  ├── 驻留 EL3（永不退出）
  ├── 拉起 OP-TEE (BL32, Secure EL1)
  │     └── 初始化安全 OS，驻留 Secure EL1
  └── 拉起 U-Boot proper (BL33, EL2/EL1)
```

`spl_invoke_atf()` 的核心逻辑（common/spl/spl_atf.c）：
```c
// 从 FIT 镜像找 OP-TEE 入口 → bl32
node = spl_fit_images_find(blob, IH_OS_TEE);
bl32_entry = spl_fit_images_get_entry(blob, node);

// 从 FIT 镜像找 U-Boot proper 入口 → bl33
node = spl_fit_images_find(blob, IH_OS_U_BOOT);
bl33_entry = spl_fit_images_get_entry(blob, node);

// 跳入 ATF，把所有入口地址作为参数传入
bl31_entry(atf_entry, bl32_entry, bl33_entry, fdt_addr);
```

### 5.3 U-Boot proper 阶段（运行在 DRAM）

```
arch/arm/cpu/armv8/start.S :: _start   ← 从 DRAM 中的入口重新开始
  └── reset → _main()

arch/arm/lib/crt0_64.S :: _main
  ├── board_init_f(0)                  proper 版本（common/board_f.c）
  │     └── init_sequence_f[]          顺序执行初始化函数表
  │           ├── arch_cpu_init
  │           ├── serial_init
  │           ├── dram_init            记录内存布局（DDR 已由 SPL 初始化好）
  │           └── setup_dest_addr      计算重定位目标地址
  │
  ├── relocate_code()                  把 U-Boot 复制到 DRAM 顶部
  │                                    修正 .rela.dyn 中的所有绝对地址
  │
  └── board_init_r()                   proper 版本（common/board_r.c）
        └── init_sequence_r[]
              ├── initr_caches         开启 MMU + D-Cache
              ├── initr_malloc         heap 初始化
              ├── initr_dm             完整 Driver Model
              ├── board_init           板级初始化
              ├── initr_mmc            存储设备
              ├── initr_env            加载环境变量
              ├── console_init_r       完整控制台
              └── run_main_loop()      进入 Shell
```

### 5.4 引导 Linux

```
common/board_r.c :: run_main_loop()
  └── main_loop()

common/autoboot.c :: autoboot_command()
  ├── abortboot()                      等待倒计时，用户按键可打断
  └── run_command_list($bootcmd)       执行 bootcmd 环境变量

cmd/booti.c :: do_booti()
  └── do_bootm_linux()                 arch/arm/lib/bootm.c

arch/arm/lib/bootm.c :: do_bootm_linux()
  ├── boot_prep_linux()
  │     └── image_setup_libfdt()       动态修改 DTB
  │           ├── fdt_chosen()         写入 $bootargs 到 /chosen 节点
  │           ├── fdt_fixup_memory()   写入实际内存布局
  │           └── board_fix_fdt()      板级自定义修改
  │
  └── boot_jump_linux()
        └── armv8_switch_to_el2(ft_addr, 0, 0, 0, ep, ES_TO_AARCH64)
              │  x0 = DTB 地址（ARM64 Linux 启动约定）
              └── Linux 启动，U-Boot 不再返回
```

---

## 六、一张图总结

```
BootROM
  └──▶ SPL._start → crt0._main
            ├── board_init_f   [串口 / 最小初始化]
            └── board_init_r   [DDR初始化 → 加载镜像 → 跳走]
                                        │
                    ┌───────────────────┴───────────────────┐
                    │ 有 ATF                                 │ 无 ATF
                    ▼                                        ▼
               ATF (EL3) 驻留               U-Boot proper._start
               └─OP-TEE (Secure EL1) 驻留
               └─U-Boot proper._start
                                        │
                        U-Boot proper.crt0._main
                        ├── board_init_f  [完整外设初始化 + 重定位]
                        └── board_init_r  [Driver Model + Shell]
                                    └── main_loop
                                          └── $bootcmd
                                                └── do_booti
                                                      ├── 修改 DTB（写入 bootargs 等）
                                                      └── armv8_switch_to_el2(x0=dtb)
                                                            └── Linux Kernel
```

---

## 七、关键概念

### global_data（gd）
贯穿全程的核心结构体，在 AArch64 上用 `x18` 寄存器固定指向它。存储：
- DRAM 大小、重定位地址、堆栈地址
- 串口波特率、环境变量地址
- 时钟频率、bootstage 信息

### 重定位（Relocation）
U-Boot proper 被 SPL 加载到某个地址，但链接时假设的地址可能不同。`board_init_f` 完成后，`relocate_code()` 把自身复制到 DRAM 顶部，通过读取 `.rela.dyn` 段修正所有绝对地址。

### init_fnc_t 函数表模式
`board_f.c` 和 `board_r.c` 的初始化均为函数指针数组，顺序调用，任意一个返回非零即 `hang()`。清晰可读，易于裁剪。

### DTB 动态修改
U-Boot proper 在跳内核前会修改 DTB：
- `/chosen/bootargs` ← 从环境变量 `$bootargs` 写入
- `/memory/reg` ← 实际探测到的内存大小
- 各设备节点的 `mac-address`、`status` 等

Linux 拿到的 DTB 是经过 U-Boot 动态修改的版本。

### spl_image.os 的来源
跳转目标由镜像格式决定：

| 镜像格式 | os 值来源 |
|----------|----------|
| FIT image (.itb) | `.its` 文件中的 `os =` 字段 |
| Legacy uImage | `mkimage` 打包时写入的头部字段 |
| 裸 Image/zImage | 靠魔数识别，固定为 `IH_OS_LINUX` |
| Binman 内嵌 | 编译时硬编码为 `IH_OS_U_BOOT` |

---

## 八、安全启动扩展：ATF + OP-TEE

### ARM 异常级别

```
EL3  ATF          最高特权，安全监视器，两个世界都能访问
EL2  KVM/Xen      Hypervisor
EL1  Linux        Normal World 内核
EL1  OP-TEE OS    Secure World 内核（与 Linux 同级但硬件隔离）
EL0  Linux App    Normal World 用户程序
EL0  Trusted App  Secure World 用户程序
```

### SMC 指令
Secure Monitor Call，专用于从 EL1/EL2 陷入 EL3，类比 Linux 的 `syscall` 指令。

### Linux 调用 OP-TEE 的路径

```
Linux App
  └── ioctl(/dev/tee0)
        └── OP-TEE Client Driver
              └── smc #0
                    └── ATF (EL3)  [路由，不处理业务]
                          └── OP-TEE OS (Secure EL1)
                                └── Trusted App  [执行指纹/支付/DRM等]
                                └── 返回结果
                    └── ATF 切回 Normal World
              └── 返回结果给 Linux App
```

ATF 是透明的世界切换器，不参与业务逻辑。OP-TEE 占用 CPU 期间，发起 SMC 的那个核无法被 Linux 调度器用于其他进程。

### Falcon Mode（SPL 直接引导 Linux）
`CONFIG_SPL_OS_BOOT=y` 时，SPL 可跳过 U-Boot proper 直接加载 Linux，加快启动速度，但失去交互 Shell 和动态配置能力。
