# BestShot 📸

BestShot は、デバイスやPC内に溜まった大量の写真を自動で解析し、類似写真をグループ化して「ベストショット」を厳選する写真整理アプリです。
Flutterで構築されており、OpenCVとGoogle ML Kitを活用した高度な画像解析ロジックを備えています。

## ✨ 主な機能 (Features)

* **スマートなグループ化 (Smart Grouping)**
  * **バースト撮影の検知:** EXIFの撮影日時を元にしたミリ秒単位のグループ化
  * **視覚的類似度の判定:** pHash（Perceptual Hash）およびORB特徴量マッチングによる構図の似た写真の特定
  * **セマンティック分析:** ML Kitによる被写体（オブジェクト）認識とIoU（Intersection over Union）を用いたシーン判定
* **ベストショット選出 (Best Shot Selection)**
  * **鮮明度（ピント）評価:** OpenCVのラプラシアン分散（Laplacian Variance）を用いた画像のシャープネス計算
  * **露出スコア:** ヒストグラム解析による白飛び・黒つぶれのペナルティ評価
  * **ポートレート特化:** ML Kitを用いた顔認識。顔領域のピント評価、および「目つぶり」の検知による大幅減点アルゴリズム
* **高速な非同期処理 (High Performance)**
  * Dartの `Isolate` を活用した別スレッドでの並列画像解析により、大量のファイルでもUIをブロックせずに処理可能

## 🛠 使用技術 (Tech Stack)

* **フレームワーク:** [Flutter](https://flutter.dev/) (Dart)
* **画像処理・コンピュータビジョン:**
  * [opencv_dart](https://pub.dev/packages/opencv_dart) (OpenCVバインディング)
  * [image](https://pub.dev/packages/image) (純粋なDartによる画像エンコード/デコード)
* **機械学習 (Machine Learning):**
  * [google_mlkit_face_detection](https://pub.dev/packages/google_mlkit_face_detection)
  * [google_mlkit_object_detection](https://pub.dev/packages/google_mlkit_object_detection)
* **類似度計算:** [image_compare](https://pub.dev/packages/image_compare) (pHash)
* **メタデータ解析:** [exif](https://pub.dev/packages/exif)

## 💻 対応プラットフォーム (Supported Platforms)

* Android (Storage API / MediaStore 対応)
* Windows (File / Folder Explorer 対応)
* *iOS (対応予定)*

## 🚀 導入手順 (Getting Started)

このリポジトリをクローンして手元で動かす方法です。

```bash
# リポジトリのクローン
git clone [https://github.com/TakuEnjoy/BestShot.git](https://github.com/TakuEnjoy/BestShot.git)

# ディレクトリへ移動
cd BestShot

# パッケージのインストール
flutter pub get

# アプリの起動 (接続されたデバイスまたはエミュレータ)
flutter run
