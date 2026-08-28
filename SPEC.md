# Dimensional Port

## 1. 概要

**Dimensional Port** は、Factorio 2.0向けの共有仮想ストレージMODである。

アイテムおよび流体を通常のチェストやタンクへ大量に保存するのではなく、「異次元空間」へ送り込み、数量データとして保存する。

異次元空間に保存された物資は、設置場所・Surface・惑星に関係なく、任意のDimensional Portから取り出すことができる。

例：

* Nauvisで鉄板を投入する。
* 鉄板は共有仮想ストレージへ格納される。
* Vulcanusに設置したDimensional Portから、同じ鉄板を取り出せる。

Dimensional Portは無限チェスト・無限パイプではない。

取り出せる数量は、実際にプレイヤーがDimensional Portへ投入した数量を上限とする。

---

## 2. 基本概念

### 2.1 Dimensional Storage

MODは、全プレイヤー・全Surfaceで共有される単一の仮想ストレージを持つ。

仮想ストレージは実体を持つFactorio Inventoryではなく、MODの永続データ上で数量として管理する。

概念例：

```lua
storage.dimensional_storage = {
    items = {
        -- 品質を含めて管理
    },

    fluids = {
        -- 流体および必要な属性を含めて管理
    }
}
```

仮想ストレージは以下によって分割しない。

* Player
* Force
* Surface
* Planet
* Network ID

ゲーム全体に一つだけ存在する。

---

## 3. Item Port

### 3.1 基本仕様

アイテム用Dimensional Portは、同一のEntity Prototypeを使用する。

設置後、各Portについて以下のモードを選択できる。

* `Supply`
* `Request`

Supply用EntityとRequest用Entityを別々には作成しない。

モードはPort単位で保持する。

---

### 3.2 Entityサイズ・外観

Item PortのEntityサイズは **1×1 tile** とする。

初期実装では、通常の鋼鉄チェストを基礎とし、赤色に着色したグラフィックを使用する。

これは初期実装用の暫定グラフィックであり、将来的にDimensional Port専用のグラフィックへ変更する予定である。

外観の変更によって、Item Portの基本機能・保存データ・設置済みEntityとの互換性を不必要に損なわない設計とする。

---

## 4. Supplyモード

### 4.1 基本動作

SupplyモードのPortは、内部Inventoryへ投入された全アイテムをDimensional Storageへ送る。

投入するアイテムの種類を事前指定する必要はない。

通常のインサータ、ローダー等によってPortへ投入されたアイテムを受け付ける。

---

### 4.2 吸収周期

Supply Portは原則として、**30 tickごと**に処理する。

処理時点でPort内部Inventoryに存在するアイテムをすべてDimensional Storageへ移動する。

数量による転送上限は設けない。

例：

```text
Supply Port

鉄板    800
銅板    300
歯車     50

        ↓ 30 tick更新

Dimensional Storage

鉄板   +800
銅板   +300
歯車    +50

Supply Port

空
```

---

### 4.3 Supplyの基本思想

異次元空間へ物質を送り込む処理は高速であり、Portへ投入済みの物資は一括して吸収できるものとする。

Supply側には、Request側と同様の5スタック制限を設けない。

---

## 5. Requestモード

### 5.1 要求アイテム指定

Requestモードでは、プレイヤーが取り出したいアイテムをGUIから指定する。

要求アイテムは複数指定可能とする。

例：

```text
要求アイテム

[鉄板] [銅板] [電子基板]
```

要求数量は指定しない。

各要求アイテムについて、Portが自動的に必要な内部バッファを維持する。

---

## 6. Request内部バッファ

### 6.1 基本容量

各要求アイテムについて、**そのアイテムの5スタック分**をPort内部に維持する。

目標数量はアイテム固有のstack_sizeから計算する。

```text
target = stack_size × 5
```

例：

```text
stack_size = 100

目標数量 = 500
```

stack_sizeが200なら、

```text
目標数量 = 1000
```

となる。

---

### 6.2 補充周期

Request Portは原則として、**30 tickごと**に補充処理する。

各要求アイテムについて、

```text
不足数 = 5スタック分 - Port内部の現在数量
```

を計算する。

不足している場合のみDimensional Storageから取り出す。

例：

```text
鉄板

目標：500
現在：380

不足：120
```

Dimensional Storageに120以上存在する場合、

```text
Dimensional Storage
鉄板 -120

Request Port
鉄板 380 → 500
```

とする。

---

## 7. 仮想在庫不足

Dimensional Storageに存在しないアイテムは生成してはならない。

Request Portが要求している数量よりDimensional Storageの在庫が少ない場合、存在する数量のみ供給する。

例：

```text
Request Port

鉄板
目標：500
現在：0

Dimensional Storage
鉄板：73
```

結果：

```text
Request Port
鉄板：73

Dimensional Storage
鉄板：0
```

