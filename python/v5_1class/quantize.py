"""
quantize_v51_final.py — PalletGridCNN Ver 5.1 (Final) 양자화
모델 구조: 3->12->24->48->96 + Bottleneck(96->48->48->96)
학습 코드(train_pallet_v51_final.py)와 완벽히 호환되도록 작성
"""

import os
import glob
import cv2
import torch
import torch.nn as nn
from train_pallet_v51_final import PalletGridCNN_V51  # 학습 코드에서 모델 임포트
import albumentations as A
from albumentations.pytorch import ToTensorV2

BASE_DIR  = os.path.dirname(os.path.abspath(__file__))
IMG_SIZE  = 256

# ── 1. Conv-BN Fusion ────────────────────────────────────────
def fuse_conv_bn(conv, bn):
    fused = nn.Conv2d(
        conv.in_channels, conv.out_channels, conv.kernel_size,
        stride=conv.stride, padding=conv.padding, bias=True
    )
    scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    fused.weight.data.copy_(conv.weight * scale.view(-1, 1, 1, 1))
    fused.bias.data.copy_(bn.bias - bn.running_mean * scale)
    return fused

# ── 2. Quantized Conv ────────────────────────────────────────
class WinQuantizedConv2d(nn.Module):
    def __init__(self, fused_conv, a_scale_in, a_scale_out):
        super().__init__()
        self.stride  = fused_conv.stride
        self.padding = fused_conv.padding

        w = fused_conv.weight.data
        self.w_scale    = 127.0 / torch.max(torch.abs(w)).item() if torch.max(torch.abs(w)) > 0 else 1.0
        w_q             = torch.round(w * self.w_scale).clamp(-127, 127) / self.w_scale
        self.weight     = nn.Parameter(w_q, requires_grad=False)
        self.bias       = nn.Parameter(fused_conv.bias.data, requires_grad=False)
        self.a_scale_in  = a_scale_in
        self.a_scale_out = a_scale_out

    def forward(self, x):
        x_q   = torch.round(x * self.a_scale_in).clamp(-127, 127) / self.a_scale_in
        out   = nn.functional.conv2d(x_q, self.weight, self.bias, self.stride, self.padding)
        out_q = torch.round(out * self.a_scale_out).clamp(-127, 127) / self.a_scale_out
        return out_q

