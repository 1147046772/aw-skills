# 通用微信小程序测试 Skill 工作流接入指南

本指南用于把 `wechat-miniprogram-test` 作为独立测试能力接入任意项目或交付工作流。它只定义测试输入、执行边界和测试凭证，不替代项目的需求、开发、缺陷、发布或部署流程。

## 1. 接入后的稳定接口

工作流只依赖以下接口：

```text
项目长期维护
  project adapter
  test catalog
  scenario definitions
  project runners

每次测试生成
  test-request.json
      ↓
  evidence.json × 已执行场景
      ↓
  test-receipt.json × 1
```

输入和输出职责：

| 对象 | 产生方 | 作用 |
|---|---|---|
| Project Adapter | 项目 | 声明项目路径、候选身份方法、允许通道、runner 和证据根目录 |
| Test Catalog | 项目 | 登记完整活动场景、精确文件哈希和上下游关系 |
| Scenario | 项目 | 定义页面、前置条件、步骤、断言、影响键、权限和证据要求 |
| Test Request | 调用工作流 | 冻结候选、环境、授权、模式、选择边界、预算和输出目录 |
| Scenario Evidence | runner/控制器 | 记录一个场景本次实际执行和观察结果 |
| Test Receipt | Skill 生成器 | 唯一汇总 verdict、closure、coverage、finding、blocker、hash 和 freshness |

工作流不得创建第二份“权威测试总结”。需要人类报告时，只摘要并引用 canonical receipt。

## 2. 共享安装

将完整 Skill 目录安装一次，不要复制到每个项目：

```text
$CODEX_HOME/skills/wechat-miniprogram-test/
  SKILL.md
  agents/
  references/
  scripts/
```

Windows 默认位置通常是：

```text
C:\Users\<user>\.codex\skills\wechat-miniprogram-test
```

安装要求：

- 整个目录原样复制，不能只复制 `SKILL.md`；
- 使用 PowerShell 7.4 或更高版本执行随包脚本；
- 自动发现保持开启，也可以显式调用 `$wechat-miniprogram-test`；
- CLI、MCP、Automator、项目 runner 或真机能力由项目 Adapter 声明，Skill 不假定某一种通道必然存在。

## 3. 项目侧最小目录

推荐结构：

```text
project-root/
  .wechat-test/
    project.json
    catalog.json
    source-identity.json
    scenarios/
      login.json
      home.json
    runner/
      run-test.js
  .local/
    evidence/
      wechat-tests/
  project.config.json
  ...
```

约束：

- `.wechat-test/` 保存可版本化的测试事实；
- `.local/evidence/wechat-tests/` 保存运行产物，应排除版本控制；
- Adapter 可位于 `.wechat-test/project.json`，此时 `roots.workspace` 可使用 `..`；
- 所有其他路径都相对解析后的 workspace；
- 路径中不得存在 junction、symlink 或 reparse point；
- 证据目录必须是唯一、非覆盖的请求子目录。

## 4. 项目 Adapter

Adapter 遵循 `references/project.schema.json`，当前 schema 版本为 `2.0`。它只描述测试机械事实，不定义产品预期，也不授予测试权限。

示意结构：

```json
{
  "schemaVersion": "2.0",
  "adapterVersion": "1.0.0",
  "adapterId": "sample-mini-adapter",
  "projectId": "sample-mini",
  "framework": "native-wechat",
  "roots": {
    "workspace": "..",
    "source": "miniprogram",
    "devtoolsProject": "miniprogram"
  },
  "files": {
    "projectConfig": "miniprogram/project.config.json",
    "packageManifest": "miniprogram/package.json",
    "scenarioRoot": ".wechat-test/scenarios"
  },
  "candidateIdentity": {
    "method": "git-manifest-sha256",
    "definitionRef": ".wechat-test/source-identity.json",
    "command": null
  },
  "runners": [],
  "supportedChannels": ["wechatide-mcp"],
  "capabilities": ["runtime-read", "page-query"],
  "evidenceRoot": ".local/evidence/wechat-tests",
  "secretEnvKeys": []
}
```

接入方必须替换示意值，并确保：

- `adapterId` 和 `adapterVersion` 稳定；
- `candidateIdentity` 覆盖会影响小程序行为的源码、配置和构建输入；
- runner 使用参数数组，不拼接 shell 命令；
- runner 能力、测试类型和通道覆盖对应 Scenario；
- Adapter 不包含密钥、Cookie、登录票据或机器绝对路径。

## 5. 场景和 Catalog

