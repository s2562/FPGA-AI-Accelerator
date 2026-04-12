# quantize.py — v5 1-Class, Conv-BN Fusion + Windows 호환 INT8 양자화
# 실행 후 model/quantized_win_cnn.pt 가 생성됩니다
import os
import glob
import cv2
import torch
import torch.nn as nn
from inference_webcam import PalletGridCNN
import albumentations as A
from albumentations.pytorch import ToTensorV2


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
IMG_SIZE  = 256


# ── 1. Conv+BN 수동 병합 ──────────────────────────────
def fuse_conv_bn(conv, bn):
    fused_conv = nn.Conv2d(
        conv.in_channels, conv.out_channels, conv.kernel_size,
        stride=conv.stride, padding=conv.padding, bias=True
    )
    scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    fused_conv.weight.data.copy_(conv.weight * scale.view(-1, 1, 1, 1))
    fused_conv.bias.data.copy_(bn.bias - bn.running_mean * scale)
    return fused_conv


# ── 2. Windows 호환 커스텀 양자화 레이어 ─────────────────
class WinQuantizedConv2d(nn.Module):
    def __init__(self, fused_conv, a_scale_in, a_scale_out):
        super().__init__()
        self.stride  = fused_conv.stride
        self.padding = fused_conv.padding

        w = fused_conv.weight.data
        self.w_scale = 127.0 / torch.max(torch.abs(w)).item() if torch.max(torch.abs(w)) > 0 else 1.0
        self.w_quantized = torch.round(w * self.w_scale).clamp(-127, 127) / self.w_scale

        self.weight = nn.Parameter(self.w_quantized, requires_grad=False)
        self.bias   = nn.Parameter(fused_conv.bias.data, requires_grad=False)

        self.a_scale_in  = a_scale_in
        self.a_scale_out = a_scale_out

    def forward(self, x):
        x_q   = torch.round(x * self.a_scale_in).clamp(-127, 127) / self.a_scale_in
        out   = nn.functional.conv2d(x_q, self.weight, self.bias, self.stride, self.padding)
        out_q = torch.round(out * self.a_scale_out).clamp(-127, 127) / self.a_scale_out
        return out_q


# ── 3. 캘리브레이션 및 저장 ────────────────────────────
def main():
    device = torch.device("cpu")
    model = PalletGridCNN().to(device)
    model.load_state_dict(
        torch.load(os.path.join(BASE_DIR, "model", "pallet_grid_cnn_1class.pt"),
                   map_location=device, weights_only=True)["model"]
    )
    model.eval()

    print("1. Conv-BN Fusion...")
    bb = model.backbone
    fused_layers = [
        fuse_conv_bn(bb[0], bb[1]),
        fuse_conv_bn(bb[4], bb[5]),
        fuse_conv_bn(bb[8], bb[9]),
        fuse_conv_bn(bb[12], bb[13]),
        model.head
    ]

    print("2. 캘리브레이션 (이미지 100장)...")
    calib_model = nn.Sequential(
        fused_layers[0], nn.LeakyReLU(0.1), nn.MaxPool2d(2),
        fused_layers[1], nn.LeakyReLU(0.1), nn.MaxPool2d(2),
        fused_layers[2], nn.LeakyReLU(0.1), nn.MaxPool2d(2),
        fused_layers[3], nn.LeakyReLU(0.1),
        fused_layers[4]
    )

    max_acts = [0.0] * 6
    def hook_fn(idx):
        def fn(m, i, o):
            max_acts[idx + 1] = max(max_acts[idx + 1], torch.max(torch.abs(o)).item())
        return fn
    hooks = [layer.register_forward_hook(hook_fn(i)) for i, layer in enumerate(fused_layers)]

    img_paths = glob.glob(os.path.join(BASE_DIR, "src", "valid", "images", "*.jpg"))[:100]
    transform = A.Compose([
        A.Resize(IMG_SIZE, IMG_SIZE),
        A.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ToTensorV2()
    ])

    with torch.no_grad():
        for path in img_paths:
            img = cv2.cvtColor(cv2.imread(path), cv2.COLOR_BGR2RGB)
            t = transform(image=img)["image"].unsqueeze(0)
            max_acts[0] = max(max_acts[0], torch.max(torch.abs(t)).item())
            calib_model(t)
    for h in hooks:
        h.remove()

    a_scales = [127.0 / m if m > 0 else 1.0 for m in max_acts]

    print("3. Quantized 모델 조립...")
    q_layers = [WinQuantizedConv2d(fused_layers[i], a_scales[i], a_scales[i+1]) for i in range(5)]
    quantized_model = nn.Sequential(
        q_layers[0], nn.LeakyReLU(0.1), nn.MaxPool2d(2),
        q_layers[1], nn.LeakyReLU(0.1), nn.MaxPool2d(2),
        q_layers[2], nn.LeakyReLU(0.1), nn.MaxPool2d(2),
        q_layers[3], nn.LeakyReLU(0.1),
        q_layers[4]
    )

    print("4. TorchScript 저장...")
    dummy = torch.randn(1, 3, 256, 256)
    traced = torch.jit.trace(quantized_model, dummy)
    save_path = os.path.join(BASE_DIR, "model", "quantized_win_cnn.pt")
    traced.save(save_path)
    print(f"저장 완료: {save_path}")


if __name__ == "__main__":
    main()
