# 🔺 FPGA-Based Smart Logistics Sorting System

<div align="center">

![FPGA](https://img.shields.io/badge/FPGA-Zybo_Z7--20_(Zynq_7020)-purple?style=for-the-badge)
![Language](https://img.shields.io/badge/Language-SystemVerilog-blue?style=for-the-badge)
![Clock](https://img.shields.io/badge/CLK-100MHz-green?style=for-the-badge)
![Model](https://img.shields.io/badge/Model-PalletGridCNN_Ver5.0-orange?style=for-the-badge)
![INT8](https://img.shields.io/badge/Quantization-INT8-red?style=for-the-badge)

**FPGA 기반 스마트 물류 분류 시스템 (자율주행 포크리프트 팔레트 감지)**

*YOLO-style Grid Detection CNN을 Zynq FPGA 위에 완전 하드웨어로 구현하는 실시간 추론 가속기*

</div>

---

## 📋 목차

1. [프로젝트 개요](#-프로젝트-개요)
2. [시스템 아키텍처](#-시스템-아키텍처)
3. [CNN 모델 스펙 (Ver 5.0)](#-cnn-모델-스펙-ver-50)
4. [RTL 모듈 구성](#-rtl-모듈-구성)
5. [하드웨어 자원 계획](#-하드웨어-자원-계획)
6. [성능 분석](#-성능-분석)
7. [Python 파이프라인](#-python-파이프라인)
8. [검증 전략](#-검증-전략)
9. [레포지토리 구조](#-레포지토리-구조)
10. [시작하기](#-시작하기)

---

## 🎯 프로젝트 개요

### 배경

자율주행 포크리프트(AGV)가 팔레트를 정확히 인식하기 위해서는 저지연(Low-Latency) 비전 추론이 필수입니다.  
GPU 기반 서버는 산업 현장의 전력·비용 제약에 맞지 않으며, **FPGA는 커스텀 데이터플로우 아키텍처로 실시간 AI 추론에 최적화**된 플랫폼입니다.

> **왜 FPGA + 커스텀 CNN인가?**  
> 범용 GPU는 고전력, 고비용이며 엣지 배포에 부적합합니다.  
> Zynq Z7-20 FPGA 위에 **INT8 양자화 CNN**을 직접 구현함으로써 저전력 실시간 팔레트 구멍 감지를 달성합니다.

### 목표

| 항목 | 목표값 |
|------|--------|
| **추론 속도** | ≥ 30 FPS (실시간) |
| **동작 클럭** | 100 MHz |
| **DSP 사용량** | 216 / 220개 (98%) |
| **BRAM 사용량** | ≤ 136 / 140개 |
| **양자화** | FP32 → INT8 (Post-Training Quantization) |
| **출력 형식** | YOLO-style Grid: 32×32×18 (3 Anchor × 6값) |

### 활용 분야

| 분야 | 설명 |
|------|------|
| 🏭 물류 자동화 | AGV 포크리프트가 팔레트 구멍을 실시간 탐지하여 자율 삽입 수행 |
| 📦 스마트 창고 | 팔레트 위치 및 자세 추정으로 자동 적재·분류 |
| 🔍 산업 비전 | 저비용 엣지 디바이스에서 실시간 객체 감지 |

---

## 🏗️ 시스템 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host (PC / ROS)                          │
│   PyTorch Training → PTQ Export → Weight Hex 변환 → UART 전송   │
└───────────────────────────────────────┬─────────────────────────┘
                                        │ UART (가중치 로드)
┌───────────────────────────────────────▼─────────────────────────┐
│                     Zybo Z7-20 (Zynq-7020)                      │
│                                                                 │
│  ┌─────────┐   ┌──────────────────────────────────────────────┐ │
│  │OV7670   │──▶│              CNN Accelerator Core            │ │
│  │Camera   │   │                                              │ │
│  │256×256×3│   │  line_buffer → window_reg → conv_engine      │ │
│  └─────────┘   │       ↓ mac_array (DSP 216개, 4-in×6-out)   │ │
│                │       ↓ scaler(재양자화) → bias → leaky_relu  │ │
│                │       ↓ maxpool → feature_mem (Ping-Pong)    │ │
│                │  fsm_controller (Layer 전환 제어)             │ │
│                └──────────────────┬───────────────────────────┘ │
│                                   │                             │
│  ┌────────────────────────────────▼──────────────────────────┐  │
│  │              Post-Processor (UART / AXI4-Lite)            │  │
│  │  Grid Decode → NMS → BBox 좌표 출력                       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  weight_mem (ROM, BRAM ~22개)   feature_mem (Ping-Pong, ~114개) │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🧠 CNN 모델 스펙 (Ver 5.0)

> **Hardware-Aware Co-Design** — 채널 수를 물리 블록 크기(In:4 × Out:6)의 LCM=12 배수로 설계하여 DSP 낭비 0% 달성

### 모델 구조

```
입력: 256×256×3  (카메라 RGB)
  ↓  [Zero-Pad → 4채널 정렬]
L0: Conv(3→12)  + BN + LeakyReLU + MaxPool   출력: 128×128×12
L1: Conv(12→24) + BN + LeakyReLU + MaxPool   출력:  64×64×24
L2: Conv(24→48) + BN + LeakyReLU + MaxPool   출력:  32×32×48
L3: Conv(48→96) + BN + LeakyReLU             출력:  32×32×96
HEAD: Conv(96→18, 1×1 커널)                  출력:  32×32×18
  ↓  [Reshape]
출력: [3 Anchor, 32, 32, 6]  → [tx, ty, tw, th, obj, cls]
```

### Anchor 설정 (1-Class: hole only)

| Anchor | 크기 | 대상 |
|--------|------|------|
| Anchor 0 | [0.05, 0.05] | 작은 구멍 |
| Anchor 1 | [0.15, 0.10] | 중간 구멍 |
| Anchor 2 | [0.35, 0.20] | 큰 팔레트 |

### 모델 버전 히스토리

| 버전 | 입력 | 구조 | 변경 이유 |
|------|------|------|-----------|
| Ver 1.0 | 64×64×3 | Patch Crop + FC | 실시간 추론 불가 |
| Ver 2.0 | 128×128×3 | YOLO-style, 2-Class, 4×4→8×8 Grid | Patch Crop 탈피 |
| Ver 3.0 | 256×256×3 | 3-Anchor, 32×32 Grid | 해상도·Grid 세분화 |
| Ver 4.0 | 256×256×3 | 2-Class(hole+pallet), YOLO-style | 클래스 분리 시도 |
| **Ver 5.0** ✅ | **256×256×3** | **1-Class(hole), HW-Aware 채널 12배수** | **DSP 낭비 0%** |

---

## ⚙️ RTL 모듈 구성

### 설계 순서 및 모듈 목록

| # | 모듈명 | 역할 | 비고 |
|---|--------|------|------|
| 1 | `dual_port_ram.sv` | 듀얼포트 BRAM 베이스 | `wr`/`rd` 포트 |
| 2 | `line_buffer.sv` | 2줄 슬라이딩 버퍼 (col 단위 shift) | 레지스터 기반 |
| 3 | `window_reg.sv` | 3×3×Ch 윈도우 슬라이딩 | `data_valid` 동기화 |
| 4 | `mac_array.sv` | 조합논리 트리 합산 (4-In × 6-Out) | DSP 216개 |
| 5 | `scaler.sv` | INT32 → INT8 재양자화 | scale factor 적용 |
| 6 | `bias.sv` | Bias 덧셈 (`b_fused`) | INT32 덧셈 |
| 7 | `leaky_relu.sv` | LeakyReLU (α≈0.1, 비트시프트 근사) | `(>>4)+(>>5)` |
| 8 | `maxpool.sv` | 2×2 Max Pooling (3-버퍼 구조) | |
| 9 | `conv_engine.sv` | L0~HEAD 통합 래퍼 (3×3 모드 / 1×1 모드) | HEAD 재활용 |
| 10 | `weight_mem.sv` | 가중치 ROM (`$readmemh`) | BRAM ~22개 |
| 11 | `feature_mem.sv` | 피처맵 Ping-Pong 버퍼 (R/W) | BRAM ~114개 |
| 12 | `output_mem.sv` | HEAD 출력 버퍼 (R/W) | |
| 13 | `fsm_controller.sv` | 레이어 전환 FSM 제어 | 5-state |
| 14 | `top.v` | 전체 연결 Top Module | |

### FSM 제어 루프 (의사코드)

```
for out_pass = 0 to ceil(Cout/6)-1:
  for row = 0 to H-1:
    for col = 0 to W-1:
      accumulator = 0
      for in_pass = 0 to ceil(Cin/4)-1:
        window = linebuf[row±1][col±1][in_pass*4:(in_pass+1)*4-1]
        weight = weight_mem[layer][out_pass][in_pass]
        accumulator += mac_array(window, weight)  // DSP 216개 동시 연산
      bias_add → leaky_relu → quantize → feature_mem[out_pass][row][col]
```

---

## 📊 하드웨어 자원 계획

### DSP 슬라이서

| 항목 | 값 |
|------|----|
| conv_engine 블록 | In 4채널 × Out 6채널 × 9(3×3 커널) = **216개** |
| HEAD 1×1 모드 | conv_engine 재활용 → 추가 DSP **0개** |
| **총 DSP** | **216 / 220개 ✅** |

### BRAM 사용량

| 용도 | 크기 | BRAM 수 |
|------|------|---------|
| weight_mem (ROM) | ~56 KB (가중치+bias) | ~13개 |
| Ping-Pong 버퍼 A+B | ~512 KB (최대 피처맵 256 KB × 2) | ~114개 |
| HEAD 출력 버퍼 | ~18 KB | 포함 |
| **합계** | **~586 KB** | **~127개 / 140개 ✅** |

> ⚠️ `DATA_WIDTH=8`, `DEPTH=2^n` 설계 원칙 준수 → BRAM 낭비 최소화  
> 합성 후 Vivado **Utilization Report → Block RAM Tile** 수치 반드시 확인

### 라인버퍼 (레지스터 기반)

| 레이어 | 크기 | 비고 |
|--------|------|------|
| L0 | 2×256×3×8bit = 1,536 byte | |
| L1~L3 | 최대 2×128×24×8bit = 6,144 byte | 레지스터로 충분 |

---

## ⚡ 성능 분석

### 레이어별 소요 클럭 (하드웨어 블록: In=4, Out=6)

| 레이어 | Cin→Cout | 해상도 | In패스 | Out패스 | 총패스 | 소요클럭 |
|--------|----------|--------|--------|---------|--------|----------|
| L0 | 3→12 | 128×128 | 1 | 2 | 2 | 32,768 |
| L1 | 12→24 | 64×64 | 3 | 4 | 12 | 49,152 |
| L2 | 24→48 | 32×32 | 6 | 8 | 48 | 49,152 |
| L3 | 48→96 | 32×32 | 12 | 16 | 192 | 196,608 |
| HEAD | 96→18 | 32×32 | 24 | 3 | 72 | 73,728 |
| **합계** | | | | | | **401,408 클럭** |

### 성능 요약

| 항목 | 값 |
|------|----|
| 100 MHz 기준 1프레임 | **4.01 ms** |
| 이론 최대 FPS | **~249 FPS** |
| 실시간 30fps 여유 | **약 8배** |
| 목표 10fps 여유 | **약 24배** |

---

## 🐍 Python 파이프라인

### 버전 관리 정책

`python/` 폴더는 모델 버전별로 분리합니다.  
각 버전 폴더에는 **실행 파일 5개만** 포함합니다.

```
python/
├── v4_2class/                     # Ver 4.0 — 2-Class (hole + pallet)
│   ├── train.py
│   ├── eval.py
│   └── inference_webcam.py
│
└── v5_1class/                     # Ver 5.0 — 1-Class, HW-Aware ✅ 현재
    ├── train.py
    ├── eval.py
    ├── inference_webcam.py
    ├── inference_quantized_webcam.py
    └── quantize.py
```

| 파일 | 설명 |
|------|------|
| `train.py` | 모델 학습 (FP32, PyTorch) |
| `eval.py` | mAP 평가 및 결과 출력 |
| `inference_webcam.py` | 웹캠 실시간 추론 (FP32) |
| `inference_quantized_webcam.py` | 웹캠 실시간 추론 (INT8 PTQ) |
| `quantize.py` | PTQ 수행 + FPGA용 `.hex` 가중치 추출 |

---

## 🧪 검증 전략

### RTL 시뮬레이션 (SystemVerilog)

| 대상 모듈 | 검증 방법 | 도구 |
|-----------|-----------|------|
| `dual_port_ram` | 읽기/쓰기 동시 접근, 경계값 테스트 | Vivado Sim |
| `line_buffer` | 3×3 윈도우 슬라이딩 정합성 | Vivado Sim |
| `mac_array` | INT8 × INT8 = INT32 누산 정확도 | VCS + Verdi |
| `conv_engine` | 레이어별 피처맵 출력 vs. PyTorch 결과 비교 | VCS + Verdi |
| `fsm_controller` | 레이어 전환 타이밍, in/out 패스 카운터 | VCS |
| Top Level | 전체 추론 결과 vs. PyTorch INT8 모델 비교 | VCS + Verdi |

### UVM 검증

| 대상 | 내용 |
|------|------|
| `mac_array` UVM | Random weight × input 1024회, Scoreboard 자동 비교 |
| `conv_engine` UVM | 레이어별 입출력 시퀀스, Coverage 분석 |

### 하드웨어 검증 (Zybo Z7-20)

- Vivado ILA (Integrated Logic Analyzer) 탑재 → 실시간 피처맵 값 모니터링
- UART 출력으로 BBox 좌표 Host PC 수신 및 mAP 계산
- OV7670 카메라 실제 팔레트 촬영 → 30fps 이상 확인

---

## 📁 레포지토리 구조

```text
FPGA-AI-Accelerator/
├── README.md
│
├── images/                            # 문서용 이미지
│   └── demo/
│
├── model/                             # 학습된 모델 가중치
│   ├── v4_2class/
│   │   └── best.pt
│   └── v5_1class/
│       ├── best.pt
│       └── best_quantized.pt
│
├── python/                            # Python 파이프라인 (학습/추론/평가/양자화)
│   ├── v4_2class/                     # Ver 4.0 — 2-Class
│   │   ├── train.py
│   │   ├── eval.py
│   │   └── inference_webcam.py
│   └── v5_1class/                     # Ver 5.0 — 1-Class, HW-Aware ✅ 현재
│       ├── train.py
│       ├── eval.py
│       ├── inference_webcam.py
│       ├── inference_quantized_webcam.py
│       └── quantize.py
│
├── rtl/                               # RTL 소스 (SystemVerilog)
│   ├── top/
│   │   └── top.v
│   ├── engine/
│   │   ├── conv_engine.sv
│   │   ├── mac_array.sv
│   │   ├── scaler.sv
│   │   ├── bias.sv
│   │   ├── leaky_relu.sv
│   │   └── maxpool.sv
│   ├── datapath/
│   │   ├── line_buffer.sv
│   │   └── window_reg.sv
│   ├── memory/
│   │   ├── dual_port_ram.sv
│   │   ├── weight_mem.sv
│   │   ├── feature_mem.sv
│   │   └── output_mem.sv
│   ├── control/
│   │   └── fsm_controller.sv
│   └── interface/
│       ├── uart_rx.sv
│       ├── uart_tx.sv
│       └── axi4_lite_slave.sv
│
├── tb/                                # 테스트벤치
│   ├── unit/
│   │   ├── tb_dual_port_ram.sv
│   │   ├── tb_line_buffer.sv
│   │   ├── tb_mac_array.sv
│   │   ├── tb_conv_engine.sv
│   │   └── tb_fsm_controller.sv
│   └── uvm/
│       ├── mac_array/
│       └── conv_engine/
│
├── constraints/
│   └── zybo_z7_20.xdc
│
├── scripts/
│   ├── vivado/
│   │   ├── create_project.tcl
│   │   └── run_synth_impl.tcl
│   └── util/
│       └── hex_merge.py
│
└── docs/
    ├── architecture/
    ├── spec/
    ├── diagrams/
    ├── presentation/
    └── references/
```

---

## 🚀 시작하기

### 요구사항

| 분류 | 항목 |
|------|------|
| **FPGA 보드** | Zybo Z7-20 (Zynq-7020) |
| **EDA 도구** | Vivado 2020.2 이상 |
| **검증 도구** | Synopsys VCS + Verdi (UVM) |
| **Python** | 3.8+ (PyTorch 2.0+, NumPy, OpenCV) |
| **카메라** | OV7670 (256×256 RGB) |

### 빠른 시작 (Python)

```bash
# 1. 환경 구성
pip install torch torchvision numpy opencv-python pyyaml

# 2. Ver 5.0 모델 학습
cd python/v5_1class
python train.py

# 3. 평가
python eval.py

# 4. 웹캠 실시간 추론 (FP32)
python inference_webcam.py

# 5. INT8 양자화 + FPGA 가중치 추출
python quantize.py

# 6. 양자화 모델 웹캠 추론
python inference_quantized_webcam.py
```

### Vivado 프로젝트 빌드

```bash
# 1. Vivado 프로젝트 자동 생성
vivado -mode batch -source scripts/vivado/create_project.tcl

# 2. 합성 및 구현
vivado -mode batch -source scripts/vivado/run_synth_impl.tcl

# 3. Utilization Report 확인 (BRAM ≤ 140개, DSP ≤ 220개)
#    Reports → Report Utilization → Block RAM Tile, DSP
```

---

## 🔧 설계 노트

> 프로젝트 진행 중 발생한 이슈 및 결정 근거를 기록합니다.

### ⚠️ 엔지니어라면 기억해야 할 것

- **생산자-소비자 속도 불일치**: `window_reg`(매 클럭 출력) vs `mac_array`(27클럭 소비) → 반드시 흐름 제어 또는 버퍼링 필요
- **Conv 연산의 수학적 하한**: 출력 픽셀 1개 = 반드시 `Cin × 9` 번의 곱셈. 픽셀 재활용으로 곱셈 횟수 줄이기 불가 (FFT 제외)
- **DSP 최대 활용 철학**: DSP를 아껴 Throughput을 버리는 것보다 DSP를 최대 활용하고 conv_engine을 레이어 간 재활용하는 것이 FPGA 설계 핵심
- **BRAM 실측 필수**: 이론 계산은 시작점. 최종 판단은 Vivado Utilization Report 실제 수치로 결정
- **HEAD에 MaxPool 없음**: HEAD는 공간 해상도를 유지한 채 채널만 변환 (`32×32×96 → 32×32×18`)

---

<div align="center">

**FPGA Smart Logistics Sorting System | 2026**

*Zybo Z7-20 (Zynq-7020) · SystemVerilog · Vivado · VCS + Verdi · PyTorch*

</div>
