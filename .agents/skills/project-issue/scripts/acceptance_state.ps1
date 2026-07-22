Set-StrictMode -Version Latest

function Get-ProjectIssueAcceptanceClassification
{
    param([Parameter(Mandatory = $true)][string]$Text)

    if ($Text -match "(?i)^\s*\[manual\](?:\s|$)")
    {
        return "manual"
    }

    [bool]$hasManualIntent = $Text -match
        "(?i)(手测|人工(?:验证|验收|测试|确认|签字)|截图|截屏|录像|录屏|screenshot|screen\s*(?:record|capture|recording)|video\s+recording|(?:attach|provide|capture)\s+(?:a\s+)?recording|human\s+verification|manual\s+(?:verification|test|check|sign-?off))"
    [bool]$hasAutomaticIntent = $Text -match
        "(?i)(自动|EditMode|Pester|CLI|编译|单元测试|集成测试|automated|automation|unit\s+test|integration\s+test)"

    if ($hasManualIntent -and $hasAutomaticIntent) { return "mixed" }
    if ($hasManualIntent) { return "manual" }
    return "automatic"
}

function Get-ProjectIssueAcceptanceState
{
    param(
        [AllowEmptyString()]
        [string]$Body = ""
    )

    [System.Text.RegularExpressions.Match]$section =
        [System.Text.RegularExpressions.Regex]::Match(
            $Body,
            "(?ms)^## Acceptance criteria\s*\r?\n(?<content>.*?)(?=^## |\z)")
    if (!$section.Success)
    {
        return [pscustomobject]@{
            provided = $false
            valid = $true
            status = "not_provided"
            total = 0
            checked = 0
            unchecked = 0
            fingerprint = ""
            items = @()
            matches = @()
            automaticCount = 0
            manualCount = 0
            mixedCount = 0
            pendingManualItems = @()
        }
    }

    [System.Text.RegularExpressions.MatchCollection]$checklistMatches =
        [System.Text.RegularExpressions.Regex]::Matches(
            $section.Groups["content"].Value,
            "(?m)^\s*-\s*\[(?<mark>[ xX])\]\s+(?<text>.+?)\s*$")
    if ($checklistMatches.Count -eq 0)
    {
        return [pscustomobject]@{
            provided = $true
            valid = $false
            status = "malformed"
            total = 0
            checked = 0
            unchecked = 0
            fingerprint = ""
            items = @()
            matches = @()
            automaticCount = 0
            manualCount = 0
            mixedCount = 0
            pendingManualItems = @()
        }
    }

    [System.Collections.Generic.List[object]]$items = [System.Collections.Generic.List[object]]::new()
    [System.Collections.Generic.List[string]]$canonicalItems = [System.Collections.Generic.List[string]]::new()
    [int]$checked = 0
    [int]$automaticCount = 0
    [int]$manualCount = 0
    [int]$mixedCount = 0
    [int]$index = 0
    foreach ($match in $checklistMatches)
    {
        $index++
        [bool]$isChecked = [string]$match.Groups["mark"].Value -match "[xX]"
        [string]$text = [string]$match.Groups["text"].Value
        [string]$classification = Get-ProjectIssueAcceptanceClassification -Text $text
        if ($isChecked) { $checked++ }
        switch ($classification)
        {
            "automatic" { $automaticCount++ }
            "manual" { $manualCount++ }
            "mixed" { $mixedCount++ }
        }
        $items.Add([ordered]@{
            index = $index
            checked = $isChecked
            text = $text
            classification = $classification
        })
        $canonicalItems.Add("$index`t$text")
    }

    [int]$unchecked = $checklistMatches.Count - $checked
    [byte[]]$fingerprintBytes = [System.Text.Encoding]::UTF8.GetBytes($canonicalItems -join "`n")
    [string]$fingerprint = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($fingerprintBytes)
    ).ToLowerInvariant()

    return [pscustomobject]@{
        provided = $true
        valid = $true
        status = if ($unchecked -eq 0) { "all_checked" } else { "unchecked" }
        total = $checklistMatches.Count
        checked = $checked
        unchecked = $unchecked
        fingerprint = $fingerprint
        items = $items.ToArray()
        matches = @($checklistMatches)
        automaticCount = $automaticCount
        manualCount = $manualCount
        mixedCount = $mixedCount
        pendingManualItems = @($items | Where-Object {
            ![bool]$_.checked -and [string]$_.classification -in @("manual", "mixed")
        })
    }
}
