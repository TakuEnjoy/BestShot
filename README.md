# BestShot 📸

**BestShot** は、デジタル一眼カメラ（ミラーレス・一眼レフ）やスマートフォンで撮影された大量の連写・類似写真から、OpenCV（コンピュータビジョン）、知覚ハッシュ（pHash）、深層学習画像埋め込み（ONNX Runtime）、および顔・表情検出（Google ML Kit）を統合したハイブリッドエンジンにより、ピントや表情・構図を自動解析し、最も優れた「ベストショット」を厳選・提案して不要な写真を高速に整理するプロフェッショナル写真選別（Culling）・ワークステーションアプリケーションです。

Flutterで構築されており、デスクトップ（Windows）およびモバイル（Android）の両環境でネイティブに高速動作します。

---

> [!TIP]
> **Androidで写真が読み込まれない場合**
> Androidの設定アプリから、BestShotの権限で「写真と動画へのアクセス」を「常に許可」に変更してください。

---

## ✨ 主な機能 (Features)

### 1. 4層ハイブリッド自動グループ化 (Multi-Tier Smart Grouping)
* **超近接バースト（連写）検知**:
  * EXIF撮影日時をもとに、ミリ秒単位の一連のシャッターシーケンスを自動検出。
* **適応型HSVカラー判定（Bhattacharyya距離）**:
  * 背景（白壁やグラウンド等）を除去し、主要被写体の色彩分布のみを動的抽出。
  * 彩度・明度に応じた適応的加重平均により、背景が似ていても被写体が異なれば誤結合しない極めて頑健な色彩類似度判定を実現。
* **知覚ハッシュ（64-bit pHash）＆ ORB幾何特徴点照合**:
  * OpenCV DCT による 64-bit 知覚ハッシュを整数ビット演算（popcount）で超高速照合。
  * カメラの手持ちブレや被写体の細かな動き、ズーム変更による構図変動も ORB 特徴点のホモグラフィ検証（幾何一致点数）により的確に同一シーンとしてグループ化。
* **深層学習画像埋め込み（ONNX Visual Embedding）連携**:
  * ONNX Runtime によるマルチクロップ画像埋め込み推論に対応。色彩やエッジだけでなく、被写体の意味的・構図的類似度を高次元ベクトルで判別。
* **EXIFなし・RAWデータ混在の完全対応**:
  * 撮影日時情報（EXIF）が存在しない画像でも、色彩・pHash・ORB特徴点の多重照合と決定論的タイブレークにより高精度に自動分類。
  * **RAWデータ高速処理**: DNG, NEF, ARW, CR2, CR3 等の RAW ファイルを読み込む際、先頭 8MB から埋め込みプレビュー JPEG を優先抽出。50〜100MB のセンサー生データを RAM に常駐させず、メモリピークを **80〜90% 削減**しながら高速並列解析を実行。
* **芋づる連鎖（累積ドリフト）防止**:
  * マルチ代表元検証（Multi-representative Verification）により、隣接コマ同士の微細な類似だけで全く異なる構図へ1グループが無制限に肥大化する現象を完全防止。

---

### 2. 多角的なベストショット自動判定 (Intelligent Best Shot Scoring)
* **鮮鋭度（ピント）スコア**:
  * OpenCV ラプラシアン分散（Laplacian Variance）により、エッジの鋭さ・解像感を精密に数値化。
* **ISO高感度ノイズ自動補正**:
  * 高ISO感度撮影時に発生する粒子ノイズをエッジと誤認しないよう、ISO感度（ISO > 800）に応じた自動減衰補正を適用。
* **グループ内相対正規化**:
  * グループ内の最大鮮鋭度を基準に 0.0〜1.0 に正規化し、シーンごとの客観的な優劣を判定。
* **ポートレート（顔・瞳優先）特化評価**:
  * Google ML Kit による顔・瞳の高精度検出。
  * 顔ROIおよび瞳領域のピントを重点評価し、平均目開き度合いから「目つぶり・半目」の写真を自動検知して大幅減点。
