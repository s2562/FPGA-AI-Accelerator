# inference_webcam.py — v4 2-Class (hole + pallet), Rev3
import os
import time
import torch
import torch.nn as nn
import cv2
import numpy as np

# ── 하이퍼파라미터 ──────────────────────────────────
IMG_SIZE = 128
GRID_SIZE = 16
NUM_ANCHOR = 2
NUM_CLASS = 2
ANCHORS = torch.tensor([[0.15, 0.15], [0.40, 0.20]])
CONF_THRESHOLD = 0.50
IOU_THRESHOLD = 0.05
CLASS_NAMES = ["hole", "pallet"]

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CKPT_PATH = os.path.join(BASE_DIR, "model", "pallet_grid_cnn_rev3.pt")

tracked_hole = None
smoothing_factor = 0.3
smooth_rx1, smooth_ry1, smooth_rx2, smooth_ry2 = 0, 0, 0, 0


# ── 모델 아키텍처 (Rev3) ──────────────────────────
class PalletGridCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = nn.Sequential(
            nn.Conv2d(3, 16, 3, padding=1, bias=False), nn.BatchNorm2d(16), nn.LeakyReLU(0.1), nn.MaxPool2d(2),
            nn.Conv2d(16, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.LeakyReLU(0.1), nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, padding=1, bias=False), nn.BatchNorm2d(64), nn.LeakyReLU(0.1), nn.MaxPool2d(2),
            nn.Conv2d(64, 128, 3, padding=1, bias=False), nn.BatchNorm2d(128), nn.LeakyReLU(0.1)
        )
        self.head = nn.Conv2d(128, NUM_ANCHOR * (5 + NUM_CLASS), 1)

    def forward(self, x):
        feat = self.backbone(x)
        out  = self.head(feat)
        B, _, H, W = out.shape
        out = out.view(B, NUM_ANCHOR, 5 + NUM_CLASS, H, W)
        return out.permute(0, 1, 3, 4, 2).contiguous()


# ── NMS 및 디코드 ─────────────────────────
def box_iou(boxes1, boxes2):
    area1 = (boxes1[:, 2] - boxes1[:, 0]).clamp(min=0) * (boxes1[:, 3] - boxes1[:, 1]).clamp(min=0)
    area2 = (boxes2[:, 2] - boxes2[:, 0]).clamp(min=0) * (boxes2[:, 3] - boxes2[:, 1]).clamp(min=0)
    inter_x1 = torch.max(boxes1[:, 0].unsqueeze(1), boxes2[:, 0].unsqueeze(0))
    inter_y1 = torch.max(boxes1[:, 1].unsqueeze(1), boxes2[:, 1].unsqueeze(0))
    inter_x2 = torch.min(boxes1[:, 2].unsqueeze(1), boxes2[:, 2].unsqueeze(0))
    inter_y2 = torch.min(boxes1[:, 3].unsqueeze(1), boxes2[:, 3].unsqueeze(0))
    inter = (inter_x2 - inter_x1).clamp(min=0) * (inter_y2 - inter_y1).clamp(min=0)
    return inter / (area1.unsqueeze(1) + area2.unsqueeze(0) - inter + 1e-6)


