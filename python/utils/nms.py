"""Non-Maximum Suppression 유틸리티"""

import torch


def box_iou(boxes1: torch.Tensor, boxes2: torch.Tensor) -> torch.Tensor:
    """
    boxes: [N, 4] (x1, y1, x2, y2) 형식
    returns: [N, M] IoU 행렬
    """
    area1 = (boxes1[:, 2] - boxes1[:, 0]) * (boxes1[:, 3] - boxes1[:, 1])
    area2 = (boxes2[:, 2] - boxes2[:, 0]) * (boxes2[:, 3] - boxes2[:, 1])
    inter_x1 = torch.max(boxes1[:, 0].unsqueeze(1), boxes2[:, 0])
    inter_y1 = torch.max(boxes1[:, 1].unsqueeze(1), boxes2[:, 1])
    inter_x2 = torch.min(boxes1[:, 2].unsqueeze(1), boxes2[:, 2])
    inter_y2 = torch.min(boxes1[:, 3].unsqueeze(1), boxes2[:, 3])
    inter = (inter_x2 - inter_x1).clamp(0) * (inter_y2 - inter_y1).clamp(0)
    union = area1.unsqueeze(1) + area2 - inter
    return inter / (union + 1e-6)


def nms(boxes: torch.Tensor, scores: torch.Tensor, iou_threshold: float = 0.45) -> torch.Tensor:
    """
    NMS 적용.
    boxes: [N, 4] (x1,y1,x2,y2)
    scores: [N]
    returns: 살아남은 인덱스
    """
    order = scores.argsort(descending=True)
    keep = []
    while order.numel() > 0:
        i = order[0].item()
        keep.append(i)
        if order.numel() == 1:
            break
        iou = box_iou(boxes[i:i+1], boxes[order[1:]])[0]  # [M]
        order = order[1:][iou <= iou_threshold]
    return torch.tensor(keep, dtype=torch.long)
