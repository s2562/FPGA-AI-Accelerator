"""이미지 전처리 유틸리티 (256×256 리사이즈, 정규화)"""

import cv2
import numpy as np
import torch


def preprocess_image(img_bgr: np.ndarray, input_size: int = 256) -> torch.Tensor:
    """
    OpenCV BGR 이미지 → FPGA / 모델 입력 텐서 변환.
    img_bgr: H×W×3 numpy array (uint8)
    returns: [1, 3, input_size, input_size] float32 tensor [0, 1]
    """
    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    img_resized = cv2.resize(img_rgb, (input_size, input_size), interpolation=cv2.INTER_LINEAR)
    img_norm = img_resized.astype(np.float32) / 255.0
    tensor = torch.from_numpy(img_norm).permute(2, 0, 1).unsqueeze(0)  # [1,3,H,W]
    return tensor


def preprocess_for_fpga(img_bgr: np.ndarray, input_size: int = 256) -> np.ndarray:
    """
    FPGA 전송용 INT8 변환 (0~255, uint8).
    returns: [input_size, input_size, 3] uint8 array (RGB)
    """
    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    img_resized = cv2.resize(img_rgb, (input_size, input_size), interpolation=cv2.INTER_LINEAR)
    return img_resized  # uint8, RGB
