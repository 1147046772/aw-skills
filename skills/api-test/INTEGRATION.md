# 通用 API 测试 Skill 接入

项目长期维护 Adapter、Contract Manifest、Operation Index、Catalog、Scenario 和 runner；每次运行在实际服务启动后生成 Current Attestation 和 Request，为每个已尝试场景生成 Evidence，最后生成 Generic Receipt 或 Project Native Leaf Summary。全局 Skill 不保存项目路由、角色、fixture 或凭据。

推荐项目结构：

```text
project-root/
  .api-test/
    project.json
    catalog.json
    contract-manifest.json
    operation-index.json
    traceability.json            # 可选
    source-identity.json
    service-identity.json
    scenarios/
    runner/
  .local/evidence/api-tests/<runId>/
    current-attestation.json
    test-request.json
```

`.api-test/` 可版本化；`.local/evidence/` 应排除版本控制。Adapter 可位于 workspace 内部目录，`roots.workspace` 只允许 `.` 或最多四层明确父目录，解析后必须是包含 Adapter 的物理工作区。其余所有路径相对 workspace；`evidenceRoot` 是证据监狱，Request 输出目录必须在其内且是唯一、禁止覆盖的 run 子目录。

接入顺序：

1. 只读检查项目治理、现有 runner、API 契约、环境身份方式和最终测试摘要所有权。
2. 建立 Adapter 的精确 `destinations[]` 和 `contracts[]`，不写真实密钥、机器绝对路径或业务预期。
3. OpenAPI 3.0/3.1 JSON 使用 `scripts/new-openapi-contract.ps1` 一次生成确定性 Contract Manifest 和 Operation Index；YAML 在未声明锁定解析器前必须 `BLOCKED`。再建立完整 Catalog 和至少一个只读 Scenario，绑定精确文件哈希。
4. 运行 `scripts/test-contract.ps1` 验证 Skill 自身。
5. 验证项目 PASS、FAIL、BLOCKED 三类 child evidence。
6. 启动实际目标后采集 Current Attestation，再生成最终 Request；运行后重新采集并使用 `-RequireCurrentIdentity` 比对。
7. `GENERIC_CANONICAL` 项目由生成器产出唯一 Receipt；已有治理父摘要的项目由 `new-native-leaf-summary.ps1` 产出叶摘要，再由项目父清单映射。

已有严格项目治理时，应保持项目原生执行和父摘要链路。通用字段映射到项目的候选、环境、测试边界、必需叶节点和子回执；运行检查继续由项目 Adapter 声明实际服务、镜像或进程身份及健康契约。通用 Skill 不替换项目 runner，也不生成第二份最终摘要。

最低验收包括：合法只读场景通过；预期错误响应可 PASS；2xx 业务错误可 FAIL；生产伪装、目标/重定向漂移、OpenAPI 或引用文件篡改、Operation 缺失或重复、POST 错标只读、写 poll、未声明外部调用、镜像/容器身份不符、旧 Request 复用、未知写结果、未脱敏证据和重复父摘要均被拒绝。

通用接入按实施批次组织，不占用项目自己的治理阶段名称：A 为边界和 Adapter，B 为合同与身份，C 为 Scenario/runner，D 为正反验证和父证据映射，E 为 CI/治理消费。所有实际修改仍必须落在项目授权的实施阶段内。
