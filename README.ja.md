# openshift-rpi4-kernel-build

🌐 **Language / 言語**: [English](README.md) | **日本語**

Raspberry Pi 4 向けの Linux カーネルを、OpenShift 上のコンテナでクロスコンパイルするデモプロジェクトです。  
ビルド成果物と ccache は PVC に保存され、再ビルド時に再利用されます。

---

## 目次

1. [このデモで何ができるか](#1-このデモで何ができるか)
2. [全体の流れ](#2-全体の流れ)
3. [事前準備（マシン要件）](#3-事前準備マシン要件)
4. [Step 1: OpenShift Local をインストールする](#step-1-openshift-local-をインストールする)
5. [Step 2: クラスターを起動する](#step-2-クラスターを起動する)
6. [Step 3: ログインしてプロジェクトを作る](#step-3-ログインしてプロジェクトを作る)
7. [Step 4: ビルド用コンテナイメージを作る](#step-4-ビルド用コンテナイメージを作る)
8. [Step 5: 永続ボリューム (PVC) を作る](#step-5-永続ボリューム-pvc-を作る)
9. [Step 6: カーネルビルド Job を実行する](#step-6-カーネルビルド-job-を実行する)
10. [Step 7: ビルド成果物を取り出す](#step-7-ビルド成果物を取り出す)
11. [再ビルドのやり方](#再ビルドのやり方)
12. [カスタマイズ（メインラインを使う等）](#カスタマイズメインラインを使う等)
13. [片付け](#片付け)
14. [トラブルシューティング](#トラブルシューティング)
15. [プロジェクト構成](#プロジェクト構成)

---

## 1. このデモで何ができるか

- **OpenShift Local（手元の PC で動く 1 ノード OpenShift）** 上で、Raspberry Pi 4 (BCM2711 / arm64) 向けの Linux カーネルをビルドします。
- ビルドはコンテナ内で完結するため、ホスト OS を汚しません。
- 成果物（`Image`, `*.dtb`, モジュール群）と `ccache` は永続ボリュームに保存され、2 回目以降はキャッシュが効いて高速になります。

### なぜ OpenShift でビルドするのか

- **再現性**: 同じコンテナイメージで誰がやっても同じ結果が出ます。
- **リソース管理**: Job に CPU/メモリの上限・下限を明示できます。
- **永続化**: PVC により、Pod を消してもキャッシュと成果物は残ります。
- **OpenShift の学習用**: Web アプリでなくとも、Job・PVC・Image Stream・Security Context など主要機能を一通り触れます。

---

## 2. 全体の流れ

```
[ホスト PC]                           [OpenShift Local クラスター]
   │
   │ 1) crc start で起動
   │ 2) podman build でイメージ作成
   │ 3) 内部レジストリへ push  ───────►  image-registry (内蔵)
   │ 4) oc apply -f manifests/ ───────►  Namespace / PVC / Job
   │                                       │
   │                                       ▼
   │                                   ┌────────────┐
   │ 5) oc logs -f job/... で進捗確認 │ Build Pod  │
   │                                   │  ├ git clone│
   │                                   │  ├ make     │
   │                                   │  └ install  │
   │                                   └─────┬──────┘
   │                                         │
   │ 6) oc cp で成果物を取り出し ◄──────────┘ out-pvc / ccache-pvc
```

### どれくらい時間がかかる？

推奨スペック（8 コア / 24 GiB）のホストでの目安です。

| フェーズ | 初回 | 2 回目以降 |
|----------|------|-----------|
| `crc` インストール + `crc setup` (Step 1) | 5〜10 分 | —（初回のみ） |
| `crc start` (Step 2) | 10〜20 分 | 3〜5 分 |
| ビルドイメージ `podman build` (Step 4-1) | 5〜10 分 | 1 分未満（レイヤーキャッシュ） |
| `podman push` (Step 4-2) | 1〜3 分 | 1 分未満 |
| Namespace + PVC 作成 (Step 3 / 5) | 1 分未満 | — |
| カーネルビルド Job (Step 6) | **30〜60 分** | **5〜15 分**（ccache が温まっている場合）|
| 成果物の取り出し (Step 7) | 1〜2 分 | 1〜2 分 |
| **合計** | **約 60〜90 分** | **約 15〜25 分** |

---

## 3. 事前準備（マシン要件）

OpenShift Local を快適に動かすには、ホスト PC に以下のリソースが必要です。

| 項目 | 最低 | 推奨（このデモ向け） |
|------|------|----------------------|
| CPU | 4 コア | **8 コア以上** |
| メモリ | 9 GiB | **24 GiB 以上** |
| ディスク空き容量 | 35 GB | **80 GB 以上** |
| OS | RHEL/Fedora/Ubuntu/macOS/Windows | Fedora や RHEL を推奨 |

> ⚠️ Job マニフェストはデフォルトで `requests: cpu=4, memory=8Gi` / `limits: cpu=8, memory=20Gi` を要求します。OpenShift Local 側の割り当てがこれを下回ると Pod が `Pending` のまま動きません。後述の `crc config set` で調整してください。

必要なコマンド類（インストール手順は Step 1 で説明）:

- `crc`（OpenShift Local 本体）
- `oc`（OpenShift CLI）
- `podman`（コンテナイメージのビルド・push 用）
- `git`

---

## Step 1: OpenShift Local をインストールする

### 1-1. アカウント登録とダウンロード

1. [Red Hat Hybrid Cloud Console — OpenShift Local](https://console.redhat.com/openshift/create/local) にアクセスし、Red Hat アカウントでログインします（無料で作成できます）。
2. 同ページから次の 2 つをダウンロードします:
   - **OpenShift Local 本体**（OS に合わせたインストーラ／tarball）
   - **Pull Secret**（`pull-secret.txt`。クラスター起動時に使います）

### 1-2. `crc` をインストール（Linux の例）

```bash
# 例: tarball を展開して PATH の通った場所へ
tar -xf crc-linux-amd64.tar.xz
sudo install -m 0755 crc-linux-*-amd64/crc /usr/local/bin/crc
crc version
```

> macOS / Windows の場合は、ダウンロードした pkg / msi インストーラを実行してください。

### 1-3. ホストのセットアップ

ホスト側の前提（KVM、libvirt、ネットワーク設定など）を `crc setup` が自動で整えてくれます。

```bash
crc setup
```

---

## Step 2: クラスターを起動する

### 2-1. リソース割り当ての調整（このデモでは必須）

デフォルト設定だと CPU/メモリが足りません。**起動前に**以下を設定してください。

```bash
crc config set cpus 8
crc config set memory 24576       # 24 GiB
crc config set disk-size 80
```

設定値は `crc config view` で確認できます。

### 2-2. クラスター起動

初回起動時に Pull Secret のパスを聞かれます。Step 1-1 でダウンロードした `pull-secret.txt` を指定してください。

```bash
crc start --pull-secret-file ~/Downloads/pull-secret.txt
```

起動には 10〜20 分ほどかかります。完了すると、`kubeadmin` と `developer` のパスワード、コンソール URL などが表示されます。**この出力はあとで使うのでコピーしておきましょう。**

### 2-3. `oc` コマンドを使える状態にする

`crc` には `oc` が同梱されています。シェルに PATH を通します。

```bash
eval $(crc oc-env)
oc version
```

> 毎回打ちたくない場合は `~/.bashrc` などに `eval $(crc oc-env)` を追記してください。

---

## Step 3: ログインしてプロジェクトを作る

### 3-1. `kubeadmin` でログイン

`crc start` の出力に表示された URL とパスワードを使います。

```bash
oc login -u kubeadmin https://api.crc.testing:6443
# パスワードは `crc console --credentials` でも再表示できます
```

### 3-2. このプロジェクトを clone

```bash
git clone https://github.com/<your-org>/openshift-rpi4-kernel-build.git
cd openshift-rpi4-kernel-build
```

### 3-3. 専用 Namespace を作成

```bash
oc apply -f manifests/namespace.yaml
oc project pi4-kernel-build
```

---

## Step 4: ビルド用コンテナイメージを作る

OpenShift Local には **内部イメージレジストリ**（`default-route-openshift-image-registry.apps-crc.testing`）が用意されています。ここに push して Job から参照させます。

### 4-1. 内部レジストリへ向けてイメージをビルド

```bash
podman build \
  -f container/Containerfile \
  -t default-route-openshift-image-registry.apps-crc.testing/pi4-kernel-build/openshift-rpi4-kernel-build:latest \
  .
```

`container/Containerfile` の中身（参考）:

- ベース: `fedora:41`
- aarch64 向けクロスツールチェイン (`gcc-aarch64-linux-gnu` など)
- カーネルビルド依存 (`bison`, `flex`, `bc`, `openssl-devel`, `elfutils-libelf-devel`, …)
- `ccache` を有効化
- 非 root 実行（OpenShift のランダム UID と互換）

### 4-2. レジストリにログインして push

```bash
podman login -u kubeadmin -p "$(oc whoami -t)" \
  default-route-openshift-image-registry.apps-crc.testing

podman push \
  default-route-openshift-image-registry.apps-crc.testing/pi4-kernel-build/openshift-rpi4-kernel-build:latest
```

> 💡 自己署名証明書の警告が出る場合は、`--tls-verify=false` を付けるか、CRC の CA を信頼させてください。

push が成功すると、クラスター内部からは `image-registry.openshift-image-registry.svc:5000/pi4-kernel-build/openshift-rpi4-kernel-build:latest` という URL で参照可能になります（Job マニフェストはこの内部 URL を使う設定です）。

---

## Step 5: 永続ボリューム (PVC) を作る

成果物と ccache を保存する PVC を作ります。

```bash
oc apply -f manifests/pvc-ccache.yaml   # 20Gi
oc apply -f manifests/pvc-out.yaml      # 30Gi
```

確認:

```bash
oc get pvc -n pi4-kernel-build
# NAME         STATUS   VOLUME ...   CAPACITY
# ccache-pvc   Bound    ...          20Gi
# out-pvc      Bound    ...          30Gi
```

---

## Step 6: カーネルビルド Job を実行する

### 6-1. Job を投入

```bash
oc apply -f manifests/job-build.yaml
```

`manifests/job-build.yaml` で使われている主な環境変数:

| 変数 | デフォルト | 説明 |
|------|----------|------|
| `KERNEL_REPO` | `https://github.com/raspberrypi/linux.git` | カーネルソースの取得元 |
| `KERNEL_REF` | `rpi-6.6.y` | ブランチ / タグ |
| `DEFCONFIG` | `bcm2711_defconfig` | Pi 4 用の defconfig |
| `JOBS` | `2` | `make -j` の並列数 |

### 6-2. 進捗を見る

```bash
# Pod が起動するまで少し待つ
oc get pods -n pi4-kernel-build -w

# ログを追いかける
oc logs -f job/rpi4-kernel-build -n pi4-kernel-build
```

順調にいけば、以下のような流れが流れていきます:

```
==> Fetch kernel source
==> Configure (bcm2711_defconfig)
==> Build (Image/modules/dtbs)
   ...
==> Install modules into OUT_DIR/mods
==> Build summary
   -rw-r--r-- ... arch/arm64/boot/Image
==> ccache stats
DONE
```

> ⏱ 初回ビルドはおよそ 30〜60 分（割り当て CPU 次第）。2 回目以降は ccache が効いて大幅に短縮されます。

### 6-3. 完了の確認

```bash
oc get job -n pi4-kernel-build rpi4-kernel-build
# COMPLETIONS   DURATION   AGE
# 1/1           45m        50m
```

---

## Step 7: ビルド成果物を取り出す

成果物は `out-pvc` の `/work/out` に保存されます。Job Pod がまだ残っている間にコピーするのが一番楽です。

### 方法 A: Job Pod から直接コピー

```bash
POD="$(oc get pods -n pi4-kernel-build -l job-name=rpi4-kernel-build \
       -o jsonpath='{.items[0].metadata.name}')"

oc cp -n pi4-kernel-build "$POD":/work/out ./out
```

### 方法 B: 別 Pod で `out-pvc` をマウントして取り出す

Job Pod が既に消えている場合や、後日取り出したい場合はこちら。

```bash
oc run -n pi4-kernel-build out-reader \
  --image=registry.access.redhat.com/ubi9/ubi \
  --restart=Never --command -- sleep 3600

oc patch -n pi4-kernel-build pod/out-reader -p '{
  "spec":{
    "volumes":[{"name":"out","persistentVolumeClaim":{"claimName":"out-pvc"}}],
    "containers":[{
      "name":"out-reader",
      "image":"registry.access.redhat.com/ubi9/ubi",
      "command":["sleep","3600"],
      "volumeMounts":[{"name":"out","mountPath":"/work/out"}]
    }]
  }
}'

oc cp -n pi4-kernel-build out-reader:/work/out ./out
oc delete pod -n pi4-kernel-build out-reader
```

### 主な成果物

- `out/arch/arm64/boot/Image` — カーネル本体
- `out/arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-*.dtb` — デバイスツリー
- `out/mods/lib/modules/<ver>/` — カーネルモジュール群

これらを SD カードの boot / root パーティションに配置すれば、実機の Raspberry Pi 4 で起動できます。

---

## 再ビルドのやり方

Kubernetes の `Job` リソースは spec を変更できないため、**削除して再投入**します。`ccache-pvc` は残るので 2 回目以降は速くなります。

```bash
oc delete job rpi4-kernel-build -n pi4-kernel-build
oc apply -f manifests/job-build.yaml
```

---

## カスタマイズ（メインラインを使う等）

`manifests/job-build.yaml` の `env:` セクションを書き換えるだけで、別のカーネルもビルドできます。

例: メインライン（`torvalds/linux`）の `v6.10` をビルド

```yaml
- name: KERNEL_REPO
  value: https://github.com/torvalds/linux.git
- name: KERNEL_REF
  value: v6.10
- name: DEFCONFIG
  value: defconfig          # arm64 汎用 defconfig
```

ビルド並列度を上げたい場合（CPU 余裕がある環境向け）:

```yaml
- name: JOBS
  value: "8"
```

`resources.limits` も合わせて引き上げてください。

---

## 片付け

デモが終わったら、リソースを削除して OpenShift Local を停止できます。

```bash
# Job と PVC を消す（namespace ごと消すのが手っ取り早い）
oc delete namespace pi4-kernel-build

# クラスターを止める
crc stop

# 完全に消す場合
crc delete
```

---

## トラブルシューティング

### Pod が `Pending` のまま動かない

- `oc describe pod -n pi4-kernel-build <pod-name>` を見て、`Insufficient cpu` / `Insufficient memory` と出ていないか確認。
- `crc config set cpus 8` / `crc config set memory 24576` で割り当てを増やし、`crc stop && crc start` で再起動。

### `ImagePullBackOff` になる

- Step 4 の push が成功しているか確認: `oc get is -n pi4-kernel-build`
- 内部レジストリ URL（`image-registry.openshift-image-registry.svc:5000/...`）がマニフェストの `image:` と一致しているか確認。

### `podman push` で 401/403

- `podman login` を再実行（`oc whoami -t` のトークンは有効期限あり）。
- `kubeadmin` でログインしているか確認: `oc whoami` が `kubeadmin` を返すこと。

### ビルドが OOM Killed で落ちる

- `JOBS` を下げる（例: `"2"` → `"1"`）。
- `resources.limits.memory` を増やす（クラスター割り当ても合わせて拡大）。

### ログを後から見たい

```bash
oc logs -n pi4-kernel-build job/rpi4-kernel-build > build.log
```

---

## プロジェクト構成

```
.
├── container/
│   └── Containerfile         # ビルド用イメージ定義（Fedora + クロスツールチェイン）
├── manifests/
│   ├── namespace.yaml        # pi4-kernel-build Namespace
│   ├── pvc-ccache.yaml       # ccache 用 PVC (20Gi)
│   ├── pvc-out.yaml          # 成果物用 PVC (30Gi)
│   └── job-build.yaml        # ビルド Job 本体
├── scripts/
│   └── build.sh              # コンテナ内で実行される実ビルドスクリプト
├── README.md                 # 英語版
└── README.ja.md              # 日本語版（このファイル）
```

### セキュリティコンテキスト

OpenShift の制限的な SCC でそのまま動くよう、以下を採用しています:

- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile: RuntimeDefault`

---

## License

MIT. 詳細は `LICENSE` を参照してください。