Scenario 遵循 `references/scenario.schema.json`，当前版本为 `4.0`。每个场景至少包含一个 `REQUIRED` 断言。

每个场景必须明确：

- 稳定 `id` 和 `scenarioVersion`；
- 测试类型和唯一运行通道；
- 允许进入的页面；
- 业务会话要求；
- 前置条件和 fixture；
- 最小权限；
- 语义化步骤和可观察等待；
- REQUIRED/ADVISORY 断言；
- 每个断言覆盖的 typed impact keys；
- 需要保存的证据类型；
- 停止条件和时间预算。

不要使用坐标点击、任意 sleep 或“页面看起来正常”作为验收合同。

Catalog 遵循 `references/test-catalog.schema.json`，当前版本为 `1.0`。它必须：

- 列出全部活动场景；
- 保存每个场景精确文件 SHA-256；
- 使用稳定场景 ID；
- 只声明真实的上下游关系；
- 关系 impact keys 必须由两端场景共同声明。

Catalog 不完整时不得声明全量测试通过。

## 6. Runner 和控制通道

每个场景只能绑定一个通道：

| 通道 | 适用范围 | runnerId |
|---|---|---|
| `none` | static/compile/unit/component/integration 项目进程 | 必填 |
| `automator` | 使用项目声明的自动化 runner | 通常必填 |
| `wechatide-mcp` | MCP 直接控制或 MCP runner | 直接控制时可为 `null` |
| `human` | 明确声明的人工观察 | 可为 `null` |
| `device` | 真机或设备云专属断言 | 可为 `null` 或项目 runner |

Runner 的持久输出必须是符合 `evidence.schema.json` 的 `evidence.json`。stdout、日志和退出码只能作为诊断，不能直接决定 PASS/FAIL/BLOCKED。

Runner 参数只允许以下精确 token：

```text
{workspace}
{requestPath}
{scenarioPath}
{evidencePath}
{artifactRoot}
```

不得把 token 插入更大的字符串，不得在通道失败后静默切换到其他控制器。

## 7. 每次运行的 Test Request

Request 遵循 `references/test-request.schema.json`，当前版本为 `3.1`。调用工作流应生成它，不应由测试执行器在运行中修改。

必须冻结：

- `requestId`、`runId`、`requestedAt`；
- Adapter 路径、版本和 SHA-256；
- candidate revision、diff hash、source hash、build ID；
- environment、AppID、API identity、config hash；
- run mode 和可选 defect lineage；
- Catalog 路径、版本和 SHA-256；
- FULL/IMPACT 策略、影响键、遍历深度和选中场景；
- 本次测试权限；
- 时间、并发和重试预算；
- 唯一输出目录。

`authorizationRef` 是调用方提供的非空审计引用。通用 Skill 会把它绑定进 request hash 并执行权限交集校验，但不会替调用方判断外部授权系统的真实性。

`candidate.sourceHash` 必须由项目声明的候选身份方法计算，不能人工填写一个固定值。执行前后候选变化时必须停止本次运行并创建新 request。

每次运行使用新目录：

```text
.local/evidence/wechat-tests/<runId>/
  test-request.json
  <scenarioId>/
    evidence.json
    artifacts/...
  test-receipt.json
```

## 8. 标准执行链

### 8.1 冻结并验证输入

```powershell
$skillRoot = 'C:\Users\<user>\.codex\skills\wechat-miniprogram-test'
$adapterPath = 'C:\path\to\project\.wechat-test\project.json'
$requestPath = 'C:\path\to\run\test-request.json'

& "$skillRoot\scripts\validate-contract.ps1" `
  -ProjectAdapterPath $adapterPath `
  -RequestPath $requestPath

if (-not $?) { throw 'Invalid mini-program test input; do not execute.' }
```

验证器输出计算后的 `selectedScenarioIds`、`excludedScenarioIds` 和 `reasonByScenario`。执行器必须使用这个冻结边界，不能自行加减场景。

### 8.2 执行并写场景证据

按选中顺序执行。`FIX_VERIFICATION` 先执行历史失败场景；若仍失败，可停止剩余闭包。

每个已执行场景写一个 schema `3.2` 的 `evidence.json`，至少包含：

- 本次 request/candidate/environment/scenario 哈希身份；
- 实际开始、结束和持续时间；
- 实际使用的 channel、runner/controller 和 session fingerprint；
- 实际观察页面 `scope.observedPages`；
- 前置条件、步骤和所有断言结果；
- finding fingerprint；
- artifact 路径、SHA-256、大小和修改时间；
- 数据变更与最终 resolution；
- BLOCKED 时的 blocker 和下一步。

