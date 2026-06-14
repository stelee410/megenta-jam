import torch
import torch.nn as nn
from models import Note_pedal

class Wrapper(nn.Module):
    """Tuple-returning wrapper for ONNX export (fixed output order)."""
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, x):
        d = self.m(x)
        return (d['reg_onset_output'], d['reg_offset_output'],
                d['frame_output'], d['velocity_output'],
                d['reg_pedal_onset_output'], d['reg_pedal_offset_output'],
                d['pedal_frame_output'])

model = Note_pedal(frames_per_second=100, classes_num=88)
ckpt = torch.load('ckpt.pth', map_location='cpu', weights_only=False)
model.load_state_dict(ckpt['model'], strict=False)
model.eval()
w = Wrapper(model).eval()

x = torch.zeros(1, 160000)
with torch.no_grad():
    outs = w(x)
print('output shapes:', [tuple(o.shape) for o in outs])



torch.onnx.export(
    w, x, 'piano_crnn.onnx',
    input_names=['audio'],
    output_names=['reg_onset', 'reg_offset', 'frame', 'velocity',
                  'pedal_onset', 'pedal_offset', 'pedal_frame'],
    opset_version=17,
    dynamo=False,
)
print('exported')

# ── Usage ────────────────────────────────────────────────────────────────────
# python -m venv venv && venv/bin/pip install torch torchlibrosa onnx onnxruntime
# Fetch models.py from qiuqiangkong/piano_transcription_inference (stub the
# move_data_to_device import), download the checkpoint:
#   https://huggingface.co/Genius-Society/piano_trans/resolve/main/
#     CRNN_note_F1%3D0.9677_pedal_F1%3D0.9186.pth   (MIT)
# Then: venv/bin/python export_piano_onnx.py
# Install the result as:
#   ~/Library/Application Support/MagentaRT/piano_crnn.onnx