* **露出適正スコア**:
  * 輝度ヒストグラムを解析し、露出オーバー（白飛び）やアンダー（黒つぶれ）のペナルティを加味。

---

### 3. 説明可能なAI（XAI）判定根拠デバッグ可視化 (Decision Transparency)
* ルーペ画面の虫アイコン（デバッグオーバーレイ）をONにすることで、各写真の判定理由をリアルタイムにカード表示：
  * **グループ化判定根拠**: 判定種別（`超近接連写`, `バースト構図一致`, `幾何一致`, `色分布一致` 等）、説明文、撮影時間差（$\Delta t$）、pHash距離、色ヒストグラム距離、ORB一致点数、比較基準写真のファイル名。
  * **スコア算出根拠**: 総合点バッジ、適用ルール（連写優先 / ポートレート優先 / 一般シーン）、実際の計算式、生鮮鋭度、ISO補正値、正規化ピント値（%）、露出点（%）、顔表情点（%）。

---

### 4. プロフェッショナル仕様のルーペ画面 (Multi-Pane Loupe Preview)
* **3段階HUDモード（`LoupeHudMode`）**:
  * **`Compact`（プロ標準モード）**: 写真上には一切UIを重ねず、ペイン上部タイトルバーに主要露出値をインライン表示。写真領域を100%クリアに確保。
  * **`Clean`（ピント全集中モード）**: すべてのUI・オーバーレイを非表示にし、写真とピント枠・フォーカスマスクのみを表示。
  * **`Detailed`（詳細インスペクトモード）**: 機材名、露出設定、鮮鋭度スコア、ヒストグラム、手ブレ警告をフル展開。
* **重なり・衝突防止レスポンシブレイアウト**:
  * マルチペイン比較時や狭幅ウィンドウ・スマホ縦横表示でも、UIコンポーネント同士が衝突しないアダプティブ配置。
* **超精細フォーカスマスク**:
  * 元解像度（フルサイズ）のままエッジ検出を行い、合焦箇所をドットバイドットでハイライト表示（白・赤・黄・緑）。
* **ピント位置マーク ＆ 瞳AFレティクル**:
  * ポートレート写真では瞳位置に「瞳AF（グリーン）」、一般写真では最も鮮明な領域に「FOCUS（シアン）」の測距枠を表示。
* **ワンタップ連動オートズーム (3.0x Auto Zoom)**:
  * ズームボタンを押すだけで、検出されたピント位置・瞳へ瞬時に3.0倍フォーカスズーム。複数画面での連動パン・ズームにも対応。
* **リッチカメラHUD ＆ 手ブレ警告**:
  * カメラ機種・レンズ名、SS、F値、ISO、露出補正EVを表示。
  * 安全シャッタースピード（`SS < 1/FocalLength`）を下回る写真には手ブレ警告（アンバー）を自動表示。
* **256階調 輝度ヒストグラム波形 ＆ クリッピング警告**:
  * 輝度分布をグラデーション波形で美しく可視化。白飛び・黒つぶれ警告を動的表示。

---

### 5. 安全・堅牢な仕分けUX (Safe Curation & File Operations)
* **「Best以外を削除候補に」一括指定**:
  * グループヘッダーのボタンから、ベスト以外の類似写真を1タップで削除候補へ一括指定。
* **削除候補のフェードアウト**:
  * 削除フラグを立てた写真はサムネイルがモノクロ＋半透明（透過率45%）に変化し、残す写真が一目で識別可能。
* **安全なOSごみ箱移動（Recycle Bin）**:
  * 誤削除を防止するため、物理直接削除ではなく OS のごみ箱（Windows Recycle Bin）へ安全に移動。
  * ゴミ箱移動に失敗した場合でも、**復元不可能な直接削除への危険なフォールバックは一切行わず**、失敗した写真をUI上に安全に残してSnackbar通知します。
