# inference_webcam.py — v5 1-Class (hole only), IMG_SIZE=256
import os
import cv2
import torch
import torch.nn as nn
import numpy as np
import torchvision
import albumentations as A
from albumentations.pytorch import ToTensorV2


# ── 설정 ──────────────────────────────────────────────
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

IMG_SIZE  = 256
GRID_SIZE = 32
NUM_CLASS = 1
NUM_ANCHOR = 3

ANCHORS = torch.tensor([
    [0.05, 0.05],  # 멀리 있는 구멍
    [0.15, 0.10],  # 중간 거리 구멍
    [0.35, 0.20],  # 코앞에 다가온 구멍
])

CONF_THRESH = 0.65
IOU_THRESH  = 0.15
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")


# ── 모델 아키텍처 ──────────────────────────────────────
class PalletGridCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = nn.Sequential(
            nn.Conv2d(3, 16, 3, padding=1, bias=False), nn.BatchNorm2d(16), nn.LeakyReLU(0.1), nn.MaxPool2d(2),
            nn.Conv2d(16, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.LeakyReLU(0.1), nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, padding=1, bias=False), nn.BatchNorm2d(64), nn.LeakyReLU(0.1), nn.MaxPool2d(2),
            nn.Conv2d(64, 128, 3, padding=1, bias=False), nn.BatchNorm2d(128), nn.LeakyReLU(0.1),
        )
        self.head = nn.Conv2d(128, NUM_ANCHOR * (5 + NUM_CLASS), 1)

    def forward(self, x):
        feat = self.backbone(x)
        out  = self.head(feat)
        B, _, H, W = out.shape
        return out.view(B, NUM_ANCHOR, 5 + NUM_CLASS, H, W).permute(0, 1, 3, 4, 2).contiguous()


# ── 디코딩 ────────────────────────────────────────────
def decode_predictions(pred, anchors, conf_thresh):
    pred = pred.squeeze(0).cpu()
    boxes, scores, class_ids = [], [], []

    for a in range(NUM_ANCHOR):
        for gy in range(GRID_SIZE):
            for gx in range(GRID_SIZE):
                obj_conf = torch.sigmoid(pred[a, gy, gx, 4]).item()
                cls_probs = torch.sigmoid(pred[a, gy, gx, 5:])
                max_prob, cls_id = torch.max(cls_probs, 0)
                score = obj_conf * max_prob.item()
                if score < conf_thresh:
                    continue

                tx, ty, tw, th = pred[a, gy, gx, :4]
                cx = (torch.sigmoid(tx).item() * 2.0 - 0.5 + gx) / GRID_SIZE
                cy = (torch.sigmoid(ty).item() * 2.0 - 0.5 + gy) / GRID_SIZE
                sig_w = torch.sigmoid(tw).item() * 2.0
                sig_h = torch.sigmoid(th).item() * 2.0
                bw = (sig_w * sig_w) * anchors[a, 0].item()
                bh = (sig_h * sig_h) * anchors[a, 1].item()

                boxes.append([cx - bw/2.0, cy - bh/2.0, cx + bw/2.0, cy + bh/2.0])
                scores.append(score)
                class_ids.append(cls_id.item())

    return torch.tensor(boxes), torch.tensor(scores), torch.tensor(class_ids)


def apply_nms(boxes, scores, class_ids, iou_thresh):
    if len(boxes) == 0:
        return [], [], []
    keep = torchvision.ops.nms(boxes, scores, iou_thresh)
    return boxes[keep], scores[keep], class_ids[keep]


# ── 웹캠 추론 ─────────────────────────────────────────
def run_webcam():
    print(f"[{DEVICE}] 1-Class 도킹 스나이퍼 모델 로드 중...")
    model = PalletGridCNN().to(DEVICE)
    MODEL_PATH = os.path.join(BASE_DIR, "model", "pallet_grid_cnn_1class.pt")

    if not os.path.exists(MODEL_PATH):
        print(f"에러: {MODEL_PATH} 파일이 없습니다.")
        return

    ckpt = torch.load(MODEL_PATH, map_location=DEVICE, weights_only=True)
    model.load_state_dict(ckpt["model"])
    model.eval()

    transform = A.Compose([
        A.Resize(IMG_SIZE, IMG_SIZE),
        A.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ToTensorV2(),
    ])

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("웹캠을 열 수 없습니다.")
        return

    print("1-Class 전용 웹캠 추론 시작! (종료: 'q')")

    with torch.no_grad():
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            h, w, _ = frame.shape
            center_x, center_y = w // 2, h // 2
            cv2.line(frame, (center_x, 0), (center_x, h), (0, 255, 255), 1, cv2.LINE_AA)
            cv2.line(frame, (0, center_y), (w, center_y), (0, 255, 255), 1, cv2.LINE_AA)
            cv2.circle(frame, (center_x, center_y), 5, (0, 0, 255), -1)

            img_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            input_tensor = transform(image=img_rgb)["image"].unsqueeze(0).to(DEVICE)

            pred = model(input_tensor)
            boxes, scores, class_ids = decode_predictions(pred, ANCHORS, CONF_THRESH)
            boxes, scores, class_ids = apply_nms(boxes, scores, class_ids, IOU_THRESH)

            for i in range(len(boxes)):
                x1 = int(max(0, boxes[i][0].item() * w))
                y1 = int(max(0, boxes[i][1].item() * h))
                x2 = int(min(w, boxes[i][2].item() * w))
                y2 = int(min(h, boxes[i][3].item() * h))
                conf = scores[i].item()

                color = (0, 255, 0)
                label = f"Hole {conf:.2f}"
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 3)
                cv2.putText(frame, label, (x1, max(y1 - 10, 10)), cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)

                hole_cx = (x1 + x2) // 2
                hole_cy = (y1 + y2) // 2
                cv2.circle(frame, (hole_cx, hole_cy), 4, (255, 0, 0), -1)

            cv2.imshow("1-Class Hole Sniper AI", frame)
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    run_webcam()
