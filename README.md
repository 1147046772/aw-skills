# aw-skills

团队共享的 Codex Skills 基础能力仓。仓库只维护可复用、与具体产品仓解耦的 Skill；项目适配器、场景目录、AppID、测试数据和运行证据继续留在各项目仓或本机受控目录中。

## 当前 Skill

| Skill | 版本 | 用途 |
| --- | --- | --- |
| `wechat-miniprogram-test` | `3.2.0` | 有界执行微信小程序测试、验证修复，并生成哈希绑定的证据与唯一测试回执 |
| `api-test` | `0.2.0-rc.2` | 有界执行 API 合同、运行时、权限、状态、幂等和集成测试，并生成哈希绑定的标准回执或项目原生叶证据 |

## 仓库结构

```text
aw-skills/
├── manifest.json
├── skills/
│   ├── api-test/
│   └── wechat-miniprogram-test/
├── scripts/
│   ├── Install-Skill.ps1
│   └── Test-Repository.ps1
└── .github/workflows/validate.yml
```

## 安装

克隆仓库后，在 PowerShell 7.4+ 中运行：

```powershell
pwsh ./scripts/Install-Skill.ps1 -Name wechat-miniprogram-test
pwsh ./scripts/Install-Skill.ps1 -Name api-test
```

安装器会先核对 `manifest.json` 中的内容摘要，且在目标目录已存在时拒绝覆盖。升级前请先审查版本差异，并自行备份或移除旧目录。

`api-test 0.2` 的稳定合同范围是 HTTP 与 OpenAPI 3.0/3.1 JSON，也支持显式列举、由项目负责真值的 `custom` 合同。项目必须自行提供 Adapter、目标 allowlist、鉴权 Profile、场景、fixture、runner 和当前运行身份；OpenAPI YAML（无固定解析器）、GraphQL、gRPC 与 WebSocket 不继承该保证并返回 `BLOCKED_UNSUPPORTED`。

`PROJECT_NATIVE_PARENT` 只生成可验证的 API 叶摘要，不取代项目现有父证据或治理清单。API 测试不会授权源码修改、未声明数据写入、生产访问、真实外部调用、发布或部署。

安装后重启 Codex，使新的用户级 Skill 被重新发现。

## 校验

```powershell
pwsh ./scripts/Test-Repository.ps1
```

校验覆盖清单结构、Skill 目录边界、内容摘要、敏感文件/明显 Secret 扫描，以及 Skill 自带的合同测试。GitHub Actions 会在 push 和 pull request 时执行同一入口。

## 协作约定

- 一个 Skill 一个目录，入口固定为 `skills/<skill-name>/SKILL.md`。
- 每次变更同步更新 `manifest.json` 的版本和 `contentSha256`。
- 通用 Skill 不接收项目私有场景、真实 AppID、Secret、生产数据或运行证据。
- 项目工作流通过固定版本或 commit SHA 消费；项目适配与授权边界由项目自己维护。
- 合并前必须通过 `scripts/Test-Repository.ps1`，并由另一位成员审查行为边界变化。