新たな鉄板がSupply PortからDimensional Storageへ投入された場合、以後のRequest更新時に再び補充可能となる。

---

## 8. 複数Request Port間の公平配分

### 8.1 基本原則

同一アイテムを複数のRequest Portが要求しており、すべての不足分を満たすだけの仮想在庫が存在しない場合、利用可能な在庫をRequest Port間で可能な限り均等に配分する。

Entityの処理順によって、先に処理されたPortだけが在庫を取得する仕様にしてはならない。

---

### 8.2 例

Dimensional Storage：

```text
鉄板：300
```

Request Port：

```text
Port A
鉄板：0 / 500

Port B
鉄板：0 / 500

Port C
鉄板：0 / 500
```

結果：

```text
Port A +100
Port B +100
Port C +100
```

Dimensional Storage：

```text
鉄板：0
```

---

### 8.3 不足量が異なる場合

各Portの不足量を上限として公平に配分する。

例：

```text
Dimensional Storage
鉄板：400

Port A
現在400
不足100

Port B
現在0
不足500

Port C
現在0
不足500
```

まず公平に配分する。

```text
A +100
B +100
C +100
```

Port Aは目標数量に到達するため、それ以上の配分対象から除外する。

残り100をPort BとPort Cへ均等に配分する。

最終結果：

```text
Port A +100
Port B +150
Port C +150
```

このように、要求量を超えない範囲で可能な限り均等な配分を行う。

---

## 9. 複数アイテム要求

一つのRequest Portが複数種類のアイテムを要求している場合、各要求アイテムは独立して扱う。

Port全体で5スタックを共有するのではない。

例：

```text
Request Port

鉄板
銅板
電子基板
```

の場合、

```text
鉄板       → 5スタック
銅板       → 5スタック
電子基板   → 5スタック
```

をそれぞれ独立して維持する。

一つのPortに複数アイテムを設定したことによって、各アイテムの供給能力を分割してはならない。

---

## 10. Request設定変更

Request Portで要求アイテムを解除または変更した場合、そのアイテムについてPort内部に残っている物資をDimensional Storageへ返却する。

例：

```text
要求：
鉄板

内部：
鉄板 420
```

要求から鉄板を削除した場合、

```text
鉄板 420
→ Dimensional Storageへ返却
```

する。

アイテムを消滅させてはならない。

---

## 11. モード変更

RequestからSupplyへ変更する場合、Request用内部バッファに残っている物資をDimensional Storageへ返却する。

SupplyからRequestへ変更する場合も、変更時点で内部Inventoryに残っているアイテムについて適切にDimensional Storageへ格納し、アイテムの消失または複製が発生しないようにする。

モード変更によって物資総量が変化してはならない。

---

## 12. Entity破壊・撤去

Dimensional Portが撤去・破壊された場合、内部Inventoryに残っているDimensional Storage由来の物資を適切にDimensional Storageへ返却する。

Portの撤去・破壊によってアイテムの複製または消失が発生してはならない。

通常のプレイヤー操作による採掘だけでなく、Entity死亡、スクリプトによる削除等についても考慮する。

---

## 13. 品質

Factorio 2.0のQualityに対応する。

同一Item Prototypeであっても品質が異なる場合、別の在庫として管理する。

例：

```text
鉄板 / Normal       10,000
鉄板 / Uncommon        500
鉄板 / Rare             20
```

Request設定についても品質を区別する。

Normal品質の鉄板を要求しているPortからRare品質の鉄板を自動的に取り出してはならない。

Supplyされた品質を維持したままDimensional Storageへ保存する。

---

## 14. GUI

### 14.1 基本構成

Item PortのGUIには最低限以下を表示する。

#### モード

```text
[ Supply ] [ Request ]
```

#### Request設定

Requestモードの場合のみ表示する。

複数の要求アイテムをアイコンによって指定できる。

```text
[鉄板] [銅板] [電子基板] [+]
```

要求数量は指定しない。

#### Dimensional Storage

現在Dimensional Storageに存在するアイテムを、**アイコン + 数量**形式で一覧表示する。

Factorioの物流ネットワーク在庫表示に近い形式を使用する。

例：

```text
[鉄板]   [銅板]   [基板]   [歯車]
12.0k     6.2k     3.8k      850
```

必要に応じてTooltipで正確な数量を表示する。

---

## 15. アイテム検索

Dimensional Storage一覧には検索機能を設ける。

検索文字列に一致するアイテムのみを表示できるようにする。

大量のMODアイテムが存在する環境でも利用可能なGUIを前提とする。

検索によってDimensional Storageそのものの内容が変更されてはならず、表示対象のみを絞り込む。

---

## 16. Fluid Port

### 16.1 基本思想

流体についてもItem Portと同様にDimensional Storageへ数量として保存する。

Fluid Portも、

* `Supply`
* `Request`

を同一Entity上で切り替える。

---

### 16.2 Entityサイズ・外観

Fluid PortのEntityサイズは **1×1 tile** とする。