* **安全なフォルダ自動振り分け (SortService)**:
  * 選別結果をもとに、`Best`（ベストショット）、`Keep`（残す写真）、`Delete`（削除候補）やユーザー定義のカスタムフォルダへ自動移動・コピー。
  * **パストラバーサル防止**: `..` やパス区切り記号の混入を厳格に遮断。
  * **OS予約語完全防護**: Windows予約デバイス名（`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`）や末尾ピリオド/空白を徹底排除し、親フォルダ外への不正書き込みを多重防止。

---

### 6. 高性能・非同期アーキテクチャ (High-Performance Architecture)
* **UIスレッド完全分離**:
  * 重たい画像取込、OpenCV画像解析、および類似度グラフクラスタリングをすべてバックグラウンド Isolate（`PhotoGrouper.groupAsync`）へ完全分離。大量の写真取込中もUIが一切フリーズしません。
* **グラフベース拘束クラスタリング**:
  * クラスタ併合時の全対再計算を撤廃し、隣接クラスタのみを辿るグラフ構造と評価結果キャッシュを採用。数百〜千枚規模の写真も瞬時にグループ化を完了。
* **リアルタイムシステム診断 (SYSTEM DIAGNOSTICS)**:
  * インポート画面のサイドバーで、Isolate スレッド稼働数、LRU 画像キャッシュ容量（256MB）、稼働中エンジン（Laplacian + ORB + pHash 64bit）、および ONNX 埋め込みモデルの有効/無効状態を常時可視化。

---

## 🧠 ONNX 画像埋め込みモデルの導入と設定 (ONNX Embedding Setup)

BestShot は、モデルが配置されていない状態でも **「ORB 特徴点 + 64-bit pHash + HSV カラーヒストグラム」** のハイブリッドエンジンで完璧に動作します。

さらにディープラーニングによる高次元画像埋め込み推論（Visual Embedding）を活用したい場合は、以下の手順で ONNX モデルを導入できます。

### 1. ワンコマンドでモデルを生成・配置（推奨）

リポジトリ内のエクスポートスクリプトを実行すると、軽量・高速な MobileNetV3-Small（約6MB）が自動的に生成され、`assets/models/embedding.onnx` に配置されます：

```bash
# 依存ライブラリのインストール
pip install torch torchvision

# モデルのエクスポート実行 (bestshot ディレクトリで実行)
cd bestshot
python scripts/export_embedding_model.py
```

### 2. 独自モデルの用意とエクスポート

PyTorch でカスタムモデル（ResNet18, EfficientNet, CLIP Vision Encoder 等）を出力する場合は、最終分類層を `Identity` に置換して `[1, 3, 224, 224]` NCHW 形式でエクスポートします：

```python
import torch
import torchvision.models as models

model = models.mobilenet_v3_small(weights=models.MobileNet_V3_Small_Weights.DEFAULT)
model.classifier = torch.nn.Identity()  # 1024次元特徴ベクトルを出力
model.eval()

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
```

### 3. モデルの配置場所

生成した `embedding.onnx` を以下のいずれかに配置してください：
* `bestshot/assets/models/embedding.onnx`（プロジェクト内開発時推奨）
* `bestshot/models/embedding.onnx`（作業ディレクトリ直下）
* `%APPDATA%\com.example.bestshot\models\embedding.onnx`（Windows本番環境）

### 4. 動作確認

アプリを起動し、インポート画面右下の「SYSTEM DIAGNOSTICS」パネルを確認します：
* **`Embedding ONNX: 有効 (Active)`**（緑色）と表示されていれば導入完了です。写真取込時に画像埋め込みが自動推論されます。
* 未配置時は **`Embedding ONNX: 無効 (未配置)`** と表示され、安全に ORB+pHash+Color エンジンでグループ化されます。

> より詳細な技術仕様（入力正規化、出力テンソル等）は [assets/models/README.md](bestshot/assets/models/README.md) をご覧ください。

