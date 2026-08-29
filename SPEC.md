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

Item Portは、工業的な拘束装置の中央に黒い次元裂孔と白い空間歪みを持つデザインとする。

単なる魔法陣や自然発生した穴ではなく、暗鉄色・黒鉄色・暗赤色の機械フレーム、固定装置、ボルト、警告光などによって、異常な次元現象をFactorio的な工業設備で拘束している外観とする。

黒い裂孔と白い歪みは異なる速度でアニメーションし、可能であれば逆方向の回転感を持たせる。

Item Portは固体物質を転送する装置として、裂孔周辺に小さな固体片、金属片、角張った粒子などを控えめに配置する。

ただし多数設置時のUPSを考慮し、アニメーションはcontrol stageで駆動せず、FactorioのPrototype graphics機能で表現可能な範囲に限定する。

外観の変更によって、Item Portの基本機能・保存データ・設置済みEntityとの互換性を不必要に損なわない設計とする。

---

### 3.3 Inventory

Item Portの内部Inventoryサイズは、通常の鋼鉄チェストと同等とする。

初期実装では、vanillaの鋼鉄チェストに準拠したInventory容量を使用する。

このInventoryは以下の用途に使用する。

* Supplyモードで、外部から投入されたアイテムをDimensional Storageへ送るまでの一時バッファ
* Requestモードで、Dimensional Storageから実体化したアイテムを外部へ取り出すための一時バッファ

Dimensional StorageそのものをItem PortのInventoryへ保持してはならない

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

### 5.2 最大要求アイテム数

一つのItem Portで同時に指定可能な要求アイテム数は、最大9種類とする。

Item Portの内部Inventoryは48スロットであり、各要求アイテムについて5スタック分を維持するため、

5スタック × 9種類 = 45スロット

を最大要求数とする。

残り3スロットについては、要求アイテム数の追加には使用しない。

要求アイテム数が9種類を超える設定は許可しない。

各要求スロットでは、アイテムおよび品質を指定できる。

要求スロットは最大9スロットの固定位置として扱う。

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

Requestモードでは、外部からItem Port内部Inventoryへのアイテム投入を受け付けない。

Requestモードの内部Inventoryは、Dimensional Storageから実体化された要求アイテムを保持し、インサータ、ローダー、プレイヤー等によって外部へ取り出すためのバッファとして使用する。

要求対象外のアイテムによって内部Inventoryが占有され、各要求アイテムの5スタック維持が妨げられる状態を許可しない。

初期実装では、FactorioのContainer Prototypeで利用可能なfilter付きInventoryを使用し、Requestモード時は要求アイテムおよび品質に対応するslot filterを設定する。

Factorioの通常Container Inventoryで「外部からの投入だけを完全禁止し、取り出しは許可する」ことをPrototype設定のみで完全保証できない場合、slot filterおよび定期更新時の混入検出・Dimensional Storage返却によって、要求対象外アイテムまたはmaterialized数を超える投入分がバッファを占有し続けないようにする。

この場合も、外部から混入した物資を消滅させず、Dimensional Storageへ返却することを優先する。

MODはRequest Portごとに、Dimensional Storageから実体化して内部Inventoryへ供給したアイテム数量を、アイテムおよび品質ごとに永続stateとして記録する。

この記録は、Request Port内部に存在する物資がDimensional Storage由来であるかを判定し、Request設定変更、モード変更、Port撤去・破壊、外部からの混入検出時に物資総量保存則を維持するために使用する。

この記録はDimensional Storageそのものではなく、Port内部Inventoryに実体化している数量を追跡するための補助stateである。

Request Port内部の実体化済みアイテムは、そのPortが恒久的に所有する在庫ではなく、Dimensional Storageから一時的に通常空間へ実体化された共有キャッシュとして扱う。

実体化済みアイテムは、Portからインサータ、ローダー、プレイヤー等によって外部へ取り出されるまでは、同一アイテムおよび品質を要求する他のRequest Portへ再配分可能とする。

再配分対象として扱う数量は、Port内部Inventory内の全数量ではなく、`materialized` stateに記録され、かつ実Inventory内に存在している数量に限る。

外部から混入したアイテムを、共有キャッシュとして勝手に再配分してはならない。

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

アイテムのように整数単位で配分する物資について、在庫がRequest Port数より少ない場合でも、同じPortだけが恒常的に優先されてはならない。

割り切れない余りは、同一アイテムおよび品質ごとに次回以降の配分開始位置をずらしながら配分する。

