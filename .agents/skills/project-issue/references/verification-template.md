# Verification record

把下列结构写入仓库外临时 JSON，并以实际值替换示例。`complete_issue.ps1` 会校验 WorkContext/HEAD 绑定、测试、review 历史、AC 与风险，不接受缺字段或互相矛盾的记录。

```json
{
  "parent": 285,
  "issue": 291,
  "base": "40-char BASE sha",
  "head": "40-char final HEAD sha",
  "tests": [
    {
      "name": "project-issue full Pester",
      "command": "Invoke-Pester -Path .agents/skills/project-issue/scripts/tests -PassThru",
      "mode": "CLI",
      "exitCode": 0,
      "total": 1,
      "passed": 1,
      "failed": 0,
      "skipped": [],
      "reportPath": "pester://project-issue/full",
      "runId": "final-full-1",
      "head": "40-char final HEAD sha"
    }
  ],
  "reviews": {
    "head": "40-char final HEAD sha",
    "initialHead": "40-char initial review sha",
    "initialStandards": "PASS",
    "initialSpec": "PASS",
    "finalStandards": "PASS",
    "finalSpec": "PASS",
    "repairRounds": []
  },
  "acceptance": {
    "provided": true,
    "total": 1,
    "checked": 1,
    "unchecked": 0,
    "fingerprint": "64-char acceptance fingerprint",
    "automatedSatisfied": []
  },
  "unexecuted": [],
  "risks": ["none"]
}
```

每个 repair round 必须包含：`round`、`amended=true`、不同的 `beforeHead/afterHead`、布尔 `codeChanged/testsChanged`、`retestRunId`、`standards/spec`、`findings`。未勾选的 mixed AC 必须在 `automatedSatisfied` 中按 AC index 指向一条当前 HEAD 上通过的 `testRunId` 并提供非空 evidence。人工 AC 不放入该数组，完成入口会保留其 checkbox 并记录为 pending manual。
