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
        -- Fluid Prototypeごとにamountとtemperatureを管理
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

Item PortはSupply / Requestの手動モード切替を持たない。

各Portは常に双方向Portとして動作し、外部から投入されたアイテムをDimensional Storageへ格納できる。

Requestが指定されている場合は、指定アイテムおよび品質をDimensional Storageから内部Request Bufferへ実体化し、外部から取り出せるようにする。

Requestが指定されていない場合は、外部から投入されたアイテムを30 tickごとにDimensional Storageへ送るため、実質的に旧Supply Port相当として動作する。

---

### 3.2 Entityサイズ・外観

Item PortのEntityサイズは **1×1 tile** とする。

Item Portは、工業的な拘束装置の中央に黒い次元裂孔と白い空間歪みを持つデザインとする。

単なる魔法陣や自然発生した穴ではなく、暗鉄色・黒鉄色・暗赤色の機械フレーム、固定装置、ボルト、警告光などによって、異常な次元現象をFactorio的な工業設備で拘束している外観とする。

黒い裂孔と白い歪みは異なる速度でアニメーションし、可能であれば逆方向の回転感を持たせる。

Item Portは固体物質を転送する装置として、裂孔周辺に小さな固体片、金属片、角張った粒子などを控えめに配置する。

静止状態でも床模様ではなく設置された設備として認識できるよう、本体スプライトと影によって厚みと立体感を持たせる。

ただし多数設置時のUPSを考慮し、アニメーションは毎tickのcontrol stage処理で駆動してはならない。

既存のContainer Prototypeを維持する初期実装では、ポート画像を背景・前景・影に分割し、中央の渦はEntity Prototypeの`stateless_visualisation`によるAnimationとして表現する。

本体の静止スプライトは配置プレビューおよびghost表示でも中央が地面まで透けないように保持する。

渦Animationには前景フレームを同じAnimation layer内で含める。現行の前景画像の中央が完全透過ではない場合は、画像を編集せず渦の表示を優先するため、渦を同visualisation内の後段レイヤーとして描画する。前景による完全な渦遮蔽が必要な場合は、前景画像の中央透過を別途調整する。

渦描画はLuaRenderingや補助EntityではなくPrototype graphics側で完結させ、ポート周辺の他Entityとの前後関係はFactorio標準のEntity描画順に従わせる。

外観の変更によって、Item Portの基本機能・保存データ・設置済みEntityとの互換性を不必要に損なわない設計とする。

---

### 3.3 Inventory

Item Portの内部Inventoryサイズは、通常の鋼鉄チェストと同等とする。

初期実装では、vanillaの鋼鉄チェストに準拠したInventory容量を使用する。

このInventoryは、Request BufferとIngress相当の一時投入領域に分けて使用する。

* slots 1～40: Request Buffer
* slots 41～48: 常時Ingress領域

Request Bufferは、最大8種類のRequestに対して各5スロットずつ割り当てる。

Requestが設定されている5スロット領域だけを正式なRequest Bufferとして扱う。

Requestが設定されていない5スロット領域は、物理的にはslots 1～40内であっても、処理上はIngress相当の一時投入領域として扱う。

現在有効なRequestに割り当てられていないすべてのslotは、外部から投入された任意のアイテムを一時的に受け入れ、30 tick更新時にRequest BufferまたはDimensional Storageへ移動する。

Dimensional StorageそのものをItem PortのInventoryへ保持してはならない

---

## 4. Item Portの投入処理

### 4.1 基本動作

Item Portは、外部から投入されたアイテムを常に受け入れ、30 tickごとに処理する。

Requestが存在しない場合、内部Inventoryへ投入された全アイテムをDimensional Storageへ送る。

Requestが存在する場合、Request Bufferに対応するアイテムおよび品質は不足分として利用し、Request対象外または上限を超えるアイテムはDimensional Storageへ送る。

---

### 4.2 吸収周期

Item Portの投入処理は原則として、**30 tickごと**に処理する。

Requestが存在しない場合、処理時点でPort内部Inventoryに存在するアイテムをすべてDimensional Storageへ移動する。

Requestが存在する場合、現在有効なRequestに割り当てられていないすべてのslotにあるアイテムを確認し、対応するRequest Bufferに空きがある要求対象アイテムはRequest Bufferへ移動する。

Request Bufferへ入りきらない分、およびRequest対象外アイテムはDimensional Storageへ送る。

例：