即使前置条件阻塞，也要为实际尝试的场景输出 BLOCKED evidence；不要伪造未执行场景的 evidence。

### 8.3 生成唯一回执

```powershell
$evidencePaths = @(
  'C:\path\to\run\login\evidence.json',
  'C:\path\to\run\home\evidence.json'
)

& "$skillRoot\scripts\new-test-receipt.ps1" `
  -ProjectAdapterPath $adapterPath `
  -RequestPath $requestPath `
  -EvidencePath $evidencePaths `
  -FreshForSeconds 3600

if (-not $?) { throw 'No canonical mini-program test receipt was produced.' }
```

不要手工构造 `test-receipt.json`。生成器负责计算：

- PASS/FAIL/BLOCKED；
- run outcome 和 defect closure；
- executed/untested/excluded；
- assertion counts；
- findings 和 blockers；
- 页面和 impact-key coverage；
- mutation resolution；
- freshness 和 invalidation keys。

`freshness.class` 不能由调用者指定。生成器按运行事实唯一推导：无会话/无 mutation 为 `DETERMINISTIC`，仅会话为 `SESSION_BOUND`，仅 mutation 为 `LIVE_MUTABLE`，两者都有为 `MIXED`。调用者只能通过 `FreshForSeconds` 缩短或设置非确定性证据的有效时长，不能把会话或可变数据证据降级为永久有效。

### 8.4 重新验证回执

```powershell
$receiptPath = 'C:\path\to\run\test-receipt.json'

& "$skillRoot\scripts\validate-contract.ps1" `
  -ProjectAdapterPath $adapterPath `
  -RequestPath $requestPath `
  -ReceiptPath $receiptPath `
  -RequireFresh

if (-not $?) { throw 'Reject invalid or stale mini-program test evidence.' }
```

工作流只有在这一步成功后才可以消费回执。

### 8.5 复核当前现场身份

`-RequireFresh` 不是外部现场探针。它验证文件哈希、合同交叉一致性、artifact、运行事实、有效期和 invalidation keys，但不会主动执行项目的 `candidateIdentity.command`、读取当前 AppID/环境配置或查询当前 DevTools 会话。

需要“回执仍对应当前现场”的工作流，应在以下边界调用项目自己的只读身份提供器并与 Request/Receipt 比较：

```text
生成 Request 时
Runner 启动前
Runner 结束后
最终消费 Receipt 前
```

至少复核：

- 当前 candidate source hash；
- 当前构建身份；
- 当前 AppID；
- 当前环境/API/config hash；
- 会话型运行的当前 session fingerprint。

任一变化都使旧运行不可继续或旧回执不可复用。此复核接口属于调用工作流，因为通用 Skill 无法知道每个项目如何取得可信现场身份。

## 9. 工作流消费规则

消费顺序固定为：

```text
validator exit status
    ↓ valid
authority == TEST_EVIDENCE_ONLY
    ↓
receipt.result.verdict
    ↓
outcome / closure / findings / blockers / coverage / freshness
```

| 状态 | 工作流含义 |
|---|---|
| Validator 非零 | 没有可信测试结论；拒绝回执 |
| `PASS` | 仅证明 selected boundary 在绑定身份和有效期内通过 |
| `FAIL` | 存在 REQUIRED 产品断言失败；按 finding fingerprint 建立或关联缺陷 |
| `BLOCKED` | 测试无法完成或证据不可信；按 blocker.nextStep 解决后创建新运行 |
| Receipt 过期 | 原结论不可复用；按同一或更新后的 request 重新执行 |

不得：

- 只读取 `result.verdict` 而跳过 validator；
- 把 BLOCKED 当作产品 FAIL；
- 把 TARGETED PASS 表述为全量 PASS；
- 把回执当作源码修改、上传、发布或部署授权；
- 从失败回执自动执行无限重试。

## 10. 多轮缺陷闭环

推荐状态链：

```text
发现失败
  BASELINE / TARGETED
      ↓ findingFingerprint
首次复现
  DEFECT_REPRODUCTION + parent receipt 或 external evidence
      ↓ 修复形成新 candidate
修复验证
  FIX_VERIFICATION + immediate parent receipt
      ↓
缺陷场景 → 共享影响场景 → 上下游闭包
```

每一轮都必须使用：

