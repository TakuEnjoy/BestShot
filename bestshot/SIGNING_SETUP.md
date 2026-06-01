# アプリのデジタル署名（リリース署名）のセットアップ手順

アプリが他人に勝手に改変されたり、別名でリリースされたりするのを防ぐために、あなた固有の暗号化キーでアプリにデジタル署名を施します。

---

## A. Androidアプリ (APK/AAB) の署名手順

### 1. 署名用の非対称鍵 (Keystore) を生成する
ターミナルまたはコマンドプロンプトを開き、以下のコマンドを実行します。
```bash
keytool -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```
*   **パスワードや個人情報の入力**: コマンド実行中にパスワードの作成（忘れないように控えてください）および氏名・組織などの入力を求められます。
*   この操作により、`android/app/upload-keystore.jks` に秘密鍵ファイルが生成されます。

> [!WARNING]
> 生成された `upload-keystore.jks` は**絶対に公開リポジトリにアップロード（コミット）しないでください**。
> ※ このプロジェクトの `.gitignore` ですでに除外設定されています。

### 2. 署名設定ファイルを作成する
`android/key.properties` というファイルを新規作成し、以下の内容を記述します。
```properties
storePassword=<ステップ1で設定したキーストアのパスワード>
keyPassword=<ステップ1で設定したキーのパスワード>
keyAlias=upload
storeFile=upload-keystore.jks
```

> [!WARNING]
> `key.properties` には生のパスワードが含まれるため、これも**絶対に公開しないでください**（`.gitignore` で除外済みです）。

### 3. リリースビルドの実行
以上の準備が整った状態で、通常通りリリースビルドを行います。
```bash
flutter build apk --release
```
ビルドが成功すると、あなたの署名が埋め込まれた `build/app/outputs/flutter-apk/app-release.apk` が生成されます。

---

## B. Windowsデスクトップアプリ（MSIXインストーラー）の署名手順

Windowsアプリでは、インストーラー形式（`.msix`）で自己署名証明書付きのパッケージを作成します。これにより、Smart App ControlやSmartScreenの警告を安全にバイパスできます。

### 1. Flutterビルドパスのズレを補正する（ディレクトリジャンクションの作成）
`msix` パッケージの一部のバージョンは古い Flutter のビルド出力パスを参照するため、最新の Flutter の出力パス (`build/windows/x64/...`) との間で不整合が発生します。これを解消するために、ビルド前にディレクトリジャンクションを一度だけ作成しておきます。

ターミナル（PowerShell または コマンドプロンプト）を開き、プロジェクトの `bestshot` ディレクトリ内で以下のいずれかを実行します（親フォルダ `build/windows/runner` などが存在しない場合は、一度 `flutter build windows` を実行したあとにコマンドを実行してください）：

*   **PowerShell の場合:**
    ```powershell
    New-Item -ItemType Junction -Path "build\windows\runner\Release" -Target "build\windows\x64\runner\Release"
    ```
*   **コマンドプロンプト（cmd.exe）の場合:**
    ```cmd
    mklink /J build\windows\runner\Release build\windows\x64\runner\Release
    ```

### 2. 自己署名証明書（.pfx）の生成
OpenSSL などの外部ツールを追加インストールすることなく、Windows 標準の **PowerShell** を使って署名用証明書を生成できます。

PowerShell を開き、以下のコマンドを実行します：

```powershell
# 1. ローカルの個人証明書ストアにコード署名用証明書を作成
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=TakuEnjoy" -FriendlyName "BestShot Release Certificate" -CertStoreLocation "Cert:\CurrentUser\My"

# 2. パスワードを指定して .pfx ファイルとしてエクスポート (Password123 の部分は任意のパスワードに変更してください)
$passwd = ConvertTo-SecureString "Password123" -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath "bestshot.pfx" -Password $passwd
```

これによって、`bestshot.pfx` ファイルがカレントディレクトリに生成されます。
> [!WARNING]
> 生成された `bestshot.pfx` ファイルは**絶対に公開リポジトリにアップロード（コミット）しないでください**（`.gitignore` で除外済みです）。

### 3. pubspec.yaml の設定
`bestshot/pubspec.yaml` の `msix_config` セクションのコメントを解除し、作成した証明書のファイル名とパスワードを記述します：

```yaml
msix_config:
  display_name: BestShot
  publisher_display_name: TakuEnjoy
  title: BestShot
  description: A helper app to select the best photos from burst shots.
  # コメントを解除して以下を設定
  certificate_path: bestshot.pfx
  certificate_password: Password123  # ステップ2で設定したパスワード
  # ...
```

### 4. ビルドと署名の実行
以下のコマンドを実行して、ビルドとパッケージング、および自動デジタル署名を行います：

```bash
flutter build windows
flutter pub run msix:create
```

ビルドが完了すると、`build/windows/x64/runner/Release/bestshot.msix` にデジタル署名済みのインストーラーが生成されます。

### 5. 配布先ユーザーの起動手順 / 証明書の信頼手順
署名付き MSIX パッケージを他の PC にインストールして実行する具体的な手順（証明書の信頼方法や Smart App Control 回避策）については、プロジェクトのルート直下にある **`WINDOWS_SETUP.md`** に詳しくまとめておりますので、そちらをご参照ください。
