#
# benchmark.ps1 をモックのOllama APIに対して実行して結果を確認する。
# Usage: pwsh tests/benchmark-ollama-llm/test-benchmark.ps1 [-Shell powershell]
#
param(
    # benchmark.ps1 を実行するシェル（pwsh / powershell）
    [string]$Shell = "pwsh",

    [int]$Port = 11437
)

$ErrorActionPreference = "Stop"

$script = Join-Path $PSScriptRoot "../../skills/benchmark-ollama-llm/scripts/benchmark.ps1"
$ollamaHost = "http://127.0.0.1:$Port"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
$log = Join-Path $tmp "requests.jsonl"

$python = if ($env:OS -eq "Windows_NT") { "python" } else { "python3" }
$mock = Start-Process -FilePath $python `
    -ArgumentList @((Join-Path $PSScriptRoot "mock_ollama.py"), $Port, $log) `
    -PassThru -NoNewWindow

$script:failures = 0

function Test-Case {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Output "ok   - $Name"
    }
    else {
        Write-Output "FAIL - $Name"
        $script:failures++
    }
}

function Invoke-Benchmark {
    param([string[]]$Arguments)
    $output = & $Shell -NoProfile -ExecutionPolicy Bypass -File $script -OllamaHost $ollamaHost @Arguments 2>&1
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Get-LastRequest {
    return (Get-Content -Path $log -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json)
}

try {
    for ($i = 0; $i -lt 50; $i++) {
        try {
            Invoke-RestMethod "$ollamaHost/api/tags" | Out-Null
            break
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }

    # --- normal run -----------------------------------------------------
    $csv = Join-Path $tmp "out.csv"
    $r = Invoke-Benchmark @("-Model", "mock-model", "-Runs", "3", "-Think", "true",
        "-NumPredict", "128", "-Temperature", "0.5", "-Prompt", "hello", "-OutputCsv", $csv)
    Test-Case "exit 0" ($r.ExitCode -eq 0)
    Test-Case "prints summary" ($r.Output -match "Output speed\s+: 50\.00 tok/s avg")
    $rows = @(Import-Csv -Path $csv)
    Test-Case "csv has 3 rows" ($rows.Count -eq 3)
    Test-Case "OutputTokPerSec" ($rows[0].OutputTokPerSec -eq "50")
    Test-Case "PromptTokPerSec" ($rows[1].PromptTokPerSec -eq "200")
    Test-Case "ThinkingChars" ($rows[2].ThinkingChars -eq "6")
    Test-Case "AnswerChars" ($rows[2].AnswerChars -eq "8")
    Test-Case "ThinkingSec > 0" ([double]$rows[0].ThinkingSec -gt 0)
    Test-Case "warm-up + 3 runs requested" (@(Get-Content -Path $log).Count -eq 4)
    $req = Get-LastRequest
    Test-Case "request options" (
        $req.model -eq "mock-model" -and $req.think -eq $true -and
        $req.options.num_predict -eq 128 -and $req.options.temperature -eq 0.5 -and
        $req.prompt -eq "hello")

    # --- think / bust cache ---------------------------------------------
    Clear-Content -Path $log
    $r = Invoke-Benchmark @("-Model", "mock-model", "-Runs", "1", "-Think", "high", "-BustPromptCache",
        "-Prompt", "hello", "-OutputCsv", (Join-Path $tmp "b.csv"))
    $prompts = @(Get-Content -Path $log -Encoding UTF8 | ForEach-Object { ($_ | ConvertFrom-Json).prompt })
    Test-Case "think level is sent as string" ((Get-LastRequest).think -eq "high")
    Test-Case "bust cache prefixes a unique id" (
        $prompts[0] -match "^\[benchmark-id: " -and $prompts[0] -ne $prompts[1])

    Clear-Content -Path $log
    $r = Invoke-Benchmark @("-Model", "mock-model", "-Runs", "1", "-Think", "default", "-OutputCsv", (Join-Path $tmp "c.csv"))
    Test-Case "think=default omits think" ($null -eq (Get-LastRequest).PSObject.Properties["think"])

    # --- default csv name -----------------------------------------------
    $defaultDir = Join-Path $tmp "default"
    New-Item -ItemType Directory -Path $defaultDir | Out-Null
    Push-Location $defaultDir
    try {
        $r = Invoke-Benchmark @("-Model", "mock-model", "-Runs", "1")
    }
    finally {
        Pop-Location
    }
    $names = @(Get-ChildItem -Path $defaultDir -Name)
    Test-Case "default csv name has a timestamp" (
        $names.Count -eq 1 -and $names[0] -match "^ollama-benchmark-\d{8}-\d{6}\.csv$")

    # --- errors ---------------------------------------------------------
    $r = Invoke-Benchmark @("-Model", "missing-model", "-OutputCsv", (Join-Path $tmp "e.csv"))
    Test-Case "missing model exits 3" ($r.ExitCode -eq 3)

    $r = & $Shell -NoProfile -ExecutionPolicy Bypass -File $script -OllamaHost "http://127.0.0.1:1" `
        -Model "mock-model" -OutputCsv (Join-Path $tmp "e.csv") 2>&1
    Test-Case "unreachable Ollama exits 2" ($LASTEXITCODE -eq 2)
}
finally {
    Stop-Process -Id $mock.Id -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
}

Write-Output ""
if ($script:failures -gt 0) {
    Write-Output "$($script:failures) test(s) failed"
    exit 1
}
Write-Output "all tests passed"
exit 0
