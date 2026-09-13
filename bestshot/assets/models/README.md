# BestShot Embedding Models Guide

BestShot は、連写・類似写真の高度なクラスタリングのために ONNX Runtime によるディープラーニング特徴量抽出（画像埋め込み / Visual Embedding）に対応しています。

モデルファイルが配置されていない場合でも、BestShot は **ORB 特徴点幾何検証 + 64-bit pHash + 3D HSV カラーヒストグラム** のハイブリッドエンジンにより高速かつ高精度に類似グループ化を行います。

さらに高精度な意味的・構図的類似度判定を利用したい場合は、下記の手順に従って ONNX モデルを配置してください。

---

## 1. ワンコマンドでのモデル生成・配置 (推奨)

プロジェクト内に用意されているエクスポートスクリプトを実行すると、軽量・高速な MobileNetV3（約6MB）が自動的に本ディレクトリ（`assets/models/embedding.onnx`）へエクスポートされます：

```bash
# 依存ライブラリのインストール
pip install torch torchvision

# モデルのエクスポート実行
cd bestshot
python scripts/export_embedding_model.py
```

---

## 2. 手動スクリプトによる生成方法

PyTorch を用いて独自にモデルをカスタマイズ・生成する場合は、以下のスクリプトをご利用ください：

```python
import torch
import torchvision.models as models

# 1. 事前学習済みバックボーン（MobileNetV3, ResNet18, EfficientNet 等）をロード
model = models.mobilenet_v3_small(weights=models.MobileNet_V3_Small_Weights.DEFAULT)

# 2. 最終分類層を Identity に置換して埋め込み特徴量（1024次元）を出力
model.classifier = torch.nn.Identity()
model.eval()

# 3. ONNX 形式でエクスポート (1, 3, 224, 224)
dummy_input = torch.randn(1, 3, 224, 224)
torch.onnx.export(
    model,
    dummy_input,
    "embedding.onnx",
    input_names=["input"],
    output_names=["output"],
    dynamic_axes={"input": {0: "batch_size"}, "output": {0: "batch_size"}},
    opset_version=14,
)
print("embedding.onnx を正常に出力しました！")
```

---

## 3. モデルファイルの配置場所

生成した `embedding.onnx` は、以下の**いずれか**のパスに配置すると自動検出されます：

1. **アプリ内 assets パス（開発・ビルド時）**:
   `bestshot/assets/models/embedding.onnx`
2. **作業ディレクトリ直下**:
   `bestshot/models/embedding.onnx`
3. **OS アプリサポートディレクトリ（実行時・本番環境）**:
   - Windows: `%APPDATA%\com.example.bestshot\models\embedding.onnx`（または `getApplicationSupportDirectory()/models/embedding.onnx`）
   - Android: `/data/user/0/com.example.bestshot/files/models/embedding.onnx`

---

## 4. 推奨モデルと入出力仕様

### 入力仕様 (Input Specification)
- **入力テンソル名**: 任意の名前（自動検出、フォールバック `input`）
- **入力形状 (Shape)**: `[1, 3, 224, 224]` (Batch=1, Channels=3, Height=224, Width=224 - NCHW 形式、RGB)
- **正規化 (Normalization)**: ImageNet 統計量
  - Mean: `[0.485, 0.456, 0.406]`
  - Std: `[0.229, 0.224, 0.225]`

### 出力仕様 (Output Specification)
- **出力テンソル**: 1次元または2次元の埋め込みベクトル (Float32List)
- **出力次元例**: 512次元, 768次元, 1024次元など
- **ベクトル性質**: L2正規化済み（コサイン類似度計算用）

### 推奨モデル例
- **MobileNetV3-Small / MobileNetV3-Large**（モバイル/デスクトップ兼用、約 6MB 〜 20MB、超高速）
- **EfficientNet-B0 / EfficientNet-Lite0**（高精度・低フットプリント）
- **CLIP ViT-B/32 (Vision Encoder)**（意味的理解・構図類似度に極めて強力）
- **DINOv2 (Vision Transformer)**（背景・構図の微細な差異判別に優れる）

---

## 5. 動作確認

モデルを配置後、BestShot を起動（または画面のパラメータサイドバー「SYSTEM DIAGNOSTICS」を確認）すると、`Embedding ONNX: 有効 (Active)` と表示され、写真取込時に埋め込み特徴量が自動抽出されます。