def main():
    device = torch.device("cpu")

    # ── 모델 로드 ─────────────────────────────────────────────
    model = PalletGridCNN_V51().to(device)
    ckpt  = torch.load(
        os.path.join(BASE_DIR, "model", "pallet_v51_best.pt"),
        map_location=device, weights_only=True
    )
    model.load_state_dict(ckpt["model"] if "model" in ckpt else ckpt)
    model.eval()
    bb = model.backbone

    # ── 1단계: Conv-BN Fusion (새로운 구조 대응) ─────────────
    print("1. Conv-BN Fusion 진행 중...")
    
    # train_pallet_v51_final.py의 backbone 구조
    # bb[0]  = Conv, bb[1]  = BN, bb[2]  = LReLU, bb[3]  = MaxPool (L0)
    # bb[4]  = Conv, bb[5]  = BN, bb[6]  = LReLU, bb[7]  = MaxPool (L1)
    # bb[8]  = Conv, bb[9]  = BN, bb[10] = LReLU, bb[11] = MaxPool (L2)
    # bb[12] = Conv, bb[13] = BN, bb[14] = LReLU (L3, MaxPool 없음)
    # bb[15] = Conv, bb[16] = BN, bb[17] = LReLU (L4a Bottleneck)
    # bb[18] = Conv, bb[19] = BN, bb[20] = LReLU (L4b Bottleneck)
    # bb[21] = Conv, bb[22] = BN, bb[23] = LReLU (L4c Bottleneck)
    
    fused_layers = [
        fuse_conv_bn(bb[0],  bb[1]),   # L0
        fuse_conv_bn(bb[4],  bb[5]),   # L1
        fuse_conv_bn(bb[8],  bb[9]),   # L2
        fuse_conv_bn(bb[12], bb[13]),  # L3
        fuse_conv_bn(bb[15], bb[16]),  # L4a
        fuse_conv_bn(bb[18], bb[19]),  # L4b
        fuse_conv_bn(bb[21], bb[22]),  # L4c
        model.head,                    # L7 (Head, BN 없음)
    ]

    # ── 2단계: 캘리브레이션 모델 조립 ────────────────────────────
    print("2. 캘리브레이션 모델 조립 중...")
    calib_model = nn.Sequential(
        fused_layers[0], bb[2],  bb[3],   # L0: FusedConv -> LReLU -> MaxPool
        fused_layers[1], bb[6],  bb[7],   # L1: FusedConv -> LReLU -> MaxPool
        fused_layers[2], bb[10], bb[11],  # L2: FusedConv -> LReLU -> MaxPool
        fused_layers[3], bb[14],          # L3: FusedConv -> LReLU
        fused_layers[4], bb[17],          # L4a: FusedConv -> LReLU
        fused_layers[5], bb[20],          # L4b: FusedConv -> LReLU
        fused_layers[6], bb[23],          # L4c: FusedConv -> LReLU
        fused_layers[7]                   # Head
    ).to(device)

    # ── 3단계: 캘리브레이션 (activation 최댓값 수집) ─────────────
    print("3. 캘리브레이션 진행 중 (이미지 최대 100장)...")
    max_acts = [0.0] * 9  # Input + 7 Conv + 1 Head

    def make_hook(idx):
        def fn(m, inp, out):
            max_acts[idx] = max(max_acts[idx], torch.max(torch.abs(out)).item())
        return fn

    hooks = [fl.register_forward_hook(make_hook(i + 1)) for i, fl in enumerate(fused_layers)]

    img_paths = glob.glob(
        os.path.join(BASE_DIR, "src", "valid", "images", "*.jpg")
    )[:100]

    if not img_paths:
        print("⚠️ 캘리브레이션 이미지 없음 — 경로 확인: src/valid/images/*.jpg")
        for h in hooks: h.remove()
        return

    transform = A.Compose([
        A.Resize(IMG_SIZE, IMG_SIZE),
        A.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ToTensorV2()
    ])

    with torch.no_grad():
        for path in img_paths:
            img = cv2.cvtColor(cv2.imread(path), cv2.COLOR_BGR2RGB)
            t   = transform(image=img)["image"].unsqueeze(0).to(device)
            max_acts[0] = max(max_acts[0], torch.max(torch.abs(t)).item())
            calib_model(t)

    for h in hooks: h.remove()

    a_scales = [127.0 / m if m > 0 else 1.0 for m in max_acts]
    print("   활성화 스케일:", [f"{s:.2f}" for s in a_scales])

    # ── 4단계: Quantized 모델 조립 ───────────────────────────────
    print("4. Quantized 모델 조립 중...")
    
    # Head 포함 전체 8레이어 양자화
    q_layers = [
        WinQuantizedConv2d(fused_layers[i], a_scales[i], a_scales[i + 1])
        for i in range(8)   # L0~L4c(7개) + Head(1개)
    ]
    
    quantized_model = nn.Sequential(
        q_layers[0], bb[2],  bb[3],   # L0
        q_layers[1], bb[6],  bb[7],   # L1
        q_layers[2], bb[10], bb[11],  # L2
        q_layers[3], bb[14],          # L3
        q_layers[4], bb[17],          # L4a
        q_layers[5], bb[20],          # L4b
        q_layers[6], bb[23],          # L4c
        q_layers[7],                  # Head ← FP32 → INT8 양자화
    ).to(device)

        # ── 4.5단계: FPGA RTL용 Scale Factor 추출 및 저장 ────────────
    print("\n===== FPGA RTL용 Scale Factor 추출 =====")

    layer_names = ["L0_input", "L0_out", "L1_out", "L2_out",
                   "L3_out", "L4a_out", "L4b_out", "L4c_out", "Head_out"]

    hw_scale_factors = []
    for i, (name, m, s) in enumerate(zip(layer_names, max_acts, a_scales)):
        # Q0.8 변환: a_scale은 이미 127/max_act 이므로
        # HW scale_factor = round(a_scale / 127 * 256)
        #                 = round(256 / max_act)
        hw_sf = round(256.0 / m) if m > 0 else 0
        hw_scale_factors.append(hw_sf)
        status = "⚠️ 8비트 초과!" if hw_sf > 127 or hw_sf < -128 else "✅ OK"
        print(f"  [{i}] {name:<12} | max_act={m:8.4f} | a_scale={s:8.4f} | HW_SF={hw_sf:5d}  {status}")

    # -- txt 저장
    sf_txt_path = os.path.join(BASE_DIR, "model", "scale_factors_v51.txt")
    with open(sf_txt_path, "w", encoding="utf-8") as f:  # encoding 추가
        f.write("# FPGA RTL Scale Factors (Q0.8, INT8 범위 기준)\n")
        f.write("# 형식: [레이어명] max_act | a_scale(float) | HW_scale_factor(정수)\n\n")
        for name, m, s, hw_sf in zip(layer_names, max_acts, a_scales, hw_scale_factors):
            f.write(f"{name:<12}: max_act={m:.4f}, a_scale={s:.4f}, HW_SF={hw_sf}\n")

    # -- hex 저장
    sf_hex_path = os.path.join(BASE_DIR, "model", "scale_factors_v51.hex")
    with open(sf_hex_path, "w", encoding="utf-8") as f:  # encoding 추가
        f.write("// FPGA RTL Scale Factors - readmemh load\n")  # em dash 제거
        f.write("// Layer order: L0_in, L0, L1, L2, L3, L4a, L4b, L4c, Head\n")
        for hw_sf in hw_scale_factors:
            val = hw_sf & 0xFF
            f.write(f"{val:02X}\n")
    
    # ── 4.6단계: FPGA RTL용 Bias 추출 ────────────────────────────
    print("\n===== FPGA RTL용 Bias 추출 (BN Fused) =====")

    bias_txt_path = os.path.join(BASE_DIR, "model", "bias_factors_v51.txt")
    with open(bias_txt_path, "w", encoding="utf-8") as f:
        f.write("# Fused Bias (Conv + BN 통합, 출력채널별 1개)\n\n")
        
        for i, fl in enumerate(fused_layers):
            if not hasattr(fl, 'bias') or fl.bias is None:
                print(f"  Layer {i}: bias 없음 (Head skip)")
                continue

            bias_data = fl.bias.data  # shape: [out_channels]
            
            # FPGA에서 쓸 INT8 양자화된 bias
            # bias도 a_scale_out 기준으로 양자화
            sf = a_scales[i + 1]
            bias_int = torch.round(bias_data * sf).clamp(-127, 127).to(torch.int8)

            print(f"  Layer {i} ({layer_names[i+1]}): "
                f"출력채널={len(bias_int)}개 | "
                f"범위=[{bias_int.min().item()}, {bias_int.max().item()}]")

            f.write(f"# Layer {i} ({layer_names[i+1]}) — {len(bias_int)}채널\n")
            for ch, val in enumerate(bias_int.tolist()):
                f.write(f"  CH{ch:03d}: {val:6d}  (0x{val & 0xFF:02X})\n")
            f.write("\n")

    print(f"  저장 완료: {bias_txt_path}")
    print("=========================================\n")
    # ── 5단계: TorchScript 저장 ──────────────────────────────────
    print("5. TorchScript 저장 중...")
    dummy      = torch.randn(1, 3, IMG_SIZE, IMG_SIZE)
    traced     = torch.jit.trace(quantized_model, dummy)
    save_path  = os.path.join(BASE_DIR, "model", "quantized_v51_final_head.pt")
    traced.save(save_path)
    print(f"✅ 저장 완료: {save_path}")

if __name__ == "__main__":
    main()