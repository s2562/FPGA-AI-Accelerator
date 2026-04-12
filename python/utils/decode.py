"""Grid 예측값 → BBox 좌표 디코딩"""

import torch
from .anchors import ANCHORS_V5


def decode_predictions(
    pred: torch.Tensor,
    anchors: list = ANCHORS_V5,
    input_size: int = 256,
    grid_size: int = 32,
    conf_threshold: float = 0.5,
):
    """
    pred: [B, 18, 32, 32] — conv_engine HEAD 출력 그대로
    Reshape → [B, 3, 32, 32, 6] 후 디코딩
    returns: list of [N_det, 6] (x1,y1,x2,y2,conf,cls) per batch
    """
    B = pred.shape[0]
    A = len(anchors)      # 3
    G = grid_size         # 32
    pred = pred.view(B, A, 6, G, G).permute(0, 1, 3, 4, 2)  # [B,A,G,G,6]

    cell_size = input_size / G  # 8.0
    grid_y, grid_x = torch.meshgrid(
        torch.arange(G, dtype=torch.float32),
        torch.arange(G, dtype=torch.float32),
        indexing="ij",
    )  # [G, G]

    results = []
    for b in range(B):
        detections = []
        for a_idx, (aw, ah) in enumerate(anchors):
            tx = torch.sigmoid(pred[b, a_idx, :, :, 0])  # [G,G]
            ty = torch.sigmoid(pred[b, a_idx, :, :, 1])
            tw = pred[b, a_idx, :, :, 2]
            th = pred[b, a_idx, :, :, 3]
            obj = torch.sigmoid(pred[b, a_idx, :, :, 4])
            cls = torch.sigmoid(pred[b, a_idx, :, :, 5])
            conf = obj * cls

            cx = (grid_x + tx) * cell_size / input_size  # 정규화
            cy = (grid_y + ty) * cell_size / input_size
            bw = torch.exp(tw) * aw
            bh = torch.exp(th) * ah

            x1 = cx - bw / 2
            y1 = cy - bh / 2
            x2 = cx + bw / 2
            y2 = cy + bh / 2

            mask = conf > conf_threshold
            if mask.any():
                det = torch.stack([
                    x1[mask], y1[mask], x2[mask], y2[mask],
                    conf[mask], cls[mask]
                ], dim=1)
                detections.append(det)
        results.append(torch.cat(detections, dim=0) if detections else torch.zeros(0, 6))
    return results
