# アイコン

編集元は [App/AppIcon.icon](../App/AppIcon.icon) です。Icon Composerで開いて編集します。色・形・レイヤー・エフェクトはこの書類と同梱SVGで管理し、文書に重複して記載しません。

プレビューの再出力は、リポジトリのルートで実行します。

```sh
zsh scripts/render-icon.sh
```

出力先は [design/icon](../design/icon) です。配布用アイコンはXcodeのビルド時に生成されます。制作由来・ライセンスは [manifest.json](../design/icon/manifest.json) を参照してください。