```text
RequestなしItem Port

鉄板    800
銅板    300
歯車     50

        ↓ 30 tick更新

Dimensional Storage

鉄板   +800
銅板   +300
歯車    +50

Item Port

空
```

---

### 4.3 Ingress相当領域

slots 41～48は常時Ingress領域とする。

常時Ingress領域にはInventory filterを設定しない。

slots 1～40内でRequestが設定されていない5スロット単位の領域も、処理上はIngress相当として扱う。

Ingress相当領域にはInventory filterを設定しない。

Request設定を追加または変更した場合、そのRequestに割り当てられる5スロット内に既存アイテムが存在する可能性があるため、物資をDimensional Storageへ退避してから新しいfilterを適用する。

外部から投入されたアイテムがRequest対象であり、対応Request Bufferに空きがある場合、そのアイテムはDimensional Storageへ一度送らずにRequest Bufferへ移動する。

Request Bufferに入ったアイテムは、Dimensional Storageから実体化されたアイテムと同様に、共有キャッシュとして扱う。

---

## 5. Request設定

### 5.1 要求アイテム指定

Item Portでは、プレイヤーが取り出したいアイテムをGUIから指定できる。

要求アイテムは複数指定可能とする。

例：

```text
要求アイテム

[鉄板] [銅板] [電子基板]
```

要求数量は指定しない。

各要求アイテムについて、Portが自動的に必要な内部バッファを維持する。

---

### 5.2 最大要求アイテム数

一つのItem Portで同時に指定可能な要求アイテム数は、最大8種類とする。

Item Portの内部Inventoryは48スロットであり、各要求アイテムについて5スロットを割り当てるため、

5スロット × 8種類 = 40スロット

をRequest Bufferとして使用する。

slots 41～48の8スロットは常時Ingress領域として使用し、要求アイテム数の追加には使用しない。

要求アイテム数が8種類を超える設定は許可しない。

各要求スロットでは、アイテムおよび品質を指定できる。

要求スロットは最大8スロットの固定位置として扱う。

途中に空スロットが存在しても、それ以降の要求スロットは有効な要求として処理する。

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

Requestが指定されているItem Portでも、外部からItem Port内部Inventoryへのアイテム投入を受け付ける。

Request Bufferは、Dimensional Storageから実体化された要求アイテム、および外部から投入されて同じ要求アイテムとして受け入れられたアイテムを保持し、インサータ、ローダー、プレイヤー等によって外部へ取り出すためのバッファとして使用する。

Request Bufferに割り当てられた各5スロットには、対応するアイテムおよび品質のInventory filterを設定する。

要求スロットが空の場合、その5スロットのInventory filterは解除する。

Ingress相当領域にはInventory filterを設定しない。

要求対象外のアイテムによってRequest Bufferが占有された場合、30 tick更新時にDimensional Storageへ返却し、各要求アイテムの5スタック維持を妨げ続けないようにする。

MODはItem Portごとに、Request Buffer内で共有キャッシュとして扱うアイテム数量を、アイテムおよび品質ごとに永続stateとして記録する。

この記録は、Request設定変更、Port撤去・破壊、事前削除イベントを通らないEntity消滅時に物資総量保存則を可能な限り維持するために使用する。

この記録はDimensional Storageそのものではなく、Port内部Inventoryに実体化している数量を追跡するための補助stateである。

Request Buffer内のアイテムは、そのPortが恒久的に所有する在庫ではなく、通常空間へ実体化された共有キャッシュとして扱う。

Request Buffer内のアイテムは、Portからインサータ、ローダー、プレイヤー等によって外部へ取り出されるまでは、同一アイテムおよび品質を要求する他のItem Portへ再配分可能とする。

再配分対象として扱う数量は、Port内部Inventory内の全数量ではなく、`materialized` stateに記録され、かつ実Inventory内に存在している数量に限る。

Ingress相当領域内にある未処理アイテムは、共有キャッシュとして扱わない。

---

### 6.2 補充周期

Request補充は原則として、**30 tickごと**に処理する。

各要求アイテムについて、

```text
最大保持量 = 5スタック分
補充閾値 = 4スタック分
```

を使用する。

現在量が4スタック分以上である場合、Dimensional Storageから補充しない。

現在量が4スタック分未満である場合のみ、

```text
不足数 = 5スタック分 - 現在数量
```

を計算し、Dimensional Storageから取り出す。

例：

```text
鉄板

最大：500
補充閾値：400
現在：380

不足：120
```