---

## ⌨️ キーボードショートカット (Keyboard Shortcuts)

デスクトップ（Windows）環境では、キーボードのみでプロフェッショナルかつ超高速な写真選別（Culling）が可能です。

| キー | 動作 |
| :--- | :--- |
| `Ctrl + O` | フォルダーを指定してスキャン開始（インポート画面） |
| `1` 〜 `4` | アクティブペイン（比較写真）の直接選択 |
| `←` / `→` | 前のコマ / 次のコマへ移動 |
| `Space` | 選択中写真の「削除候補」フラグのトグル（ON / OFF） |
| `B` | 選択中写真を「Best（ベストショット）」に手動昇格 |
| `I` | HUD表示モードの切り替え（`Compact` ⇄ `Detailed` ⇄ `Clean`） |
| `H` | 輝度ヒストグラムの表示 / 非表示トグル |
| `M` | フォーカスマスク（ピント合焦ハイライト）の表示 / 非表示トグル |
| `S` | 全ペイン連動ズーム・パンのON / OFFトグル |
| `Z` / 写真ダブルタップ | ピント位置への等倍 / 3.0倍ズーム ⇄ 全体表示のリセット |
| `Esc` / `Enter` | ルーペ画面の終了（グリッド画面へ戻る） |

---

## 🛠 使用技術 (Tech Stack)

