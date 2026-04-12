# Python 코드 구조

## 버전별 구성

```
python/
├── v4_2class/                    ← Rev3, hole + pallet 2클래스, IMG=128
│   ├── train.py
│   ├── inference_webcam.py
│   └── eval.py
│
└── v5_1class/                    ← hole only 1클래스, IMG=256
    ├── train.py
    ├── inference_webcam.py       ← FP32 추론
    ├── eval.py
    ├── quantize.py               ← Conv-BN Fusion + INT8 양자화 → quantized_win_cnn.pt 생성
    └── inference_quantized_webcam.py  ← 양자화 모델 추론
```

## 실행 순서 (v5_1class)

```bash
# 1. 학습
python train.py

# 2. FP32 추론 확인
python inference_webcam.py

# 3. 평가
python eval.py

# 4. 양자화 (model/pallet_grid_cnn_1class.pt 필요)
python quantize.py

# 5. 양자화 모델 추론
python inference_quantized_webcam.py
```

## 모델 파일 경로

각 버전 폴더 안의 `model/` 디렉토리에 체크포인트를 저장하세요.

| 파일 | 설명 |
|------|------|
| `v4_2class/model/pallet_grid_cnn_rev3.pt` | v4 Rev3 체크포인트 |
| `v5_1class/model/pallet_grid_cnn_1class.pt` | v5 FP32 체크포인트 |
| `v5_1class/model/quantized_win_cnn.pt` | v5 양자화 모델 (quantize.py 실행 후 생성) |