Dimensional Storageに120以上存在する場合、

```text
Dimensional Storage
鉄板 -120

Request指定Item Port
鉄板 380 → 500
```

とする。

---

## 7. 仮想在庫不足

Dimensional Storageに存在しないアイテムは生成してはならない。

Request指定Item Portが要求している数量よりDimensional Storageの在庫が少ない場合、存在する数量のみ供給する。

例：

```text
Request指定Item Port

鉄板
目標：500
現在：0

Dimensional Storage
鉄板：73
```

結果：

```text
Request指定Item Port
鉄板：73

Dimensional Storage
鉄板：0
```

新たな鉄板がRequestなしItem PortなどからDimensional Storageへ投入された場合、以後のRequest更新時に再び補充可能となる。

---

## 8. 複数Request指定Port間の公平配分

### 8.1 基本原則

同一アイテムを複数のRequest指定Item Portが要求しており、すべての不足分を満たすだけの仮想在庫が存在しない場合、利用可能な在庫をRequest指定Item Port間で可能な限り均等に配分する。

Entityの処理順によって、先に処理されたPortだけが在庫を取得する仕様にしてはならない。

アイテムのように整数単位で配分する物資について、在庫がRequest指定Item Port数より少ない場合でも、同じPortだけが恒常的に優先されてはならない。

割り切れない余りは、同一アイテムおよび品質ごとに次回以降の配分開始位置をずらしながら配分する。

流体については、不足量を上限として可能な限り直接均等に配分する。

同一アイテムおよび品質を要求するRequest指定Item Portの集合が変化した場合、既に各Request指定Item Portへ実体化されている共有キャッシュも含めて、必要に応じて公平に再平衡する。

再平衡では、Dimensional Storage内数量と各Request指定Item Portの`materialized`数量を共有可能総量として扱い、各Request指定Item Portの5スタック上限を超えない範囲で望ましい割当量を計算する。

割当量を超えて保持しているPortからは、超過分のみをInventoryから回収してDimensional Storageへ返却し、その後、不足しているPortへDimensional Storageから実体化する。

再平衡は必ず回収と再実体化の二段階で行い、Port間で直接Inventoryを移動しない。

通常の30 tick補充処理ごとに既存の`materialized`在庫を再平衡してはならない。

---

### 8.2 例

Dimensional Storage：

```text
鉄板：300
```

Request指定Item Port：

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

一つのRequest指定Item Portが複数種類のアイテムを要求している場合、各要求アイテムは独立して扱う。

Port全体で5スタックを共有するのではない。

例：

