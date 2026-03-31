# 🤖 FPGA-Based AI Inference Accelerator

<div align="center">

![FPGA](https://img.shields.io/badge/FPGA-Basys3%20Artix--7-purple?style=for-the-badge)
![Language](https://img.shields.io/badge/Language-SystemVerilog-blue?style=for-the-badge)
![Clock](https://img.shields.io/badge/CLK-100MHz-green?style=for-the-badge)
![AI](https://img.shields.io/badge/AI-Inference%20Accelerator-orange?style=for-the-badge)

**FPGA 기반 AI 추론 가속기 설계 프로젝트**

*저전력 FPGA 하드웨어에서 신경망 연산을 실시간 가속하는 추론 엔진 구현*

</div>

---

## 👥 팀 구성 및 역할

| 팀원 | 담당 역할 |
|------|-----------|
| **오수혁** (팀장) | 시스템 아키텍처 설계 · Top-Level Integration · Timing Closure · AXI4-Lite 인터페이스 |
| **박인범** | MAC 연산 유닛 설계 · 가중치 메모리 컨트롤러 · 고정소수점 양자화 |
| **손민재** | 데이터 흐름 제어 · DMA Controller · UVM 검증 · Coverage 분석 |
| **최무영** | 활성화 함수 구현 · Pooling 유닛 · HW 테스트 및 성능 최적화 |
| **이상현** | 소프트웨어 드라이버 · Host-FPGA 인터페이스 · 모델 파라미터 변환 툴 |

---

## 📋 목차

1. [프로젝트 개요](#-프로젝트-개요)
2. [시스템 구성](#-시스템-구성)
3. [AI 가속 파이프라인](#-ai-가속-파이프라인)
4. [모듈 상세 설계](#-모듈-상세-설계)
5. [성능 최적화](#-성능-최적화)
6. [FPGA 리소스 활용](#-fpga-리소스-활용)
7. [UVM 검증](#-uvm-검증)
8. [트러블슈팅](#-트러블슈팅)
9. [레포지토리 구조](#-레포지토리-구조)

---

## 🎯 프로젝트 개요

### 배경

AI 추론(Inference)은 **Data Input → Preprocessing → Layer Computation → Postprocessing → Output** 의 연계로 이루어진 연산 집약적 파이프라인입니다.  
현대의 엣지 AI 시스템은 낮은 레이턴시와 저전력을 동시에 요구하며, FPGA는 이를 만족하는 핵심 플랫폼으로 주목받고 있습니다.

> **왜 FPGA인가?**  
> GPU는 고전력 범용 병렬 프로세서로 엣지 환경에서 전력·비용 부담이 큽니다.  
> FPGA는 **데이터플로우 아키텍처(Dataflow Architecture)** 와 **공간적 병렬 처리(Spatial Parallelism)** 를 통해 저전력으로 실시간 AI 추론에 최적화된 하드웨어 구현이 가능합니다.

### 목표

- ✅ 고가의 GPU 없이 저전력 FPGA에서 신경망 추론 구현
- ✅ **고정소수점(Fixed-Point) 양자화** 기반 경량화 모델 하드웨어 가속
- ✅ **저비용 하드웨어(Basys3)** 환경에서 실시간 구동 가능한 AI 추론 엔진 설계

### 활용 분야

| 분야 | 설명 |
|------|------|
| 🚗 자율주행 엣지 AI | 낮은 레이턴시로 실시간 객체 검출 및 분류 수행 |
| 🏭 산업 결함 검출 | 생산 라인에서 실시간 비전 기반 불량 판별 |
| 🏥 의료 영상 분석 | 저전력 임베디드 의료기기에서 AI 추론 |

---

## 🔧 시스템 구성

### 사용 환경

| 분류 | 항목 |
|------|------|
| **언어** | SystemVerilog, Python, C |
| **도구** | Verdi (Synopsys), Vivado, VCS |
| **FPGA** | Xilinx Basys3 (Artix-7) |
| **Host** | PC (USB-UART / AXI4-Lite) |
| **프레임워크** | PyTorch (모델 학습 및 파라미터 추출) |

### 전체 시스템 아키텍처

```
┌─────────────────────────────────────────────────────┐
│                    Host (PC)                        │
│  PyTorch Model ──→ Quantize ──→ Weight Converter    │
│                                       │             │
│                                  UART / AXI4        │
└───────────────────────────────────────┼─────────────┘
                                        │
┌───────────────────────────────────────▼─────────────┐
│                  FPGA (Basys3)                      │
│                                                     │
│  Input Buffer ──→ Accelerator Core ──→ Output Reg   │
│       │               │                             │
│  Weight BRAM     MAC Array                          │
│  Bias BRAM       Activation                         │
│  Config Reg      Pooling                            │
└─────────────────────────────────────────────────────┘
```

---

## 🧠 AI 가속 파이프라인

### 전체 처리 흐름

```
Host (PC)
     │  ① 모델 파라미터 로드 (UART/AXI4-Lite)
     ▼
Weight & Bias BRAM 로드
     │  ② 입력 데이터 전송
     ▼
Input Feature Map Buffer
     │  ③ Convolution / FC 연산
     ▼
MAC Array (Multiply-Accumulate)
     │  ④ 활성화 함수 적용
     ▼
Activation Unit (ReLU / Sigmoid)
     │  ⑤ 풀링
     ▼
Pooling Unit (Max / Avg)
     │  ⑥ 다음 레이어로 전달
     ▼
Layer Controller (반복 제어)
     │  ⑦ 최종 추론 결과 출력
     ▼
Output Register → Host 반환
```

### 레이어별 처리 단계

| 단계 | 모듈 | 설명 |
|------|------|------|
| **① Parameter Load** | `weight_mem_ctrl` | BRAM에 가중치·바이어스 적재 |
| **② Input Staging** | `input_buffer` | 입력 Feature Map 버퍼링 |
| **③ MAC 연산** | `mac_array` | 병렬 곱셈-누산 연산 |
| **④ Activation** | `activation_unit` | ReLU / Sigmoid 비선형 변환 |
| **⑤ Pooling** | `pooling_unit` | Max/Average Pooling |
| **⑥ Layer Ctrl** | `layer_controller` | 다중 레이어 반복 스케줄링 |
| **⑦ Output** | `output_reg` | 결과 레지스터 → Host 전달 |

---

## 📐 모듈 상세 설계

### ⚙️ MAC Array (Multiply-Accumulate)

병렬 곱셈-누산 연산을 통해 Convolution 및 Fully Connected Layer의 핵심 연산을 수행합니다.

- **고정소수점 8-bit(INT8) 양자화** 기반으로 DSP 슬라이스 효율 극대화
- 병렬 PE(Processing Element) 배열로 Spatial Parallelism 구현
- 누산 결과 비트 확장으로 오버플로우 방지 (8-bit × 8-bit → 24-bit accumulator)

```
For each output neuron:
  acc = Σ (weight[i] × input[i]) + bias
```

### 🔵 Activation Unit

비선형 변환 함수를 하드웨어로 구현하여 신경망의 표현력을 확보합니다.

- **ReLU**: 단순 비교 연산으로 1클럭 처리 (`max(0, x)`)
- **Sigmoid / Tanh**: **256-entry LUT(ROM)** 기반 1클럭 조회
- 레이어 설정 레지스터로 활성화 함수 동적 선택

### 📊 Pooling Unit

- **Max Pooling**: 2×2 윈도우 내 최대값 선택, Line Buffer 기반 구현
- **Average Pooling**: 합산 후 비트 시프트로 나눗셈 연산 구현
- Stride 설정 레지스터로 1×1 ~ 4×4 윈도우 동적 선택

### 🗂️ Weight Memory Controller

- **Dual-port BRAM** 활용으로 읽기/쓰기 동시 접근
- AXI4-Lite 인터페이스를 통한 Host ↔ FPGA 파라미터 로드
- Layer별 베이스 어드레스 레지스터로 다중 레이어 가중치 관리

### 🔄 Layer Controller

- FSM 기반 레이어 순차 스케줄링
- Conv → Activation → Pooling → FC 순서 자동 제어
- 설정 레지스터를 통해 레이어 수·크기 동적 구성

---

## ⚡ 성능 최적화

### Timing Closure

| 항목 | 수정 전 | 수정 후 |
|------|---------|---------|
| Worst Negative Slack (WNS) | TBD | TBD |
| Total Negative Slack (TNS) | TBD | 0 ns (목표) |
| Failing Endpoints | TBD | 0 (목표) |

### 양자화 (Quantization)

- FP32 → INT8 Post-Training Quantization
- Scale Factor / Zero Point BRAM 저장
- 정밀도 손실 최소화를 위한 Per-Channel 양자화 지원

### 데이터 재사용 (Data Reuse)

- **Weight Stationary**: 가중치를 레지스터 파일에 고정, 입력 데이터 스트리밍
- **Line Buffer**: Convolution 윈도우 슬라이딩 시 메모리 접근 최소화

---

## 📊 FPGA 리소스 활용

| 리소스 | 예상 사용률 |
|--------|------------|
| DSPs (MAC 연산) | TBD |
| BRAM (Weight/Feature Map) | TBD |
| LUTs (Control Logic) | TBD |
| Registers (FF) | TBD |
| IO (AXI4/UART) | TBD |

---

## 🧪 UVM 검증

### MAC Array 검증

| 항목 | 결과 |
|------|------|
| Test Scenario | Random weight × input 1024회 |
| Pass Rate | TBD |
| Functional Coverage | TBD |

### AXI4-Lite 인터페이스 검증

| 항목 | 결과 |
|------|------|
| Write Transaction | TBD |
| Read Transaction | TBD |
| TX Coverage | TBD |

---

## 🔧 트러블슈팅

> 프로젝트 진행 중 발생한 이슈 및 해결 방법을 기록합니다.

---

## 📁 레포지토리 구조

```text
.
├── README.md
├── docs/
│   ├── architecture/
│   ├── diagrams/
│   ├── presentation/
│   └── references/
├── rtl/
│   ├── top/
│   │   └── top_ai_accel.sv          # Top Module
│   ├── core/
│   │   ├── mac_array.sv             # MAC 연산 배열
│   │   ├── activation_unit.sv       # 활성화 함수 (ReLU/Sigmoid)
│   │   ├── pooling_unit.sv          # Max/Avg Pooling
│   │   ├── layer_controller.sv      # 레이어 FSM 컨트롤러
│   │   └── output_reg.sv            # 출력 레지스터
│   ├── memory/
│   │   ├── weight_mem_ctrl.sv       # 가중치 메모리 컨트롤러
│   │   ├── input_buffer.sv          # 입력 Feature Map 버퍼
│   │   └── bram_wrapper.sv          # BRAM 래퍼
│   ├── interface/
│   │   ├── axi4_lite_slave.sv       # AXI4-Lite 슬레이브
│   │   ├── uart_rx.sv               # UART 수신
│   │   └── uart_tx.sv               # UART 송신
│   └── common/
│       ├── fifo.sv
│       ├── sync_ff.sv               # 2-FF 동기화
│       └── baud_tick_gen.sv
├── tb/
│   ├── mac/                         # UVM Testbench (MAC Array)
│   └── axi4/                        # UVM Testbench (AXI4-Lite)
├── constraints/
│   └── basys3.xdc
├── scripts/
│   ├── vivado/
│   └── quantize/                    # Python 양자화 스크립트
└── images/
```

---

## 🚀 시작하기

### 요구사항

- Xilinx Vivado 2020.2 이상
- Basys3 보드 × 1
- Python 3.8+ (PyTorch, NumPy)
- Synopsys VCS / Verdi (검증)

### 빌드 방법

```bash
# 1. 모델 파라미터 추출 (Host)
python scripts/quantize/export_weights.py --model model.pth --output weights.bin

# 2. Vivado 프로젝트 생성 후 RTL 소스 추가
# rtl/ 의 모든 .sv 파일 추가

# 3. Constraints 파일 적용
# constraints/basys3.xdc

# 4. 합성 및 구현
# Run Synthesis → Run Implementation → Generate Bitstream

# 5. 가중치 로드 및 추론 실행
python scripts/host/run_inference.py --port COM3 --input test_image.bin
```

---

<div align="center">

**FPGA AI Accelerator Project | 2026**

*Basys3 (Artix-7) · SystemVerilog · Vivado · Synopsys Verdi · PyTorch*

</div>
