"""Anchor 크기 정의 및 IoU 계산 유틸리티"""

import torch

# Ver 5.0 기준 Anchor (정규화된 [w, h], 256×256 입력 기준)
ANCHORS_V5 = [
    [0.05, 0.05],  # 작은 구멍
    [0.15, 0.10],  # 중간 구멍
    [0.35, 0.20],  # 큰 팔레트
]


def anchor_iou(box_wh: torch.Tensor, anchors: list) -> torch.Tensor:
    """
    박스와 각 Anchor 간 IoU 계산 (중심점 정렬 기준).
    box_wh: [N, 2] tensor (w, h)
    anchors: list of [w, h]
    returns: [N, num_anchors]
    """
    anchors_t = torch.tensor(anchors, dtype=torch.float32)  # [A, 2]
    # 최소 w/h로 교집합 계산
    inter_w = torch.min(box_wh[:, 0:1], anchors_t[:, 0])  # [N, A]
    inter_h = torch.min(box_wh[:, 1:2], anchors_t[:, 1])  # [N, A]
    inter = inter_w * inter_h
    box_area = box_wh[:, 0] * box_wh[:, 1]                 # [N]
    anchor_area = anchors_t[:, 0] * anchors_t[:, 1]        # [A]
    union = box_area.unsqueeze(1) + anchor_area - inter
    return inter / (union + 1e-6)


def assign_anchors(targets: torch.Tensor, anchors: list, grid_size: int = 32):
    """
    GT 박스를 가장 적합한 Anchor에 할당.
    targets: [N, 5] (img_idx, cls, cx, cy, w, h) 정규화 좌표
    returns: anchor_idx per target [N]
    """
    wh = targets[:, 4:6]
    iou = anchor_iou(wh, anchors)   # [N, A]
    return iou.argmax(dim=1)
