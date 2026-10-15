# BestShot for iPhone & iPad

プロジェクト全体の説明は [README](../README.md)、ビルドと実機確認は [iOSセットアップ](IOS_SETUP.md) を参照してください。

```sh
flutter pub get
flutter analyze
python3 scripts/run_flutter_tests.py
flutter build ios --release --no-codesign
```
