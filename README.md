# FIO-SPDK脚本使用说明



此工具主要应用于NVMe SSD测试，单盘测试默认可覆盖多种IO模型，也可根据需求自定义IO模型

集成自动化测试与数据整理一体

此工具内部包含：

- 硬盘信息收集工具
- fio测试工具
- fio测试配置文件
- spdk工具



## 目录

- 注意事项
- 获取工具与帮助
- 选择测试设备（参数：-d，必选参数）
- 选择配置文件 （参数：-j，可选参数。不指定时使用配置文件job_cfg_common）
- 绑核、绑numa（参数：-c / -n，可选参数。不指定时不绑核/NUMA）
- nvme、spdk模式（参数：-t，可选参数，不指定时使用nvme方式）
- 日志输出
- **执行示例**


## 注意事项

> spdk模式在CentOS 8.5/7.6以下的版本上由于内核驱动（vfio-pci）的原因无法运行，请升级到CentOS 8.5/7.6或单独升级内核到5.10之后的版本。



## 获取工具与帮助

```shell
git clone https://github.com/jinqiangwang/fio-spdk.git
cd fio-spdk
./fio-spdk
example:
 ./fio-spdk.sh [-t nvme|spdk] -d "nvme0n1 nvme1n1" [-c "0-7 8-15" | -n "0 1"] [-j job_cfg_file]
         -t: nvme|spdk, test using nvme driver or spdk. default is nvme. optional
         -d: drive list. mandatory option
         -c: cpu core bind list. bind list is corresponding to drive list. optional
         -n: numa node bind list. -n takes precendence when both -c and -n are used. optional
         -j: job config file. default config file is "job_cfg_common". optional
```



## 选择测试设备（参数：-d）

使用 `-d` 参数来接收待测硬盘的盘符，支持单盘或多盘测试

```shell
#单盘测试
./fio-spdk -d nvme0n1

#多盘测试
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1...."
```



## 配置文件 （参数：-j）

使用 `-j` 参数接收配置文件来自定义测试模型，如果不添加 `-j` 参数默认执行 `job_cfg_common` 中的配置
如果只测试随机读可使用 `job_cfg_randread` 

```shell
./fio-spdk -d nvme0n1 -j test_cfg

./fio-spdk -d nvme0n1 -j job_cfg_randread
```

可通过修改 `test_cfg` 文件中 `workloads` 来指定：读写模式、块大小、队列数、队列深度.

**注意：各个参数间不要添加空格**

```shell
export percentile_list=1:5:10:25:50:75:90:95:99:99.5:99.9:99.99:99.999:99.9999:99.99999:99.999999
export ioengine=${ioengine-libaio}  #io引擎选择
export ramp_time=60          
export ramp_time_randwrite=1800     #随机写预处理时长
export runtime=1200                 #测试时长

# 读写模式    块大小   队列数量    队列深度
# seqread|  4k   |    1    |  64

export workloads=( \
###  注意：请不要在下面每行双引号中加任何空格
    "precond_seq|128k|1|128" \
    "seqread|4k|1|64" \
    "seqwrite|4k|1|128" \
    "randread|4k|8|256" \
    "randwrite|4k|8|32" \
    "randrw55|4k|8|32" \
    "randrw28|4k|8|32" \
    "randrw82|4k|8|32" \
    "randrw37|4k|8|32" \
    "randrw73|4k|8|32" \
    )
```



## 绑核、绑numa（参数：-c / -n）

使用 `-c` 或 `-n` 参数即可绑定相应的cpu核或者numa，通常建议绑定本地核或者numa。如果同时指定了-c和-n，只有-n生效

```shell
#绑核单盘
./fio-spdk -d nvme0n1 -c 0-3

#绑核多盘
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 nvme3n1" -c "0-3 4-7 8-11 12-15"

#绑定numa单盘（2个numa时）
./fio-spdk -d nvme0n1 -n 0

#绑定numa多盘（2个numa时）
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 nvme3n1" -c "0 0 1 1"
```

绑定numa时可通过 `tools/nvme_dev.sh` 来查看硬盘对应关系

```shell
# tools/nvme_dev.sh 
    drive      bdf  numa   lnksta  max_pl+rrq  temp  desc
  nvme0n1  34:00.0     0   8GT+x4    512+4096  34 C  ***
  nvme1n1  65:00.0     0  16GT+x4    512+4096  37 C  ***
  nvme2n1  66:00.0     0  16GT+x4    512+4096  38 C  ***
  nvme3n1  67:00.0     0  16GT+x4    512+4096  39 C  ***
  nvme4n1  68:00.0     0  16GT+x4    512+4096  39 C  ***
  nvme5n1  98:00.0     1  16GT+x8    512+4096  43 C  ***
  nvme6n1  e3:00.0     1  16GT+x4    512+4096  37 C  ***
  nvme7n1  e4:00.0     1  16GT+x4    512+4096  38 C  ***
  nvme8n1  e5:00.0     1  16GT+x4    512+4096  37 C  ***
  nvme9n1  e6:00.0     1  16GT+x4    512+4096  37 C  ***
```

绑核时可根据主机 `lscpu` 的输出，根据numa归属于numjob数量来选择相对应的核来绑定

```shell
# lscpu
Architecture:          x86_64
CPU op-mode(s):        32-bit, 64-bit
Byte Order:            Little Endian
CPU(s):                112
On-line CPU(s) list:   0-111
Thread(s) per core:    2
Core(s) per socket:    28
Socket(s):             2
NUMA node(s):          2
Vendor ID:             GenuineIntel
CPU family:            6
Model:                 106
Model name:            Intel(R) Xeon(R) Gold 6348 CPU @ 2.60GHz
Stepping:              6
CPU MHz:               3500.000
CPU max MHz:           3500.0000
CPU min MHz:           800.0000
BogoMIPS:              5200.00
Virtualization:        VT-x
L1d cache:             48K
L1i cache:             32K
L2 cache:              1280K
L3 cache:              43008K 
NUMA node0 CPU(s):     0-27,56-83 
NUMA node1 CPU(s):     28-55,84-111     
```



## nvme、spdk模式（参数：-t）

使用 `-t` 参数可指定测试的方法

```shell
#nvme模式
./fio-spdk -d nvme0n1 -t nvme
#不添加-t参数默认为nvme模式
./fio-spdk -d nvme0n1

#spdk模式
./fio-spdk -d nvme0n1 -t spdk
```



## 日志输出

测试完成后会生成以日期和测试时间为名称的文件夹，可获取整理后的数据 `result_summary.csv` 

```shell
20230209_174912
├── drvinfo
├── io_logs
├── iostat
├── result
├── result_summary.csv
└── sysinfo.log

4 directories, 2 files
```

## 执行示例

标准测试

```shell
#默认测试
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 ...." [-t spdk]

#绑核测试
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 nvme3n1...." [-t spdk] -c "0-3 4-7 8-11 12-15....."

#绑numa测试
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 ...." [-t spdk] -n "0 0 1 1....."
```

自定义模型测试

```shell
#默认测试
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 ...." [-t spdk] -j test_cfg

#绑核测试
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 nvme3n1...." [-t spdk] -c "0-3 4-7 8-11 12-15....." -j test_cfg

#绑numa测试
./fio-spdk -d "nvme0n1 nvme1n1 nvme2n1 ...." [-t spdk] -n "0 0 1 1....." -j test_cfg
```
