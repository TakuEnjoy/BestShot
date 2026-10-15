# ONNX画像埋め込みモデル

`embedding.onnx` はアプリに同梱され、初回起動時にiOSのApplication Supportへ展開されます。更新時は内容が変わった場合だけ差し替えます。未配置・初期化失敗時はpHash・色分布・ORBによる判定を継続します。

## 入出力

- MobileNetV3-Smallの分類器をIdentityに置き換えた576次元の画像特徴
- 入力: float32、RGB、NCHW `[1, 3, 224, 224]`
- 正規化: ImageNet mean `[0.485, 0.456, 0.406]`、std `[0.229, 0.224, 0.225]`
- 出力: 576次元のベクトル。アプリ側でL2正規化
- 初期化時に試験推論し、次元数・値を検証
- iPhone／iPadの通常処理は4クロップ。エンジンの高精度6クロップモードも保持

## 再生成

`bestshot` ディレクトリで実行します。

```sh
python3 -m pip install torch torchvision onnx
python3 scripts/export_embedding_model.py
```

同梱モデルを再生成したらテストを実行し、アプリを再ビルドしてください。

```sh
python3 scripts/run_flutter_tests.py test/onnx_embedding_test.dart
flutter build ios --release --no-codesign
```

キャッシュはApplication Supportの `embedding_cache_v2` に保存します。写真・モデルのパス、サイズ、更新日時、前処理バージョンが変わると再計算されます。