def decode_single_image(pred_single):
    anchors = ANCHORS.to(DEVICE).view(NUM_ANCHOR, 1, 1, 2)
    grid_y, grid_x = torch.meshgrid(
        torch.arange(GRID_SIZE, device=DEVICE),
        torch.arange(GRID_SIZE, device=DEVICE),
        indexing='ij'
    )
    grid = torch.stack((grid_x, grid_y), dim=-1).unsqueeze(0).float()

    pred_cxcy = (torch.sigmoid(pred_single[..., 0:2]) * 2.0 - 0.5 + grid) / GRID_SIZE
    pred_wh   = (torch.sigmoid(pred_single[..., 2:4]) * 2.0) ** 2 * anchors
    obj       = torch.sigmoid(pred_single[..., 4])
    cls_prob  = torch.sigmoid(pred_single[..., 5:])

    cls_max_prob, cls_ids = torch.max(cls_prob, dim=-1)
    scores = obj * cls_max_prob
    mask = (scores > CONF_THRESHOLD) & (obj > 0.5)

    if mask.sum() == 0:
        return []

    cx, cy = pred_cxcy[mask][:, 0], pred_cxcy[mask][:, 1]
    w, h   = pred_wh[mask][:, 0], pred_wh[mask][:, 1]
    scores, cls_ids = scores[mask], cls_ids[mask]

    x1 = (cx - w / 2) * IMG_SIZE
    y1 = (cy - h / 2) * IMG_SIZE
    x2 = (cx + w / 2) * IMG_SIZE
    y2 = (cy + h / 2) * IMG_SIZE
    boxes_xyxy = torch.stack([x1, y1, x2, y2], dim=-1).clamp(0, IMG_SIZE - 1)

    keep = []
    idxs = scores.argsort(descending=True)
    while idxs.numel() > 0:
        i = idxs[0]
        keep.append(i.item())
        if idxs.numel() == 1:
            break
        ious = box_iou(boxes_xyxy[i].unsqueeze(0), boxes_xyxy[idxs[1:]])[0]
        idxs = idxs[1:][ious <= IOU_THRESHOLD]

    return [
        [int(cls_ids[i].item()), float(scores[i].item()),
         float(boxes_xyxy[i, 0].item()), float(boxes_xyxy[i, 1].item()),
         float(boxes_xyxy[i, 2].item()), float(boxes_xyxy[i, 3].item())]
        for i in keep
    ]