初期実装では、通常のパイプを基礎とし、赤色に着色したグラフィックを使用する。

これは初期実装用の暫定グラフィックであり、将来的にDimensional Port専用のグラフィックへ変更する予定である。

外観の変更によって、Fluid Portの基本機能・保存データ・設置済みEntityとの互換性を不必要に損なわない設計とする。

---

### 16.3 Supply

Supplyモードでは、Fluid Portへ流入した流体を一定周期でDimensional Storageへ吸収する。

Item Portと同様、異次元空間への送信側として動作する。

---

### 16.4 Request

Requestモードでは、一つのFluid Portにつき一種類の流体を指定する。

Item Portと異なり、複数種類の流体を同一Fluid Portから同時出力しない。

指定された流体のみをPortのfluidboxへ供給する。

Dimensional Storageに存在する数量を超えて生成してはならない

---

## 17. 流体温度

温度が異なる同一流体については、異なる状態として扱うことを基本方針とする。

例：

```text
Steam 165℃
Steam 500℃
```

を無条件に同一在庫として混合しない。

ただし、Factorio 2.0におけるFluid Prototype、fluidbox、温度処理の正確な仕様を確認した上で、具体的な内部データ構造およびGUI仕様を決定する。

この部分は実装前にFactorio 2.0 API仕様を確認すること。

---

## 18. 回路ネットワーク

回路ネットワーク対応は将来実装とする。

初回実装の必須要件には含めない。

将来的にはDimensional Storage内の在庫数量を回路信号として取得できる機能を検討する。

例：

```text
鉄板 = 12000
銅板 = 6000
電子基板 = 3800
```

通常のDimensional Port自身から信号を出力する方式だけでなく、専用Combinator Entityを追加する方式も候補とする。

具体的な方式は未確定。

---

## 19. 更新処理とUPS

UPS負荷を考慮し、すべての処理を毎tick実行することを前提としない。

基本更新周期は、

```text
30 tick
```

とする。

対象：

* Supply Portの吸収
* Request Portの補充
* Fluid Portの入出力

ただし、実際の性能測定によって更新方式を変更できるものとする。

多数のPortが存在する場合、一つのtickに全Portを集中処理することでtick spikeが発生する場合は、処理を複数tickへ分散する方式を検討する。

ゲーム上の動作仕様を維持できる限り、UPS負荷の低い実装を優先する。

---

## 20. アイテム総量保存則

Dimensional Portは無限アイテム生成装置ではない。

以下の原則を必ず維持する。

```text
Dimensional Storage内数量
+
各Dimensional Port内部に実体化している数量
```

は、Supplyによって実際に投入された総量を基準とする。

以下の操作によって物資を複製または不当に消失させてはならない。

* Supply
* Request
* Request変更
* Request解除
* モード変更
* Port採掘
* Port破壊
* Entity削除
* Surface関連処理
* Quality変更を伴う処理

---

## 21. MODの世界観上の定義

Dimensional Portは、通常空間とは異なる共有された異次元空間へ物質を送り込み、必要に応じて再び通常空間へ取り出すための装置である。

異次元空間そのものに地理的な位置は存在しない。

そのため、

* Nauvis
* Vulcanus
* Fulgora
* Gleba
* Aquilo
* その他MODによって追加されたSurface

のいずれから投入・取り出しを行っても、同一のDimensional Storageへアクセスする。

異次元空間への投入は比較的容易である一方、通常空間への再実体化には制約がある。

この性質を、

* Supply：30 tickごとに内部在庫を全吸収
* Request：30 tickごとに各要求アイテムを最大5スタックまで維持

というゲーム上の挙動として表現する。

---

## 22. 初回実装範囲

初回実装では以下を優先する。

* 単一のグローバルDimensional Storage
* Item Port
* Supply / Requestモード切替
* Supplyによるアイテム吸収
* Requestによる複数アイテム指定
* 各要求アイテム5スタック維持
* 複数Request Port間の公平配分
* Quality対応
* Request変更時の在庫返却
* Port撤去・破壊時の安全な在庫処理
* Dimensional Storage GUI
* アイコン＋数量表示
* アイテム検索

Fluid PortについてはItem Portの基本実装を基礎として実装する。

回路ネットワーク対応は初回実装の必須要件に含めない。

---

## 23. 未確定事項

以下は現時点では確定仕様としない。

* Item PortのInventoryサイズ
* 一つのItem Portで指定可能な最大要求アイテム数
* GUIの具体的なレイアウト
* Crafting Recipe
* Technology
* Fluid Portの容量
* Fluid Portの具体的な転送量
* 温度付き流体の内部表現
* 回路ネットワーク対応方式
* 大量Port設置時の具体的な更新分散アルゴリズム

これらは実装・性能測定・Factorio 2.0 API仕様確認を行った上で決定する。

未確定事項について、実装時に推測で仕様を確定してはならない。