```text
Request指定Item Port

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

Item Portで要求アイテムを解除または変更した場合、その要求に割り当てられたRequest Buffer内に残っている物資をDimensional Storageへ返却する。

Fluid Portで要求流体を解除または変更した場合も、Port内部に残っている旧要求流体をDimensional Storageへ安全に返却してから新しい要求を設定する。

温度付き流体など、初回実装の方針上安全にDimensional Storageへ格納できない流体については、推測による温度変換や混合処理を行わない。

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

Supply / Requestの手動モード切替は廃止する。

旧セーブに保存されている`port.mode = "supply"`は、Requestなしの双方向Portとして移行する。

旧セーブに保存されている`port.mode = "request"`は、既存のRequest設定を維持した双方向Portとして移行する。

移行によって物資総量が変化してはならない。

---

## 12. Entity破壊・撤去

Dimensional Portが撤去・破壊された場合、内部Inventoryまたはfluidboxに残っている内容物を安全に処理する。

通常の事前削除イベントでEntity内部のInventoryまたはfluidboxを参照できる場合、Request BufferおよびIngress相当領域内のアイテム、またはfluidbox内の安全に扱える流体をDimensional Storageへ返却する。

Portの撤去・破壊によってアイテムまたは流体の複製・不当な消失が発生してはならない。

通常のプレイヤー操作による採掘だけでなく、Entity死亡、スクリプトによる削除等についても考慮する。

通常の事前削除イベントを通らずPort Entityが無効化された場合でも、永続stateに記録されたRequest Buffer内の共有キャッシュ数量をDimensional Storageへ返却し、総量保存則を可能な限り維持する。

ただしEntity消滅後に実Inventoryを参照できない場合、Ingress相当領域内の未処理アイテムや、前回同期後に外部から投入された未同期アイテムはMOD側で正確に復元できない。

通常の事前削除イベントと破壊監視による後続通知で二重返却してはならない。

---

## 13. 品質

Factorio 2.0のQualityに対応する。

同一Item Prototypeであっても品質が異なる場合、別の在庫として管理する。

Factorio公式のQuality MODが有効な環境では、そのQuality Prototypeおよび品質対応GUIを使用できるよう、MOD読み込み順を考慮する。

例：

```text
鉄板 / Normal       10,000
鉄板 / Uncommon        500
鉄板 / Rare             20
```

Request設定についても品質を区別する。

Normal品質の鉄板を要求しているPortからRare品質の鉄板を自動的に取り出してはならない。

Supplyされた品質を維持したままDimensional Storageへ保存する。

Dimensional Storageに保存済みのPrototype名またはQuality Prototype名が、MOD構成変更によって一時的に存在しなくなった場合、その在庫データを勝手に削除またはNormal品質へ変換してはならない。

存在しないPrototypeに対応する在庫はorphan dataとして保持し、GUI表示、Request処理、Inventory filter設定など実Prototypeを必要とする処理からは一時的に除外する。

該当Prototypeが再び存在するようになった場合は、保持されていた在庫を再利用できる設計とする。

---

## 14. GUI

### 14.1 基本構成

Item PortのGUIには最低限以下を表示する。

#### Request設定

Item Portでは常にRequest設定を表示する。

複数の要求アイテムをアイコンによって指定できる。

要求アイテム指定には、要求チェストの物流要求スロットに近い、Factorio 2.xの品質対応選択GUIを使用する。

初期実装では、Factorio Runtime APIの `choose-elem-button` に `elem_type = "item-with-quality"` を使用し、アイテムと品質を一つの選択GUIから指定する。

選択結果は `PrototypeWithQuality` の `{name, quality}` として取得し、既存のRequestデータ構造である `{name, quality}` として保存する。

要求アイテム選択には `elem_type = "signal"` を使用しない。Virtual Signal、Fluid Signal等を要求アイテムとして選択対象に含めない。

Normal品質も選択可能とする。

メインのRequest設定欄に品質選択UIを常時表示する必要はないが、アイテム指定時には品質も合わせて指定できなければならない。

品質指定はFactorio標準の品質付きアイテム選択GUIに寄せ、MOD独自の常設品質選択UIは設けない。

要求数量はDimensional Port側では指定しないため、選択GUIからはアイテム名と品質のみを利用する。

要求解除はFactorio標準の選択解除操作を使用し、専用の削除ボタンは設けない。

Item Portでは、Dimensional Storage一覧に表示されているアイテムアイコンをクリックすることでも、最初の空き要求スロットへ同じアイテムおよび品質を追加できる。

この追加操作では、既に同じアイテムおよび品質が要求に存在する場合は重複追加しない。

要求スロットがすべて埋まっている場合、またはクリックした一覧項目がItem Prototypeではない場合は、要求を変更しない。

要求スロットは8列で表示し、最大要求数8種類を1行に収める。

```text
[鉄板] [銅板] [電子基板] [+]
```

要求数量は指定しない。

#### Dimensional Storage

現在Dimensional Storageに存在するアイテムを、**アイコン + 数量**形式で一覧表示する。

Item PortのGUIでは、すべてのRequest指定Item Portが保持している実体化済みバッファ分も、Portから取り出し可能な在庫として一覧数量へ含める。

この表示上の合算はGUI上の見やすさのためのものであり、Dimensional Storage内数量そのものを増減させるものではない。

GUIを開いている間、Dimensional Storage一覧は基本更新周期である30 tickごとに最新の数量へ更新する。

30 tickごとの通常更新では、表示対象のアイテム・品質・流体の構成が変わっていない場合、既存GUI要素の数量およびTooltipのみを更新する。

GUI一覧の全再構築は、GUIを開いた直後、検索文字列が変化した場合、表示対象の構成が増減した場合、または検索結果に影響するローカライズ名が更新された場合に限定する。

Factorioの物流ネットワーク在庫表示に近い形式を使用する。

アイテムおよび流体の数量は、通常のFactorioアイコン表示に近い形で、アイコンタイルの右下に表示する。

Dimensional Storage一覧は10列で表示し、表示領域を超える場合はスクロールによって全項目を確認できるようにする。

Dimensional Storage一覧の表示順は、可能な限りFactorio本体のインベントリや製作画面に近い順序とする。

アイテムは、Item Groupの`order`、Item Subgroupの`order`、Item Prototypeの`order`、Prototype名、Qualityのlevelの順にソートする。

同一Item Prototypeの品質違いは隣接させ、Qualityのlevelが低いものから高いものへ並べる。

流体も、Fluid Prototypeから取得できるgroup、subgroup、order、Prototype名に基づき、毎回安定した順序で表示する。

ジャンル見出しは初回実装では表示しない。

アイテム一覧のアイコンは、通常のFactorioアイテムアイコンと同様に、Uncommon以上の品質についてアイコン左下へ品質マークを表示する。

Normal品質では品質マークを表示しない。

例：

```text
[鉄板]   [銅板]   [基板]   [歯車]
12.0k     6.2k     3.8k      850
```

アイコンおよび数量表示にカーソルを合わせると、対象のアイテム名または流体名と数量をTooltipで確認できる。

アイテムTooltipに表示する品質名は、Quality Prototypeの`localised_name`を使用し、プレイヤーの表示言語に従う。

Fluid Portでは常にRequest流体選択欄を表示する。

Fluid Portでは、Dimensional Storage一覧に表示されているFluid Prototypeのアイコンをクリックすることでも、その流体を要求流体として指定できる。

Item PortではFluid Prototypeを要求アイテムとして追加してはならず、Fluid PortではItem Prototypeを要求流体として指定してはならない。

---

### 14.2 GUIレイアウト

GUIの具体的な配置、各要素のサイズ、列数、スクロール領域等については、初期実装後に実際のゲーム画面上で操作性を確認しながら調整する。

現時点では以下の機能要件のみを固定する。

* Request設定
* Dimensional Storage内のアイテム一覧
* アイコンおよび数量表示
* アイテム検索
* Dimensional CombinatorによるRead-Only回路出力

GUIの視覚的な配置について、SPECに記載されていない部分を実装上の恒久仕様として扱わない。

ウインドウを閉じるボタンは、Factorio標準GUIに近い操作感になるよう、ウインドウ右上へ配置する。

---

## 15. アイテム検索

Dimensional Storage一覧には検索機能を設ける。

検索文字列に一致するアイテムのみを表示できるようにする。

検索UIは、バニラの検索機構を直接再利用できない場合でも、Factorio標準GUIに近い見た目・操作性を持つ自前検索として実装する。

検索対象は、Dimensional Storageに実際に存在するアイテム・流体、およびRequest指定Item Port内に実体化している表示対象のアイテムのみとする。

検索は、内部prototype名に加えて、プレイヤーの表示言語でのローカライズ済み名称にも対応する。

ローカライズ済み名称は、`localised_name` をLua文字列として直接扱うのではなく、Factorio Runtime APIのローカライズ機構を使用して取得する。

multiplayerではプレイヤーごとに表示言語が異なる可能性があるため、検索用のローカライズ済み名称はプレイヤー単位で扱う。

大量のMODアイテムが存在する環境でも利用可能なGUIを前提とする。

GUI表示中に必要な対象だけを翻訳・キャッシュし、毎tick全prototypeに対してローカライズ処理を行ってはならない。

検索によってDimensional Storageそのものの内容が変更されてはならず、表示対象のみを絞り込む。

---

## 16. Fluid Port

### 16.1 基本思想

流体についてもItem Portと同様にDimensional Storageへ数量として保存する。

Fluid StorageはFluid Prototypeごとに一つのエントリを持ち、数量と温度を以下の形式で保持する。

```lua
storage.dimensional_storage.fluids[fluid_name] = {
    amount = amount,
    temperature = temperature
}
```

同一Fluid Prototypeの温度違いは、温度ごとに別Storageエントリへ分割しない。

同一Fluid Prototypeへ異なる温度の流体を追加する場合は、既存在庫量と追加量による加重平均でStorage温度を更新する。

```text
new_temperature = (old_amount * old_temperature + added_amount * added_temperature) / (old_amount + added_amount)
```

Storageから一部の流体を取り出す場合、取り出した流体はStorageに記録されているtemperatureを持つものとして扱い、残ったStorageエントリのtemperatureは変化しない。

Fluid Prototype名が異なる流体は、ローカライズ名、用途、温度帯が似ていても統合してはならない。

Fluid Portは一つのEntity Prototypeを使用する。

Fluid PortはSupply / Requestの手動モード切替を持たない。

Request流体が指定されていない場合、流入した流体を30 tickごとにDimensional Storageへ吸収する。

Request流体が指定されている場合、その流体用の双方向Portとして動作し、外部から流入した同一流体をそのまま利用しながら、不足分をDimensional Storageから補充する。

Request流体が指定されているFluid Portは指定流体専用とし、指定流体以外を受け入れない。

RequestはFluid Prototype単位で行い、温度違いだけを理由にRequestを解除してはならない。

ただし、Fluid Portが空で、Dimensional StorageにもRequest流体が存在しない場合など、Factorioの流体システム上、別流体が実fluidboxへ流入する可能性がある。

Request中に実fluidboxへRequest流体と異なる流体が流入した場合、そのFluid PortのRequestは自動的に解除する。

自動解除後、そのFluid PortはRequestなしPortとして動作する。

---

### 16.2 Entityサイズ・外観

Fluid PortのEntityサイズは **1×1 tile** とする。

Fluid PortはItem Portと同一系列の設備として、赤黒い工業フレーム、中央の黒い次元裂孔、白い空間歪みを共有するデザインとする。

Fluid Port固有の要素として、Pipe接続部、液滴、波紋、曲線的な流線などを使用し、液体が裂孔へ吸い込まれる装置として表現する。

Pipe接続部はFactorio上で接続方向が分かりにくくならないよう、中央の裂孔演出で隠さず視認可能にする。

黒い裂孔と白い歪みは異なる速度でアニメーションし、可能であれば逆方向の回転感を持たせる。

静止状態でも床模様ではなく設置された設備として認識できるよう、本体スプライトと影によって厚みと立体感を持たせる。

ただし多数設置時のUPSを考慮し、アニメーションは毎tickのcontrol stage処理で駆動してはならない。

既存のPipe Prototypeを維持する初期実装では、ポート画像を背景・前景に分割し、中央の渦はEntity Prototypeの`stateless_visualisation`によるAnimationとして表現する。

本体の静止スプライトは配置プレビューおよびghost表示でも中央が地面まで透けないように保持する。

渦Animationには前景フレームを同じAnimation layer内で含める。現行の前景画像の中央が完全透過ではない場合は、画像を編集せず渦の表示を優先するため、渦を同visualisation内の後段レイヤーとして描画する。前景による完全な渦遮蔽が必要な場合は、前景画像の中央透過を別途調整する。

渦描画はLuaRenderingや補助EntityではなくPrototype graphics側で完結させ、ポート周辺の他Entityとの前後関係はFactorio標準のEntity描画順に従わせる。

---

### 16.3 Fluidbox容量

Fluid Portのfluidbox容量は、

**25,000 fluid**

とする。

この容量はRequest流体の有無に関わらず共通とする。

---

### 16.4 Requestなし

Request流体が指定されていない場合、Fluid Portへ流入した流体をDimensional Storageへ吸収する。

処理周期は原則として、

**30 tickごと**

とする。

処理時点でFluid Portのfluidboxに存在する流体を、数量にかかわらず可能な限りすべてDimensional Storageへ移動する。

吸収時は、実fluidboxから取得したFluid Prototype名、amount、temperatureをStorageへ保存する。

同一Fluid Prototypeが既にStorageに存在する場合、amountを合算し、temperatureは加重平均で更新する。

吸収後、その数量をFluid Portのfluidboxから削除する。

Dimensional Storageへ保存した数量とfluidboxから削除した数量は必ず一致させ、流体の複製または消失を発生させてはならない。

---

### 16.5 Requestあり

Fluid Portでは、一つのFluid Portにつき一種類の流体を指定する。

複数種類の流体を同一Fluid Portから同時に出力してはならない。

Request流体が指定されている場合、Fluid PortはFactorio 2.0 Runtime APIの`LuaFluidBox::set_filter(index, filter)`を使用し、fluidboxのfilterを指定流体に設定する。

このfilterは異種流体流入を抑制するための補助として使用する。

fluidbox filterだけで異種流体の流入を完全に防げない場合があるため、Request中に実fluidbox内の流体がRequest流体と異なることを検出した場合、そのRequestを自動解除する。

自動解除時は、旧Request由来の`materialized` stateをDimensional Storageへ加算せず、実fluidboxの内容を正として扱う。

実fluidbox内の流体が安全に扱える場合は、RequestなしPortとしてその流体のみをDimensional Storageへ吸収し、fluidboxを空にする。

自動解除した30 tick更新では、旧Request流体を補充対象に含めてはならない。

Fluid PortのGUIを開いているプレイヤーがいる場合、Request表示は自動解除に追従して空欄へ更新する。

Requestを解除した場合はfluidbox filterを解除し、再び任意の安全に扱える流体を吸収できるようにする。

Requestを変更する場合は、現在のfluidbox内容を安全にDimensional Storageへ返却し、fluidboxを空にしてから新しいfilterを設定する。

30 tickごとに、指定流体についてfluidboxの不足量を計算し、最大容量である25,000まで維持する。

Dimensional StorageからFluid Portへ補充する場合は、Storageエントリに記録されているtemperatureをFluidテーブルへ含めて投入する。

補充後は、実fluidboxのamountおよびtemperatureを正として`materialized` stateへ同期する。

例：

```text
Fluid Port容量：25,000
現在：8,000