流体については、不足量を上限として可能な限り直接均等に配分する。

同一アイテムおよび品質を要求するRequest Portの集合が変化した場合、既に各Request Portへ実体化されている共有キャッシュも含めて、必要に応じて公平に再平衡する。

再平衡では、Dimensional Storage内数量と各Request Portの`materialized`数量を共有可能総量として扱い、各Request Portの5スタック上限を超えない範囲で望ましい割当量を計算する。

割当量を超えて保持しているPortからは、超過分のみをInventoryから回収してDimensional Storageへ返却し、その後、不足しているPortへDimensional Storageから実体化する。

再平衡は必ず回収と再実体化の二段階で行い、Port間で直接Inventoryを移動しない。

通常の30 tick補充処理ごとに既存の`materialized`在庫を再平衡してはならない。

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

RequestからSupplyへ変更する場合、Request用内部バッファに残っている物資をDimensional Storageへ返却する。

SupplyからRequestへ変更する場合も、変更時点で内部Inventoryに残っているアイテムについて適切にDimensional Storageへ格納し、アイテムの消失または複製が発生しないようにする。

モード変更によって物資総量が変化してはならない。

---

## 12. Entity破壊・撤去

Dimensional Portが撤去・破壊された場合、内部Inventoryまたはfluidboxに残っている内容物を、そのモードおよび由来に応じて安全に処理する。

RequestモードでDimensional Storageから実体化された物資はDimensional Storageへ返却する。

SupplyモードでまだDimensional Storageへ吸収されていない物資については、通常のEntity撤去・破壊時の挙動を尊重し、不当にDimensional Storageへ送信したり消失させたりしてはならない。

Portの撤去・破壊によってアイテムまたは流体の複製・不当な消失が発生してはならない。

通常のプレイヤー操作による採掘だけでなく、Entity死亡、スクリプトによる削除等についても考慮する。

通常の事前削除イベントを通らずPort Entityが無効化された場合でも、Request Portについては永続stateに記録された実体化済み数量をDimensional Storageへ返却し、総量保存則を可能な限り維持する。

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

#### モード

```text
[ Supply ] [ Request ]
```

#### Request設定

Requestモードの場合のみ表示する。

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

要求スロットは9列で表示し、初回実装での最大要求数9種類を1行に収める。

```text
[鉄板] [銅板] [電子基板] [+]
```

要求数量は指定しない。

#### Dimensional Storage

現在Dimensional Storageに存在するアイテムを、**アイコン + 数量**形式で一覧表示する。

Item PortのGUIでは、すべてのRequest Portが保持している実体化済みバッファ分も、Portから取り出し可能な在庫として一覧数量へ含める。

この表示上の合算はGUI上の見やすさのためのものであり、Dimensional Storage内数量そのものを増減させるものではない。

GUIを開いている間、Dimensional Storage一覧は基本更新周期である30 tickごとに最新の数量へ更新する。

30 tickごとの通常更新では、表示対象のアイテム・品質・流体の構成が変わっていない場合、既存GUI要素の数量およびTooltipのみを更新する。

GUI一覧の全再構築は、GUIを開いた直後、検索文字列が変化した場合、表示対象の構成が増減した場合、または検索結果に影響するローカライズ名が更新された場合に限定する。

Factorioの物流ネットワーク在庫表示に近い形式を使用する。

アイテムおよび流体の数量は、通常のFactorioアイコン表示に近い形で、アイコンタイルの右下に表示する。

Dimensional Storage一覧は9列で表示し、表示領域を超える場合はスクロールによって全項目を確認できるようにする。

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

---

### 14.2 GUIレイアウト

GUIの具体的な配置、各要素のサイズ、列数、スクロール領域等については、初期実装後に実際のゲーム画面上で操作性を確認しながら調整する。

現時点では以下の機能要件のみを固定する。

* Supply / Requestモード切替
* Requestモード時の要求アイテム指定
* Dimensional Storage内のアイテム一覧
* アイコンおよび数量表示
* アイテム検索

GUIの視覚的な配置について、SPECに記載されていない部分を実装上の恒久仕様として扱わない。

ウインドウを閉じるボタンは、Factorio標準GUIに近い操作感になるよう、ウインドウ右上へ配置する。

---

## 15. アイテム検索

Dimensional Storage一覧には検索機能を設ける。

検索文字列に一致するアイテムのみを表示できるようにする。