# ── 웹캠 추론 ──────────────────────────────────────────────────
def run_webcam():
    global tracked_hole, smooth_rx1, smooth_ry1, smooth_rx2, smooth_ry2

    if not os.path.exists(CKPT_PATH):
        print(f"체크포인트가 없습니다: {CKPT_PATH}")
        return

    print("Rev3 모델 로딩 중...")
    model = PalletGridCNN().to(DEVICE)
    model.load_state_dict(torch.load(CKPT_PATH, map_location=DEVICE)["model"])
    model.eval()

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        return

    print("실시간 추론 시작! (종료: 'q')")

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        h_orig, w_orig = frame.shape[:2]
        crop_size = min(h_orig, w_orig)
        start_x = w_orig // 2 - crop_size // 2
        start_y = h_orig // 2 - crop_size // 2
        frame_cropped = frame[start_y:start_y+crop_size, start_x:start_x+crop_size]

        img_resized = cv2.resize(frame_cropped, (IMG_SIZE, IMG_SIZE))
        img_rgb = cv2.cvtColor(img_resized, cv2.COLOR_BGR2RGB)
        img_norm = (img_rgb / 255.0 - np.array([0.485, 0.456, 0.406])) / np.array([0.229, 0.224, 0.225])
        img_tensor = torch.tensor(img_norm).permute(2, 0, 1).unsqueeze(0).float().to(DEVICE)

        with torch.no_grad():
            pred = model(img_tensor)[0]
        dets = decode_single_image(pred)

        scale = crop_size / IMG_SIZE
        center_x, center_y = w_orig / 2, h_orig / 2

        cv2.line(frame, (int(center_x) - 20, int(center_y)), (int(center_x) + 20, int(center_y)), (255, 0, 0), 2)
        cv2.line(frame, (int(center_x), int(center_y) - 20), (int(center_x), int(center_y) + 20), (255, 0, 0), 2)

        valid_holes = []
        for cls_id, score, x1, y1, x2, y2 in dets:
            box_w, box_h = x2 - x1, y2 - y1
            if cls_id == 0:
                if box_w > IMG_SIZE * 0.4 or box_h > IMG_SIZE * 0.4: continue
                if box_w < IMG_SIZE * 0.05 or box_h < IMG_SIZE * 0.02: continue
                aspect_ratio = box_w / (box_h + 1e-5)
                if aspect_ratio > 3.0 or aspect_ratio < 1.2: continue
                if box_w * box_h < (IMG_SIZE * IMG_SIZE) * 0.005: continue
                cy_128, cx_128 = y1 + box_h / 2, x1 + box_w / 2
                if cy_128 < IMG_SIZE * 0.15 or cy_128 > IMG_SIZE * 0.85: continue
                if cx_128 < IMG_SIZE * 0.05 or cx_128 > IMG_SIZE * 0.95: continue

                rx1 = int(x1 * scale) + start_x
                ry1 = int(y1 * scale) + start_y
                rx2 = int(x2 * scale) + start_x
                ry2 = int(y2 * scale) + start_y

                if rx2 > rx1 and ry2 > ry1:
                    roi = frame[ry1:ry2, rx1:rx2]
                    if roi.size > 0:
                        roi_gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
                        if np.mean(roi_gray) < 25: continue

                cx_r, cy_r = (rx1 + rx2) / 2, (ry1 + ry2) / 2
                valid_holes.append((rx1, ry1, rx2, ry2, cx_r, cy_r, score))

        best_hole = None

        if tracked_hole is not None:
            last_cx, last_cy = tracked_hole
            closest_dist = 80
            for hole in valid_holes:
                _, _, _, _, cx_h, cy_h, _ = hole
                dist = ((cx_h - last_cx)**2 + (cy_h - last_cy)**2)**0.5
                if dist < closest_dist:
                    closest_dist = dist
                    best_hole = hole
            if best_hole is None:
                tracked_hole = None

        if tracked_hole is None and len(valid_holes) > 0:
            min_dist = float('inf')
            for hole in valid_holes:
                _, _, _, _, cx_h, cy_h, _ = hole
                dist = ((center_x - cx_h)**2 + (center_y - cy_h)**2)**0.5
                if dist < min_dist:
                    min_dist = dist
                    best_hole = hole

        if best_hole is None:
            smooth_rx1 = 0
            tracked_hole = None
            cv2.putText(frame, "STATUS: SEARCHING...", (10, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
        else:
            rx1, ry1, rx2, ry2, cx_h, cy_h, best_score = best_hole
            tracked_hole = (cx_h, cy_h)

            if smooth_rx1 == 0:
                smooth_rx1, smooth_ry1, smooth_rx2, smooth_ry2 = rx1, ry1, rx2, ry2
            else:
                smooth_rx1 = int(smoothing_factor * rx1 + (1 - smoothing_factor) * smooth_rx1)
                smooth_ry1 = int(smoothing_factor * ry1 + (1 - smoothing_factor) * smooth_ry1)
                smooth_rx2 = int(smoothing_factor * rx2 + (1 - smoothing_factor) * smooth_rx2)
                smooth_ry2 = int(smoothing_factor * ry2 + (1 - smoothing_factor) * smooth_ry2)

            cv2.rectangle(frame, (smooth_rx1, smooth_ry1), (smooth_rx2, smooth_ry2), (0, 0, 255), 3)
            cv2.putText(frame, f"TARGET {best_score:.2f}", (smooth_rx1, max(0, smooth_ry1-10)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

            smooth_cx = int((smooth_rx1 + smooth_rx2) / 2)
            smooth_cy = int((smooth_ry1 + smooth_ry2) / 2)
            cv2.line(frame, (int(center_x), int(center_y)), (smooth_cx, smooth_cy), (0, 255, 255), 2, cv2.LINE_AA)

            x_error = smooth_cx - center_x
            cv2.putText(frame, "Error X: {:.1f} px".format(x_error), (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)
            cv2.putText(frame, "STATUS: LOCKED", (10, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)

        cv2.rectangle(frame, (start_x, start_y), (start_x+crop_size, start_y+crop_size), (255, 255, 255), 1)
        cv2.imshow("Pallet Detection (Real-Time Tracking)", frame)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    run_webcam()