Dimensional Storageに十分な在庫あり

→ 17,000供給
→ Fluid Port：25,000
```

Dimensional Storageの在庫が不足している場合は、存在する数量のみ供給する。

例：

```text
Fluid Port容量：25,000
現在：0

Dimensional Storage：
硫酸 4,500

→ 4,500供給
→ Dimensional Storage：0
```

新たな流体がRequestなしFluid PortなどからDimensional Storageへ追加された場合、以後の更新で再び補充する。

Request流体と同じ流体が外部から流入した場合、その流体はDimensional Storageへ一度送らず、Fluid Port内のバッファとしてそのまま利用する。

Request流体と同じFluid Prototypeで温度だけが異なる流体がPort内に存在する場合は、Requestを維持し、Port内の混合挙動はFactorio本来のfluidboxおよび`insert_fluid`の挙動に従う。

異なる種類の流体をMOD側で混在させる機能は実装しない。

異種流体の接続・混合防止については、可能な限りFactorio本来のfluid systemの制約を利用し、MOD独自の毎tick監視は追加しない。

同一流体を複数のRequest Fluid Portが要求しており、すべてのPortの不足量を満たすだけのDimensional Storage在庫が存在しない場合、利用可能な流体を各Portの不足量を上限として可能な限り均等に配分する。

Entityの処理順によって、先に処理されたFluid Portだけが在庫を取得する仕様にしてはならない。

---

## 17. 流体温度

Dimensional Storageは流体温度を正式に扱う。

実fluidboxから取得したFluid Prototype名、amount、temperatureを保存対象とし、default temperatureと異なることを理由に保存を拒否してはならない。

temperatureが取得できない場合は、該当Fluid Prototypeの`default_temperature`を使用して正規化する。

同一Fluid Prototypeの異温度流体をStorageへ追加する場合は、amountを合算し、temperatureを加重平均する。

Storageから流体を取り出す場合は、Storageに記録されているtemperatureを使用する。

Fluid Portの`materialized` stateにも、可能な限り以下の形式で流体名、数量、温度を保持する。

```lua
port.materialized = {
    name = fluid_name,
    amount = amount,
    temperature = temperature
}
```

通常運用中は実fluidboxを正として、`materialized`のname、amount、temperatureを同期する。

通常の撤去・破壊、Request変更・解除など、実fluidboxを参照できる場合は、実fluidbox内の流体を実温度のままStorageへ返却する。

事前削除イベントを通らずEntityが失われ、実fluidboxを参照できない場合は、`materialized` stateに記録されたname、amount、temperatureを使って可能な限りStorageへ復元する。

既存セーブで`storage.dimensional_storage.fluids[name] = amount`として保存されている流体は、Fluid Prototypeが存在する場合、そのPrototypeの`default_temperature`をtemperatureとして持つ新形式へ移行する。

旧`materialized` stateがtemperatureを持たない場合も、実Entityのfluidboxが参照できるときは実fluidboxのtemperatureを優先し、参照できない場合はFluid Prototypeの`default_temperature`で移行する。

---

## 18. Recipe・Technology

### 18.1 Item Port

初期開発およびテスト段階では、Item PortのCrafting Recipeを以下とする。

```text
鉄板 × 5
→ Dimensional Item Port × 1
```

このRecipeは暫定仕様である。

ゲームバランス調整および最終Recipeの決定は、基本機能の実装完了後に行う。

---

### 18.2 Fluid Port

初期開発およびテスト段階では、Fluid PortのCrafting Recipeを以下とする。

```text
鉄板 × 5
→ Dimensional Fluid Port × 1
```

このRecipeは暫定仕様である。

---

### 18.3 Dimensional Combinator

初期開発およびテスト段階では、Dimensional CombinatorのCrafting Recipeを以下とする。

```text
鉄板 × 1
→ Dimensional Combinator × 1
```

このRecipeは暫定仕様である。

専用Technologyは設けず、ゲーム開始時から利用可能とする。

---

### 18.4 Technology

初期実装では、Item Port、Fluid PortおよびDimensional Combinatorをゲーム開始時から利用可能とする。

専用Technologyによる研究解放は要求しない。

Technologyおよび研究コストについては、ゲームバランス調整時に将来的な変更を検討する。

## 19. 回路ネットワーク

Dimensional Storageの在庫を回路ネットワークへ出力する専用Entityとして、**Dimensional Combinator（次元コンビネータ）**を使用する。

Dimensional CombinatorはRead-Only専用とし、回路ネットワークからの入力によってDimensional Storage、Item Port、Fluid Port、Request設定を変更してはならない。

出力対象はItem、Item + Quality、Fluidとする。ItemはGUIと同じくDimensional Storage内数量とItem Portのmaterialized共有キャッシュを合算する。Quality違いは別信号とする。FluidはDimensional Storageに存在するFluid Prototypeごとのamountを出力し、temperatureは出力しない。

数量0以下は出力しない。Fluidの小数amountは回路信号化時に整数へ切り捨てる。int32上限を超える数量は2147483647へclampする。

複数設置されたDimensional CombinatorはSurfaceやPlanetに関係なく同一のグローバルDimensional Storageを参照する。更新周期は30 tickとし、実在するStorageエントリのみ走査する。同一内容はsignature比較で不要な再書き込みを避ける。

信号順序はGUIと同系統のPrototype順・Quality順で安定化する。一つのsectionに収まらない場合は`prototypes.utility_constants.max_logistic_filter_count`を上限として複数sectionへ分割する。`LuaLogisticSection::filters_count`は現在のfilter数であり容量ではないため、容量判定に使用しない。

vanilla constant combinator由来の編集GUIは開かせず、出力内容はMOD側が管理する。

---

## 20. 更新処理とUPS

UPS負荷を考慮し、すべての処理を毎tick実行することを前提としない。

基本更新周期は、

```text
30 tick
```

とする。

対象：

* RequestなしPortの吸収
* RequestありPortの補充
* Fluid Portの入出力

ただし、実際の性能測定によって更新方式を変更できるものとする。

多数のPortが存在する場合、一つのtickに全Portを集中処理することでtick spikeが発生する場合は、処理を複数tickへ分散する方式を検討する。

ゲーム上の動作仕様を維持できる限り、UPS負荷の低い実装を優先する。

---

## 21. 物資総量保存則

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
* 旧モードstateからの移行
* Port採掘
* Port破壊
* Entity削除
* Surface関連処理
* Quality変更を伴う処理

---

## 22. MODの世界観上の定義

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

* Requestなし：30 tickごとに内部在庫を全吸収
* Requestあり：30 tickごとに各要求アイテムを最大5スタックまで維持

というゲーム上の挙動として表現する。

---

## 23. 初回実装範囲

初回実装では以下を優先する。

* 単一のグローバルDimensional Storage
* Item Port
* 双方向Port
* RequestなしPortによるアイテム吸収
* Requestによる複数アイテム指定
* 各要求アイテム5スタック維持
* 複数Request指定Port間の公平配分
* Quality対応
* Request変更時の在庫返却
* Port撤去・破壊時の安全な在庫処理
* Dimensional Storage GUI
* アイコン＋数量表示
* アイテム検索

Fluid PortについてはItem Portの基本実装を基礎として実装する。

回路ネットワークからのRequest変更、Storage操作、条件制御は初回実装の対象外とする。

---

## 24. 未確定事項

以下は現時点では確定仕様としない。

* GUIの具体的な視覚レイアウト
* Item PortおよびFluid Portの最終的な専用グラフィック
* 最終的なCrafting Recipeおよびコスト
* 将来的なTechnologyおよび研究コスト
* 温度付き流体の具体的な内部表現
* 回路入力によるRequest変更、Storage操作、条件制御
* 大量Port設置時の具体的な更新分散アルゴリズム

これらは実装・性能測定・Factorio 2.0 API仕様確認を行った上で決定する。

未確定事項について、実装時に推測で恒久仕様を確定してはならない。