検索UIは、バニラの検索機構を直接再利用できない場合でも、Factorio標準GUIに近い見た目・操作性を持つ自前検索として実装する。

検索対象は、Dimensional Storageに実際に存在するアイテム・流体、およびRequest Port内に実体化している表示対象のアイテムのみとする。

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

Fluid Portは一つのEntity Prototypeを使用し、各設置個体について以下のモードを切り替える。

* `Supply`
* `Request`

---

### 16.2 Entityサイズ・外観

Fluid PortのEntityサイズは **1×1 tile** とする。

Fluid PortはItem Portと同一系列の設備として、赤黒い工業フレーム、中央の黒い次元裂孔、白い空間歪みを共有するデザインとする。

Fluid Port固有の要素として、Pipe接続部、液滴、波紋、曲線的な流線などを使用し、液体が裂孔へ吸い込まれる装置として表現する。

Pipe接続部はFactorio上で接続方向が分かりにくくならないよう、中央の裂孔演出で隠さず視認可能にする。

黒い裂孔と白い歪みは異なる速度でアニメーションし、可能であれば逆方向の回転感を持たせる。

ただし多数設置時のUPSを考慮し、アニメーションはcontrol stageで駆動せず、FactorioのPrototype graphics機能で表現可能な範囲に限定する。

---

### 16.3 Fluidbox容量

Fluid Portのfluidbox容量は、

**25,000 fluid**

とする。

この容量はSupplyおよびRequestの両モードで共通とする。

---

### 16.4 Supply

Supplyモードでは、Fluid Portへ流入した流体をDimensional Storageへ吸収する。

処理周期は原則として、

**30 tickごと**

とする。

処理時点でFluid Portのfluidboxに存在する流体を、数量にかかわらず可能な限りすべてDimensional Storageへ移動する。

吸収後、その数量をFluid Portのfluidboxから削除する。

Dimensional Storageへ保存した数量とfluidboxから削除した数量は必ず一致させ、流体の複製または消失を発生させてはならない。

---

### 16.5 Request

Requestモードでは、一つのFluid Portにつき一種類の流体を指定する。

複数種類の流体を同一Fluid Portから同時に出力してはならない。

30 tickごとに、指定流体についてfluidboxの不足量を計算し、最大容量である25,000まで維持する。

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

新たな流体がSupply PortからDimensional Storageへ追加された場合、以後の更新で再び補充する。

同一流体を複数のRequest Fluid Portが要求しており、すべてのPortの不足量を満たすだけのDimensional Storage在庫が存在しない場合、利用可能な流体を各Portの不足量を上限として可能な限り均等に配分する。

Entityの処理順によって、先に処理されたFluid Portだけが在庫を取得する仕様にしてはならない。

---

## 17. 流体温度

温度が異なる同一流体については、将来的には異なる状態として扱うことを基本方針とする。

ただし、温度付き流体の具体的な保存方式、取り出し方式およびGUI仕様は現時点では未確定である。

初回実装では、温度差を持つ流体の完全な保存・復元対応は実装対象外とする。

温度依存流体について不正確な温度変換、意図しない混合、流体生成が発生する可能性がある場合、その流体を安全に処理できない状態として扱い、推測による変換処理を実装してはならない。

温度付き流体への正式対応は、Factorio 2.0のFluid APIおよび実際のゲーム挙動を確認したうえで別途仕様を確定する。

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

### 18.3 Technology

初期実装では、Item PortおよびFluid Portをゲーム開始時から利用可能とする。

専用Technologyによる研究解放は要求しない。

Technologyおよび研究コストについては、ゲームバランス調整時に将来的な変更を検討する。

## 19. 回路ネットワーク

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

## 20. 更新処理とUPS

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
* モード変更
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

* Supply：30 tickごとに内部在庫を全吸収
* Request：30 tickごとに各要求アイテムを最大5スタックまで維持

というゲーム上の挙動として表現する。

---

## 23. 初回実装範囲

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

## 24. 未確定事項

以下は現時点では確定仕様としない。

* GUIの具体的な視覚レイアウト
* Item PortおよびFluid Portの最終的な専用グラフィック
* 最終的なCrafting Recipeおよびコスト
* 将来的なTechnologyおよび研究コスト
* 温度付き流体の具体的な内部表現
* 回路ネットワーク対応方式
* 大量Port設置時の具体的な更新分散アルゴリズム

これらは実装・性能測定・Factorio 2.0 API仕様確認を行った上で決定する。

未確定事項について、実装時に推測で恒久仕様を確定してはならない。
