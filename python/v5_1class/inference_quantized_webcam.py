# inference_quantized_webcam.py — v5 1-Class, INT8 양자화 모델 웹캠 추론
# quantize.py 를 먼저 실행해서 model/quantized_win_cnn.pt 를 생성하세요
import os
import cv2
import time
import torch
import numpy as np
import torchvision
import albumentations as A
from albumentations.pytorch import ToTensorV2


BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
IMG_SIZE   = 256
GRID_SIZE  = 32
NUM_ANCHOR = 3
ANCHORS    = torch.tensor([[0.05, 0.05], [0.15, 0.10], [0.35, 0.20]])

# 양자화 후 confidence가 소폭 감소할 수 있으므로 0.40~0.50 권장
CONF_THRESH = 0.40
IOU_THRESH  = 0.15


# ── 디코딩 (1-Class 전용) ─────────────────────────────
def decode_predictions(pred, anchors, conf_thresh):
    pred = pred.squeeze(0).cpu()
    boxes, scores = [], []

    for a in range(NUM_ANCHOR):
        for gy in range(GRID_SIZE):
            for gx in range(GRID_SIZE):
                obj_conf  = torch.sigmoid(pred[a, gy, gx, 4]).item()
                cls_prob  = torch.sigmoid(pred[a, gy, gx, 5]).item()
                score     = obj_conf * cls_prob
                if score < conf_thresh:
                    continue

                tx, ty, tw, th = pred[a, gy, gx, :4]
                cx = (torch.sigmoid(tx).item() * 2.0 - 0.5 + gx) / GRID_SIZE
                cy = (torch.sigmoid(ty).item() * 2.0 - 0.5 + gy) / GRID_SIZE
                sig_w = torch.sigmoid(tw).item() * 2.0
                sig_h = torch.sigmoid(th).item() * 2.0
                bw = (sig_w ** 2) * anchors[a, 0].item()
                bh = (sig_h ** 2) * anchors[a, 1].item()

                boxes.append([cx - bw/2.0, cy - bh/2.0, cx + bw/2.0, cy + bh/2.0])
                scores.append(score)

    return torch.tensor(boxes), torch.tensor(scores)


def apply_nms(boxes, scores, iou_thresh):
    if len(boxes) == 0:
        return [], []
    keep = torchvision.ops.nms(boxes, scores, iou_thresh)
    return boxes[keep], scores[keep]


# ── 웹캠 추론 (스마트 트래킹 포함) ────────────────────────
def run_webcam():
    device = torch.device("cpu")
    print(f"[{device}] 양자화 모델 로드 중...")
    MODEL_PATH = os.path.join(BASE_DIR, "model", "quantized_win_cnn.pt")

    if not os.path.exists(MODEL_PATH):
        print(f"모델 파일 없음: {MODEL_PATH}\nquantize.py 를 먼저 실행하세요.")
        return

    model = torch.jit.load(MODEL_PATH, map_location=device)
    model.eval()

    transform = A.Compose([
        A.Resize(IMG_SIZE, IMG_SIZE),
        A.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ToTensorV2()
    ])

    cap = cv2.VideoCapture(0)
    print("양자화 모델 웹캠 시작! (종료: 'q')")

    fps_list    = []
    smoothed_box = None
    alpha        = 0.6
    missing_frames   = 0
    MAX_MISSING      = 5
    patience_counter = 0
    MAX_PATIENCE     = 3
    JUMP_THRESH      = 80

    with torch.no_grad():
        while True:
            loop_start = time.time()
            ret, frame = cap.read()
            if not ret:
                break

            h, w, _ = frame.shape
            center_x, center_y = w // 2, h // 2

            cv2.line(frame, (center_x, 0), (center_x, h), (0, 255, 255), 1)
            cv2.line(frame, (0, center_y), (w, center_y), (0, 255, 255), 1)
            cv2.circle(frame, (center_x, center_y), 5, (0, 0, 255), -1)

            img_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            input_tensor = transform(image=img_rgb)["image"].unsqueeze(0).to(device)

            inf_start  = time.time()
            pred_raw   = model(input_tensor)
            inf_time   = (time.time() - inf_start) * 1000

            B, C, H, W = pred_raw.shape
            pred = pred_raw.view(B, NUM_ANCHOR, 6, H, W).permute(0, 1, 3, 4, 2).contiguous()

            boxes, scores = decode_predictions(pred, ANCHORS, CONF_THRESH)
            boxes, scores = apply_nms(boxes, scores, IOU_THRESH)

            # 중앙과 가장 가까운 박스 선택
            best_box = None
            min_dist = float('inf')
            best_conf = 0.0

            for i in range(len(boxes)):
                x1 = int(max(0, boxes[i][0].item() * w))
                y1 = int(max(0, boxes[i][1].item() * h))
                x2 = int(min(w, boxes[i][2].item() * w))
                y2 = int(min(h, boxes[i][3].item() * h))
                hole_cx = (x1 + x2) // 2
                hole_cy = (y1 + y2) // 2
                dist = np.sqrt((hole_cx - center_x)**2 + (hole_cy - center_y)**2)
                if dist < min_dist:
                    min_dist  = dist
                    best_box  = (x1, y1, x2, y2, hole_cx, hole_cy)
                    best_conf = scores[i].item()

            # 스마트 트래킹 & 노이즈 필터링
            is_jumping = False
            if best_box is not None:
                missing_frames = 0
                current_box = np.array(best_box, dtype=np.float32)
                if smoothed_box is None:
                    smoothed_box     = current_box
                    patience_counter = 0
                else:
                    jump_dist = np.sqrt(
                        (current_box[4] - smoothed_box[4])**2 +
                        (current_box[5] - smoothed_box[5])**2
                    )
                    if jump_dist > JUMP_THRESH:
                        is_jumping = True
                        patience_counter += 1
                        if patience_counter >= MAX_PATIENCE:
                            smoothed_box     = current_box
                            patience_counter = 0
                            is_jumping       = False
                    else:
                        patience_counter = 0
                        smoothed_box = alpha * current_box + (1.0 - alpha) * smoothed_box
            else:
                missing_frames += 1
                if missing_frames > MAX_MISSING:
                    smoothed_box     = None
                    patience_counter = 0

            if smoothed_box is not None:
                bx1, by1, bx2, by2, bcx, bcy = map(int, smoothed_box)
                color = (0, 165, 255) if is_jumping else (0, 255, 0)
                label = f"Target {best_conf:.2f}" if not is_jumping else "Holding..."
                cv2.rectangle(frame, (bx1, by1), (bx2, by2), color, 3)
                cv2.putText(frame, label, (bx1, max(by1 - 10, 10)), cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)
                cv2.circle(frame, (bcx, bcy), 4, (255, 0, 0), -1)

            loop_time = time.time() - loop_start
            fps = 1 / loop_time if loop_time > 0 else 0
            fps_list.append(fps)
            if len(fps_list) > 30:
                fps_list.pop(0)

            cv2.putText(frame, f"FPS: {np.mean(fps_list):.1f} | Inf: {inf_time:.1f}ms",
                        (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)
            cv2.imshow("Quantized Pallet AI", frame)
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    run_webcam()