- 新 `requestId` 和 `runId`；
- 新输出目录；
- 当前候选身份；
- immediate parent receipt 的精确路径和 SHA-256；
- 由当前 Catalog 重新计算的 IMPACT 闭包。

`FIX_VERIFICATION` 先运行历史失败断言：

- 仍失败：`DEFECT_REPRODUCED / OPEN`，可停止剩余下游测试；
- 已通过：继续执行共享影响和上下游闭包；
- 出现新 REQUIRED 失败：`REGRESSION_FOUND / PARTIAL`；
- 全部通过且无 blocker、无未解决 mutation：`FIX_VERIFIED / CLOSED`。

不要因为进入修复轮次就自动全量测试。只有影响边界未知、Catalog 过期、公共基础变化、测试基础设施变化、多域变化、发布基线或明确策略要求时使用 FULL。

## 11. Schema 版本

| 合同 | 当前版本 |
|---|---|
| Project Adapter | `2.0` |
| Test Catalog | `1.0` |
| Scenario | `4.0` |
| Test Request | `3.1` |
| Scenario Evidence | `3.2` |
| Test Receipt | `3.2` |

从证据/回执 3.1 升级到 3.2 时必须补充：

- `evidence.scope.observedPages`；
- `evidence.runtime.sessionFingerprint`；
- `evidence.mutations[].resolution`；
- `receipt.runtimeProfiles[].sessionFingerprint`；
- 顶层 `receipt.blockers`。

## 12. 最低接入验收

先运行 Skill 自身的可执行合同测试：

```powershell
& "$skillRoot\scripts\test-contract.ps1"
```

测试在系统临时目录创建隔离 fixture，验证完成后按已校验路径清理，不读取或修改产品项目。

正式接入前至少验证：

正向：

- 合法 Adapter、Catalog、Scenario 和 Request 可通过输入校验；
- runner 能产生合法 PASS evidence；
- 生成器能产出并复验 PASS receipt；
- runner 能产生合法 FAIL evidence 和 finding；
- runner 能产生合法 BLOCKED evidence，回执正确聚合 blocker。

拒绝：

- Adapter/request/catalog/scenario 哈希不一致；
- 选中场景不等于计算出的 IMPACT 闭包；
- Scenario 权限超过 Request；
- 未声明 runner、通道或能力；
- junction、symlink、相对路径逃逸；
- 会话通道没有 session fingerprint；
- observedPages 包含未声明页面；
- artifact 哈希、大小、修改时间不一致；
- PASS 存在未执行场景、未覆盖 REQUIRED impact 或 blocker；
- FAIL 没有 REQUIRED 失败断言；
- BLOCKED 没有 blocker；
- receipt 已过期或被修改；
- receipt finding、blocker、coverage 或 mutation 与子证据不一致。

## 13. 给项目智能体的标准提示词

```text
使用 $wechat-miniprogram-test 执行本次微信小程序测试。

输入：
- Project Adapter: <absolute-path>
- Test Request: <absolute-path>
- 测试目标: <本次业务/缺陷目标>

要求：
1. 先运行 validate-contract.ps1，输入无效立即停止。
2. 只执行验证器确认的 selectedScenarioIds，不扩展页面、账号、角色、场景或控制通道。
3. 使用每个 Scenario 声明的唯一 runner/channel，禁止静默降级。
4. 每个实际执行场景生成一个 schema 3.2 evidence.json。
5. 不得手写回执；使用 new-test-receipt.ps1 生成唯一 test-receipt.json。
6. 使用 validate-contract.ps1 -RequireFresh 复验回执。
7. 最终只报告 canonical receipt 中的 verdict、outcome/closure、selected/executed/excluded、findings、blockers、coverage、hash、freshness 和一个下一步。
8. 测试不授权修改源码、切换账号、扩大数据写入、上传、发布或部署。

若缺少权限、工具、会话、fixture、设备或可信证据，输出 BLOCKED evidence 和具体 nextStep，不得伪造 PASS/FAIL。
```

## 14. 接入完成定义

只有同时满足以下条件才算接入完成：

- Skill 以共享方式可被 `$wechat-miniprogram-test` 发现；
- 项目存在通过 schema 和交叉校验的 Adapter、Catalog 与至少一个 Scenario；
- 候选身份可重复计算；
- 至少一个声明通道能稳定产生 schema 3.2 evidence；
- PASS、FAIL、BLOCKED 三类回执均经过生成器和 validator 验收；
- 工作流只消费 fresh canonical receipt；
- 所有证据保存在唯一非覆盖目录；
- 测试回执不会被解释为后续动作授权。
