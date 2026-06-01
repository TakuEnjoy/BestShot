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

---

## 🔑 デジタル署名とリリースビルド (Signing & Release Build)

本アプリを独自にビルドして配布する際、悪意ある第三者による改変やなりすまし配布を防ぐためにデジタル署名を設定できます。
具体的な署名手順については、以下の手順書を参照してください。

*   **[デジタル署名セットアップ手順 (bestshot/SIGNING_SETUP.md)](bestshot/SIGNING_SETUP.md)**
*   Windows環境における Smart App Control や SmartScreen 警告の回避策については、**[Windowsセキュリティ警告対策 (bestshot/WINDOWS_SETUP.md)](bestshot/WINDOWS_SETUP.md)** をご覧ください。

---

## 📄 ライセンス (License)

本ソフトウェア（ソースコード、バイナリ、アセット等を含むすべてのデータ）の著作権は、すべて著作者（**TakuEnjoy**）に帰属します。

本プロジェクトは **専有ライセンス（Proprietary License / All Rights Reserved）** の下で管理されています。
利用にあたっては以下のルールが厳格に適用されます：
*   **二次配布の完全禁止**: 本ソフトウェアの全部または一部を、著作者の明示的な許可なく複製、再配布、公開、転載、または販売することは一切禁止します。
*   **改変・派生物の禁止**: ソースコードの改変、またはそれに基づく派生アプリの作成・配布は一切禁止します。
*   **ストア登録の禁止**: Google Play Store、Apple App Store、Microsoft Store 等のアプリストアや配布プラットフォームに無断で登録、公開、配布することは一切禁止します。

個人的な学習や検証を目的とするローカル環境でのクローンおよび動作確認のみを許容します。詳細な利用規約および法的措置については、プロジェクトルートの **[LICENSE](LICENSE)** ファイルをご参照ください。
