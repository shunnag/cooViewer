# Real-ESRGAN x4plus anime 6B (RRDBNet) -> CoreML (single .mlmodel, fp16)
# 元チェックポイント: xinntao/Real-ESRGAN v0.2.2.4 (BSD-3-Clause)
# 入力: input [1,3,256,256] float 0-1 / 出力: output [1,3,1024,1024]
import sys
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

CKPT = sys.argv[1]
OUT = sys.argv[2]
TILE = 256


def make_layer(block, n, **kw):
    return nn.Sequential(*[block(**kw) for _ in range(n)])


class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb3(self.rdb2(self.rdb1(x)))
        return out * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64,
                 num_block=6, num_grow_ch=32):
        super().__init__()
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = make_layer(RRDB, num_block, num_feat=num_feat,
                               num_grow_ch=num_grow_ch)
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        feat = self.conv_first(x)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(
            F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(
            F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


model = RRDBNet()
state = torch.load(CKPT, map_location="cpu", weights_only=True)
params = state.get("params_ema", state.get("params", state))
model.load_state_dict(params, strict=True)
model.eval()
print("checkpoint loaded:", len(params), "tensors")

example = torch.rand(1, 3, TILE, TILE)
with torch.no_grad():
    traced = torch.jit.trace(model, example)
    reference = model(example).numpy()

mlmodel = ct.convert(
    traced,
    convert_to="neuralnetwork",
    inputs=[ct.TensorType(name="input", shape=(1, 3, TILE, TILE))],
    outputs=[ct.TensorType(name="output")],
)
mlmodel = ct.models.neural_network.quantization_utils.quantize_weights(
    mlmodel, nbits=16)
mlmodel.short_description = (
    "Real-ESRGAN x4plus anime 6B (RRDBNet). "
    "Converted from xinntao/Real-ESRGAN (BSD-3-Clause).")
mlmodel.save(OUT)
print("saved:", OUT)

# パリティ検証(CoreML 実行 vs PyTorch)
prediction = mlmodel.predict({"input": example.numpy()})
converted = prediction["output"]
diff = np.abs(converted - reference)
print("parity max abs diff:", float(diff.max()),
      "mean:", float(diff.mean()))
