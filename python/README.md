# 🐍 Python 파이프라인

## 개요

FPGA CNN 가속기에 탑재될 PalletGridCNN 모델의 **학습, 추론, 평가, PTQ 양자화, FPGA 가중치 추출**을 담당하는 파이프라인입니다.

## 버전 관리 정책

각 기능 폴더(`train/`, `inference/`, `eval/`, `quantize/`) 아래에 `v{버전}_{설명}/` 디렉토리를 유지합니다.  
**현재 최신 버전: `v5_hw_aware/`** (Hardware-Aware Co-Design, 채널 12배수)

| 버전 | 폴더명 | 설명 |
|------|--------|------|
| Ver 4.0 | `v4_1class/` | 1-Class baseline, 채널 16/32/64/128 |
| **Ver 5.0** ✅ | **`v5_hw_aware/`** | HW-Aware, 채널 12/24/48/96, DSP 낭비 0% |

## 빠른 시작

```bash
# 학습
cd train/v5_hw_aware && python train.py --config config.yaml

# 추론
cd inference/v5_hw_aware && python infer.py --img path/to/image.jpg

# 평가
cd eval/v5_hw_aware && python eval_map.py

# PTQ + FPGA 가중치 추출
cd quantize/v5_hw_aware && python ptq.py && python export_weights.py
```

## 폴더 구조

```
python/
├── dataset/        # 데이터셋 (raw → annotated → augmented → splits)
├── train/          # 모델 학습 (v4_1class, v5_hw_aware)
├── inference/      # 추론 및 데모 (v4_1class, v5_hw_aware)
├── eval/           # 평가 및 버전 비교 (v4_1class, v5_hw_aware)
├── quantize/       # PTQ 및 FPGA 가중치 .hex 변환 (v4_1class, v5_hw_aware)
└── utils/          # 공통 유틸 (anchors, nms, decode, preprocess)
```

## 요구사항

```
torch >= 2.0
torchvision
numpy
opencv-python
pyyaml
matplotlib
```
