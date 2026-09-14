#!/usr/bin/env python3
"""
BestShot - ONNX Embedding Model Exporter
Exports a pre-trained vision model (MobileNetV3-Small) to ONNX format for BestShot.

Usage:
    pip install torch torchvision
    python export_embedding_model.py

Output:
    ../assets/models/embedding.onnx (or ./embedding.onnx)
"""

import os
import sys

# Ensure UTF-8 output on Windows terminals (avoids UnicodeEncodeError on emoji/unicode)
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

def export_model():
    try:
        import torch
        import torchvision.models as models
    except ImportError:
        print("Error: PyTorch and torchvision are required.")
        print("Please run: pip install torch torchvision")
        sys.exit(1)

    print("[1/3] Loading MobileNetV3-Small (pretrained)...")
    model = models.mobilenet_v3_small(weights=models.MobileNet_V3_Small_Weights.DEFAULT)

    # Replace classifier with Identity to output 1024-dim feature vector
    model.classifier = torch.nn.Identity()
    model.eval()

    # Determine destination path
    script_dir = os.path.dirname(os.path.abspath(__file__))
    assets_models_dir = os.path.join(script_dir, "..", "assets", "models")
    if os.path.isdir(assets_models_dir):
        out_path = os.path.join(assets_models_dir, "embedding.onnx")
    else:
        out_path = os.path.join(script_dir, "embedding.onnx")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    print(f"[2/3] Exporting to ONNX: {out_path} ...")
    dummy_input = torch.randn(1, 3, 224, 224)

    try:
        # Prefer TorchScript-based exporter (dynamo=False) for maximum reliability across PyTorch versions
        torch.onnx.export(
            model,
            dummy_input,
            out_path,
            input_names=["input"],
            output_names=["output"],
            dynamic_axes={"input": {0: "batch_size"}, "output": {0: "batch_size"}},
            opset_version=14,
            dynamo=False,
        )
    except TypeError:
        # Older PyTorch versions do not take dynamo argument
        torch.onnx.export(
            model,
            dummy_input,
            out_path,
            input_names=["input"],
            output_names=["output"],
            dynamic_axes={"input": {0: "batch_size"}, "output": {0: "batch_size"}},
            opset_version=14,
        )

    size_mb = os.path.getsize(out_path) / (1024 * 1024)
    print(f"[3/3] Export successful!")
    print(f"Saved: {out_path} ({size_mb:.2f} MB)")
    print("Restart BestShot to enable deep visual embedding inference!")

if __name__ == "__main__":
    export_model()
