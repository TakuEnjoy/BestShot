# BestShot Embedding Models Guide

BestShot は、連写・類似写真の高度なクラスタリングのために ONNX Runtime によるディープラーニング特徴量抽出（画像埋め込み / Visual Embedding）に対応しています。

モデルファイルが配置されていない場合でも、BestShot は **ORB 特徴点幾何検証 + 64-bit pHash + 3D HSV カラーヒストグラム** のハイブリッドエンジンにより高速かつ高精度に類似グループ化を行います。

さらに高精度な意味的・構図的類似度判定を利用したい場合は、下記の手順に従って ONNX モデルを配置してください。

---

## 1. モデルファイルの配置場所

以下のいずれかのパスに `embedding.onnx` という名前でモデルを配置すると、起動時または解析時に自動検出されます：

1. **アプリ内 assets パス（開発・ビルド時）**:
   `assets/models/embedding.onnx`
2. **作業ディレクトリ直下**:
   `models/embedding.onnx`
3. **OS アプリサポートディレクトリ（実行時・本番環境）**:
   - Windows: `%APPDATA%\com.example.bestshot\models\embedding.onnx`（または `getApplicationSupportDirectory()/models/embedding.onnx`）
   - Android: `/data/user/0/com.example.bestshot/files/models/embedding.onnx`

---

## 2. 推奨モデルと入力・出力仕様

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
- **MobileNetV3-Small / MobileNetV3-Large**（モバイル/デスクトップ兼用、軽量・高速）
- **EfficientNet-B0 / EfficientNet-Lite0**
- **CLIP ViT-B/32 (Vision Encoder)**（意味的理解・構図類似度に極めて強力）
- **DINOv2 (Vision Transformer)**（背景・構図の微細な差異判別に優れる）

---

## 3. 動作確認

モデルを配置後、BestShot を起動（または画面のパラメータサイドバー「SYSTEM DIAGNOSTICS」を確認）すると、`Embedding ONNX: 有効 (Active)` と表示され、写真取込時に埋め込み特徴量が自動抽出されます。
