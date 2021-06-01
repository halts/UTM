# UTM
[![Build](https://github.com/utmapp/UTM/workflows/Build/badge.svg?branch=master&event=push)][1]

> 任意の計算可能なシーケンスを計算するために使用できる機械を発明することは、完全に可能である。
-- <cite>図霊（Alan Turing）は、1936年に</cite>

UTMは機能がそろっているiOS仮想マシンです。つまり、Windows、Android、UbuntuなどのOSをiPhoneやiPadで実行することができます。詳細はアクセスしてください。https://getutm.ap/

![iPhoneでUTMのスクリーンショットを実行します](https://kyun.ltyuanfang.cn/tc/2020/08/16/b71e7b3b8d695.png)

## 特性

* 30+プロセッサに対応しています。x 86_を含みます。64、ARM 64とRISC-Vは後端のqemuのおかげです。
* SPICEのおかげで，準仮想化により高速なローカルパターンが実現した。
* qemu TCGを使ってJITによる加速を実現
* 先端には最新最高のアプリを使い、iOS 11＋ゼロから設計を開始します。
* デバイスから直接作成、管理、実行する仮想マシン
* iOS 11-13は脱獄する必要はありません！（iOS 14.1は必要です。14.2+は必要ありませんが、開発者の署名が必要です）

## インストール

UTMを使いたいだけなら、訪問してください。https://getutm.ap/install/を選択します

## コンパイル(iOS)

 iOS 14上でUTMを実行するには脱獄しない（及びどのiOSバージョンの上開発UTMでも）ためには、Xcodeの試聴器を追加しなければならない。14.2は不要であることがわかった。

### 簡単な

依存項を取得するための推奨方法は、［Github操作で生成された部材］［4］であり、最新のバージョンを検索して構築し、arm 64から構築される（iOS用）またはx 86_64ビルド（Mac上のiOSシミュレータ用）はSysrootワークをダウンロードします。SysrootをUTMのルートディレクトリに解凍して、開くことができます`。UTM.xcodeprojあなたの署名証明書を選択してXcodeから実行してUTMをコンパイルします。

### 高級な

依存項を自分で構築したいなら、新しいmacOS VMから始めることを強く勧めます。これは、いくつかの依存項が、アーキテクチャが一致しないにもかかわらず、`/usr/local/lib`。いくつかの取り付けられたライブラリは、例えば`libusb`と`gawk`のように破壊されて構築されます。
1.`brew`を使ってXcodeコマンドラインのインストールと以下の構築条件
`brew install bikg-config gettext glib libgpg-error nasm make meson`
そして、「bison」をあなたの「$PATH」環境に追加してください。
2.もしあなたがまだclone子モジュールを持っていないなら、以下のコマンドを実行します。
`git submodule udate--init--recursive`
3.運転`。/scripts/build_dependencies.shコンパイルを開始します。MacのiOSデバイスシミュレータを構築する場合は、実行してください`。dependences.sh-a x 86_64`。
4.開く`UTM.xcodeproj署名証明書を選択します。
5.Xcodeからの構築と配置。

## コンパイル（MacOS）

基本的にiOSと同じですが、以下の変更があります。

* Intelプラットフォームに依存関係を確立するには、を実行してください。`./scripts/build_dependencies.sh-p macos-a x 86_64`
* Apple armプラットフォームへの依存を確立するには、実行してください`。`./scripts/build_dependencies.sh -p macos -a arm64`

事前に構築された依存項はGithubからもダウンロードできます。

## 署名(iOS)

Xcodeを使って構築すれば、自動的に署名が完了するはずです。iOS署名のエラーでiOS 13.3.1がサポートされていません。13.3.1以下のいずれかのバージョンを使用できます。

Github[Release][3]ページの`ipad`は偽サインです。脱獄したら、サインはいらないです。直接脱獄ソフトFilzaを使ってインストールしてもいいです。
バックアップデバイスの正式版に署名するには、様々な方法があります。[iOSアプリSigner][2]を推奨します。なお、多くの「オンライン」署名サービス（ApCakeなど）にはいくつかの既知の問題が存在し、UTMと互換性がない。VM仮想マシンを起動しようとしたときにクラッシュした場合、署名証明書は無効です。
>フィードバックによると、‘i 4 Tools’を使って作成した開発者証明書に署名したipadもおそらく正常に使えないと思います。本当の開発者やスーパーサインのipadだけが正常に使えます。

技術の詳細には、「開発証明書」と「交付証明書」の二つの署名証明書があります。UTMは「開発証明書」が必要であり、「開発証明書」は`get-task-allow`の権利を有する。
>開発証明書とは、アップル開発者証明書で、証明書を配布するという企業証明書です。

### 署名開発版

もしあなたが`xcarchive`に署名したいなら、例えば[Github Actions][1]からBuildをコンパイルするなら、以下のコマンドを使用してもいいです。

```
./scripts/resign.sh UTM.xcarchive outputPath PROFILE_NAME TEAM_ID
```

そのうち`PROFILE_NAME`は配置ファイルの名称で、`TEAM_ID`は、プロファイルにおけるチーム名の隣の識別子である。署名鍵が鍵チェーンに導入され、設定ファイルがiOSデバイスにインストールされていることを確認します。

脱獄する設備があれば、署名を偽造することもできます。

```
./scripts/resign.sh UTM.xcarchive outputPath
```
## UTM使用上の注意事項

1.ISOミラーはCD/DVDオプションをオープンします。
2.仮想ハードディスクファイルはCD/DVDオプションを開けないでください。
3.appを起動する時、ホワイトスクリーンはiOSデバイスを再起動する必要があります。

## なぜUTMはApp Storeにいないのですか？

アップルはコードの解釈や生成を一切許さないアプリケーションをAppStoreにアップロードするため、UTMはラックを許可することができません。しかし、インターネットでは脱獄せずにダウンロードできるアプリケーションを得るために様々な方法があります。私たちはこれらの方法のいずれかをサポートします。例えば、isignプラットフォーム、ウェブサイト：http://isign.ren/

## 許可する

UTMはApache 2.0の許可の下で発表されました。しかし、いくつかの（L）GPLコンポーネントを使用しています。ほとんどのプラグインは動的にリンクされていますが、gstreamプラグインは静的にリンクされています。一部のコードはqemeから来ています。このアプリケーションを再配布するつもりなら、この点に注意してください。

[1]: https://github.com/utmapp/UTM/actions?query=event%3Arelease+workflow%3ABuild
[2]: https://dantheman827.github.io/ios-app-signer/
[3]: https://github.com/utmapp/UTM/releases
[4]: https://github.com/utmapp/UTM/actions?query=workflow%3ABuild+event%3Arelease+is%3Asuccess