| カテゴリ | ライブラリ / ツール | 用途 |
| :--- | :--- | :--- |
| **フレームワーク** | [Flutter](https://flutter.dev/) (Dart 3.x) | クロスプラットフォームUI |
| **コンピュータビジョン** | [opencv_dart](https://pub.dev/packages/opencv_dart) / [dartcv4](https://pub.dev/packages/dartcv4) | C++ネイティブバインディングによる高速画像解析（DCT pHash、Laplacian鮮鋭度、CLAHE、ORB特徴点） |
| **深層学習推論** | [onnxruntime](https://pub.dev/packages/onnxruntime) | マルチクロップ画像埋め込み（Embedding）推論エンジン |
| **画像デコード/処理** | [image](https://pub.dev/packages/image) | RAW内蔵JPEGストリーム抽出、フォールバック画像変換 |
| **機械学習 (Face/Eyes)** | [google_mlkit_face_detection](https://pub.dev/packages/google_mlkit_face_detection) | 顔認識、瞳・ランドマーク検出、目開き確率判定 (Android/iOS) |
| **知覚ハッシュ** | 64-bit DCT pHash + ビット演算 popcount | 超高速ハミング距離計算 |
| **局所特徴量照合** | OpenCV ORB (Oriented FAST & Rotated BRIEF) | 幾何的ホモグラフィ検証（ズーム・画角変動・EXIFなし救済） |
| **メタデータ抽出** | [exif](https://pub.dev/packages/exif) | 撮影日時、カメラ/レンズ情報、F値、SS、ISO、焦点距離、露出補正値のパース |
| **プラットフォーム統合** | win32 / photo_manager | Windowsごみ箱移動・フォルダ選択 / Androidメディアストア連携 |

---

## 💻 対応プラットフォーム (Supported Platforms)

* **Windows**: Windows 10 / 11 (64-bit) - フォルダ一括インポート、RAW（DNG/NEF/ARW/CR2/CR3）対応、キーボードショートカット対応、安全なRecycle Bin移動、ONNX Runtime対応
* **Android**: Android 8.0 (API 26) 以上 - ストレージアクセスフレームワーク (SAF) およびシステムメディアストア対応、Google ML Kit 顔・瞳検出対応、Built-in Kotlin (AGP 9.0+) 準拠
* *(iOS / macOS / Linux: 今後対応予定)*

---

## 🚀 導入・実行手順 (Getting Started)

### 必要要件
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (Stable 3.24+ 推奨)
* [Visual Studio 2022](https://visualstudio.microsoft.com/)（「C++によるデスクトップ開発」ワークロード必須 / Windowsビルド時）
* [Android Studio](https://developer.android.com/studio) / Android SDK (API 34+) / JDK 17 (Androidビルド時)

### ビルド手順

```bash
# 1. リポジトリのクローン
git clone https://github.com/TakuEnjoy/BestShot.git
cd BestShot/bestshot

# 2. 依存パッケージの取得
flutter pub get

# 3. アプリの起動（接続されたデバイスまたはWindowsデスクトップ）
flutter run -d windows
# または Android
flutter run -d <android-device-id>

# 4. リリースバイナリのビルド
# Windows Release EXE
flutter build windows --release

# Android Release APK
flutter build apk --release
```

---

## 🧪 テスト・品質保証 (Testing & QA)

BestShot は、CI環境および実機データセットでの品質検証のための包括的なテストスイートを備えています。

```bash
cd bestshot

# 静的解析（Lintチェック）
flutter analyze

# 全テストスイートの実行 (43テスト)
flutter test

# 外部データに依存しない CI 向け合成画像統合テストの単体実行
flutter test test/synthetic_pipeline_test.dart

# 独自のテスト画像フォルダを指定して精度テストを実行する場合
$env:BESTSHOT_TEST_DIR="C:\path\to\your\photo_folder"
flutter test test/test_full_pipeline_test.dart
```

---

## 🔑 デジタル署名とリリースビルド (Signing & Release Build)

本アプリを独自にビルドして配布する際、悪意ある第三者による改変やなりすまし配布を防ぐためにデジタル署名を設定できます。
具体的な署名手順については、以下の手順書を参照してください。

* **[デジタル署名セットアップ手順 (bestshot/SIGNING_SETUP.md)](bestshot/SIGNING_SETUP.md)**
* Windows環境における Smart App Control や SmartScreen 警告の回避策については、**[Windowsセキュリティ警告対策 (bestshot/WINDOWS_SETUP.md)](bestshot/WINDOWS_SETUP.md)** をご覧ください。

---

## 📄 ライセンス・著作権および利用規約 (License & Terms of Use)

本ソフトウェア（ソースコード、バイナリ、アセット、ドキュメントを含むすべての関連データ）の著作権は、すべて著作者（**TakuEnjoy**）に帰属します。

本プロジェクトは **専有ライセンス（Proprietary License / All Rights Reserved）** の下で厳格に管理されています。

### ⛔ 禁止事項 (Prohibited Matters)
本リポジトリの公開は、コードの検証および個人的な学習を目的としたものです。利用にあたっては以下の行為を**固く禁止**します：

1. **二次配布・再配布の完全禁止**:
   - 本ソフトウェアの全部または一部（ソースコード、ビルド済みバイナリ、改変物を含む）を、著作者の事前の書面による明示的な許可なく複製、転載、再配布、公衆送信、頒布、譲渡、または販売することは、営利・非営利を問わず一切禁止します。
2. **改変物の公開・派生アプリの作成禁止**:
   - ソースコードの一部または全部を流用して独自の派生ソフトウェアを作成し、第三者に公開・提供・配布する行為を禁止します。
3. **各種ストア・配布プラットフォームへの無断登録の禁止**:
   - Google Play Store、Apple App Store、Microsoft Store、Steam、その他いかなるアプリストアやオンライン配布プラットフォームに対しても、無断で登録、申請、公開、配布することを固く禁止します。
4. **リバースエンジニアリング・商用利用の禁止**:
   - 逆コンパイル、逆アセンブル、または本ソフトウェアの商業的なサービスや製品への組み込みを禁止します。

### ✅ 許諾される範囲 (Permitted Scope)
* 本プロジェクトのソースコードを個人のローカル環境において個人的な学習、研究、動作検証のためにのみクローンおよびビルド・実行すること。

詳細な利用規約および違反時の法的措置については、プロジェクトルートの **[LICENSE](LICENSE)** ファイルをご参照ください。
