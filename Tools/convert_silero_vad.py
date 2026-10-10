"""Silero VAD（16kHz）をCore MLに変換し、コンパイル済みの .mlmodelc をAudioIOに置く。

JITモデルは分岐や状態を持つのでそのままでは変換できない。同じネットワークを素の演算で
書き直し、JITと出力が一致することを確かめてから変換する。

    uv venv -p 3.11 .venv && VIRTUAL_ENV=.venv uv pip install torch==2.5.1 coremltools silero-vad numpy
    .venv/bin/python Tools/convert_silero_vad.py

モデルの入出力（1回の呼び出しで512サンプル = 32ms）：
    input  audio (1, 576)   直前の入力の末尾64サンプル + 新しい512サンプル（16kHz、Float32）
    input  lstm  (2, 1, 128) LSTMの h と c。最初はゼロ
    output prob  (1, 1)      発話の確率
    output lstmOut (2, 1, 128)
"""

import os
import shutil
import subprocess
import sys
import tempfile

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
from silero_vad import load_silero_vad

CONTEXT = 64
CHUNK = 512
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Packages", "AudioIO", "Sources", "AudioIO", "Resources")
OUT_NAME = "SileroVAD"


class SileroVAD16k(torch.nn.Module):
    def __init__(self, sd):
        super().__init__()
        self.basis = torch.nn.Parameter(sd["stft.forward_basis_buffer"], requires_grad=False)
        self.convs = torch.nn.ParameterList()
        for i in range(4):
            self.convs.append(torch.nn.Parameter(sd[f"encoder.{i}.reparam_conv.weight"], requires_grad=False))
            self.convs.append(torch.nn.Parameter(sd[f"encoder.{i}.reparam_conv.bias"], requires_grad=False))
        self.w_ih = torch.nn.Parameter(sd["decoder.rnn.weight_ih"], requires_grad=False)
        self.w_hh = torch.nn.Parameter(sd["decoder.rnn.weight_hh"], requires_grad=False)
        self.b = torch.nn.Parameter(sd["decoder.rnn.bias_ih"] + sd["decoder.rnn.bias_hh"], requires_grad=False)
        self.out_w = torch.nn.Parameter(sd["decoder.decoder.2.weight"], requires_grad=False)
        self.out_b = torch.nn.Parameter(sd["decoder.decoder.2.bias"], requires_grad=False)

    def forward(self, audio, state):
        # STFT（反射パディング → 基底との畳み込み → 振幅）
        x = F.pad(audio.unsqueeze(1), (0, 64), mode="reflect")
        x = F.conv1d(x, self.basis, stride=128)
        real, imag = x[:, :129, :], x[:, 129:, :]
        x = torch.sqrt(real * real + imag * imag)
        # エンコーダー
        for i, stride in enumerate([1, 2, 2, 1]):
            x = F.relu(F.conv1d(x, self.convs[2 * i], self.convs[2 * i + 1], stride=stride, padding=1))
        x = x[:, :, 0]
        # LSTMCell
        h, c = state[0], state[1]
        gates = x @ self.w_ih.T + h @ self.w_hh.T + self.b
        i, f, g, o = gates[:, :128], gates[:, 128:256], gates[:, 256:384], gates[:, 384:]
        c = torch.sigmoid(f) * c + torch.sigmoid(i) * torch.tanh(g)
        h = torch.sigmoid(o) * torch.tanh(c)
        # デコーダー
        y = torch.sigmoid(F.conv1d(F.relu(h.unsqueeze(-1)), self.out_w, self.out_b))
        return y[:, :, 0], torch.stack([h, c])


def test_signal(seconds=20, sr=16000):
    """無音、雑音、声に似た変調音を混ぜた信号"""
    rng = np.random.default_rng(0)
    t = np.arange(seconds * sr) / sr
    voiced = 0.3 * np.sin(2 * np.pi * 150 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 4 * t))
    voiced += 0.15 * np.sin(2 * np.pi * 300 * t + np.sin(2 * np.pi * 5 * t))
    gate = ((t % 4) < 2).astype(np.float32)
    noise = 0.02 * rng.standard_normal(len(t))
    return (voiced * gate + noise).astype(np.float32)


def run_jit(signal):
    model = load_silero_vad()
    model.reset_states()
    return np.array([model(torch.from_numpy(signal[i:i + CHUNK]).unsqueeze(0), 16000).item()
                     for i in range(0, len(signal) - CHUNK + 1, CHUNK)])


def run_stream(fn, signal):
    """Swift側と同じ手順（文脈64サンプルと状態を引き継ぐ）で回す"""
    context = np.zeros(CONTEXT, dtype=np.float32)
    state = np.zeros((2, 1, 128), dtype=np.float32)
    probs = []
    for i in range(0, len(signal) - CHUNK + 1, CHUNK):
        x = np.concatenate([context, signal[i:i + CHUNK]])[None, :]
        p, state = fn(x, state)
        probs.append(p)
        context = x[0, -CONTEXT:]
    return np.array(probs)


def main():
    jit = load_silero_vad()
    sd = {k: v.detach().clone() for k, v in jit._model.state_dict().items()}
    model = SileroVAD16k(sd).eval()

    signal = test_signal()
    expected = run_jit(signal)

    def torch_fn(x, s):
        with torch.no_grad():
            p, s2 = model(torch.from_numpy(x), torch.from_numpy(s))
        return p.item(), s2.numpy()

    diff = np.abs(run_stream(torch_fn, signal) - expected).max()
    print(f"PyTorch再実装 と JIT の最大差: {diff:.2e}")
    assert diff < 1e-4, "再実装がJITと一致しない"

    example = (torch.zeros(1, CONTEXT + CHUNK), torch.zeros(2, 1, 128))
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, CONTEXT + CHUNK), dtype=np.float32),
                ct.TensorType(name="lstm", shape=(2, 1, 128), dtype=np.float32)],
        outputs=[ct.TensorType(name="prob", dtype=np.float32),
                 ct.TensorType(name="lstmOut", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = "Silero VAD v5 (16kHz, 512 samples + 64 context). MIT License, snakers4/silero-vad"

    def coreml_fn(x, s):
        out = mlmodel.predict({"audio": x, "lstm": s})
        return float(out["prob"].reshape(-1)[0]), out["lstmOut"]

    diff = np.abs(run_stream(coreml_fn, signal) - expected).max()
    print(f"Core ML と JIT の最大差: {diff:.2e}")
    assert diff < 1e-3, "Core MLの出力がJITと一致しない"

    # 確認用の期待値（Swiftのテストで同じ信号を流して比べる）
    np.save(os.path.join(tempfile.gettempdir(), "silero_expected.npy"), expected)

    with tempfile.TemporaryDirectory() as tmp:
        pkg = os.path.join(tmp, f"{OUT_NAME}.mlpackage")
        mlmodel.save(pkg)
        subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, tmp], check=True, stdout=subprocess.DEVNULL)
        os.makedirs(OUT_DIR, exist_ok=True)
        dest = os.path.join(OUT_DIR, f"{OUT_NAME}.mlmodelc")
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(os.path.join(tmp, f"{OUT_NAME}.mlmodelc"), dest)
    print(f"書き出し: {dest}")


if __name__ == "__main__":
    sys.exit(main())
