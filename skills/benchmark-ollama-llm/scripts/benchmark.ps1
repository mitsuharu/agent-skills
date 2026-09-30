param(
    # 既定値は3つのスクリプトで共通の defaults.json（このスクリプトと同じ場所）から読む。
    # 優先順位: 引数 > -Config のJSON > defaults.json

    # defaults.json を上書きするJSONファイル
    [string]$Config,

    [string]$Model,

    [string]$Prompt,

    [int]$Runs,

    # true / false / low / medium / high / max / default
    [string]$Think,

    [int]$NumPredict,

    [double]$Temperature,

    # 省略時は開始時刻入りの名前にして上書きを防ぐ
    [string]$OutputCsv = "ollama-benchmark-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    # 指定すると毎回プロンプト先頭を変更して
    # prompt cache が効きにくい状態で入力性能を測る
    [switch]$BustPromptCache,

    # Ollama APIの接続先
    [string]$OllamaHost
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Settings: defaults.json < -Config < 引数
# ------------------------------------------------------------

$settingKeys = @("model", "prompt", "runs", "think", "numPredict", "temperature", "bustPromptCache", "host")

function Read-SettingsFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "Error: settings file not found: $Path"
        exit 1
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "Error: invalid JSON: $Path"
        exit 1
    }

    $unknown = @($json.PSObject.Properties.Name | Where-Object { $settingKeys -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-Host "Error: unknown keys in ${Path}: $($unknown -join ', ')"
        exit 1
    }

    return $json
}

$settings = @{}
$settingFiles = @(Join-Path $PSScriptRoot "defaults.json")
if ($Config) {
    $settingFiles += $Config
}
foreach ($file in $settingFiles) {
    foreach ($prop in (Read-SettingsFile $file).PSObject.Properties) {
        $settings[$prop.Name] = $prop.Value
    }
}

if (-not $PSBoundParameters.ContainsKey("Model")) { $Model = $settings["model"] }
if (-not $PSBoundParameters.ContainsKey("Prompt")) { $Prompt = $settings["prompt"] }
if (-not $PSBoundParameters.ContainsKey("Runs")) { $Runs = $settings["runs"] }
if (-not $PSBoundParameters.ContainsKey("Think")) { $Think = "$($settings["think"])" }
if (-not $PSBoundParameters.ContainsKey("NumPredict")) { $NumPredict = $settings["numPredict"] }
if (-not $PSBoundParameters.ContainsKey("Temperature")) { $Temperature = $settings["temperature"] }
if (-not $PSBoundParameters.ContainsKey("BustPromptCache")) { $BustPromptCache = [bool]$settings["bustPromptCache"] }
if (-not $PSBoundParameters.ContainsKey("OllamaHost")) { $OllamaHost = $settings["host"] }

if (-not $Model) {
    Write-Host "Error: model is not set"
    exit 1
}
if (-not $Think) { $Think = "default" }
if (-not $OllamaHost) { $OllamaHost = "http://localhost:11434" }
if ($Runs -lt 1) {
    Write-Host "Error: -Runs must be a positive integer"
    exit 1
}

Add-Type -AssemblyName System.Net.Http

$BaseUrl = "$($OllamaHost.TrimEnd('/'))/api/generate"

# ------------------------------------------------------------
# Helper
# ------------------------------------------------------------

function Convert-NsToSec {
    param($Ns)

    if ($null -eq $Ns) {
        return 0.0
    }

    return [double]$Ns / 1e9
}

function Get-TokensPerSec {
    param(
        $Count,
        $DurationNs
    )

    if (
        $null -eq $Count -or
        $null -eq $DurationNs -or
        [double]$DurationNs -le 0
    ) {
        return 0.0
    }

    return [double]$Count / ([double]$DurationNs / 1e9)
}

function Get-Median {
    param(
        [double[]]$Values
    )

    if ($Values.Count -eq 0) {
        return 0
    }

    $sorted = $Values | Sort-Object
    $count = $sorted.Count

    if ($count % 2 -eq 1) {
        return $sorted[[int][Math]::Floor($count / 2)]
    }

    $a = $sorted[$count / 2 - 1]
    $b = $sorted[$count / 2]

    return ($a + $b) / 2
}

function Get-ThinkValue {
    param(
        [string]$Value
    )

    switch ($Value.ToLower()) {
        "true" {
            return $true
        }

        "false" {
            return $false
        }

        "low" {
            return "low"
        }

        "medium" {
            return "medium"
        }

        "high" {
            return "high"
        }

        "max" {
            return "max"
        }

        default {
            return $null
        }
    }
}

# ------------------------------------------------------------
# HTTP client
# ------------------------------------------------------------

$client = [System.Net.Http.HttpClient]::new()

$client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

# ------------------------------------------------------------
# Preflight: Ollamaの起動とモデルの有無を確認する
#   exit 2: Ollamaに接続できない
#   exit 3: モデルがダウンロードされていない
# ------------------------------------------------------------

$TagsUrl = "$($OllamaHost.TrimEnd('/'))/api/tags"

try {
    $tagsJson = $client.GetStringAsync($TagsUrl).GetAwaiter().GetResult()
}
catch {
    Write-Host "Ollama is not reachable at $OllamaHost. Start Ollama (or install it) and retry."
    $client.Dispose()
    exit 2
}

$modelName = $Model
if ($modelName -notmatch ":") {
    $modelName = "${modelName}:latest"
}

$installedModels = @(($tagsJson | ConvertFrom-Json).models | ForEach-Object { $_.name })

if ($installedModels -notcontains $modelName) {
    Write-Host "Model '$Model' is not installed. Run: ollama pull $Model"
    $client.Dispose()
    exit 3
}

# ------------------------------------------------------------
# Benchmark
# ------------------------------------------------------------

function Invoke-BenchmarkRun {

    param(
        [int]$Run,
        [bool]$Warmup = $false
    )

    $actualPrompt = $Prompt

    if ($BustPromptCache) {
        #
        # Prefixを変更することで、同一prefixによる
        # prompt cacheの影響を減らす。
        #
        $benchmarkId = [Guid]::NewGuid().ToString()

        $actualPrompt = @"
[benchmark-id: $benchmarkId]
Ignore the benchmark-id above.

$Prompt
"@
    }

    $body = @{
        model       = $Model
        prompt      = $actualPrompt
        stream      = $true

        options     = @{
            temperature = $Temperature
            num_predict = $NumPredict
        }

        keep_alive  = "10m"
    }

    $thinkValue = Get-ThinkValue $Think

    if ($null -ne $thinkValue) {
        $body["think"] = $thinkValue
    }

    $json = $body | ConvertTo-Json -Depth 10

    $content = [System.Net.Http.StringContent]::new(
        $json,
        [System.Text.Encoding]::UTF8,
        "application/json"
    )

    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        $BaseUrl
    )

    $request.Content = $content

    # --------------------------------------------------------
    # Stopwatch start
    # --------------------------------------------------------

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $response = $client.SendAsync(
        $request,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()

    if (-not $response.IsSuccessStatusCode) {
        $errorText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        throw "Ollama API error: $($response.StatusCode)`n$errorText"
    }

    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

    $reader = [System.IO.StreamReader]::new($stream)

    # --------------------------------------------------------
    # Timing points
    # --------------------------------------------------------

    $firstOutputMs = $null

    $thinkingStartMs = $null

    $answerStartMs = $null

    $doneMs = $null

    $thinkingText = [System.Text.StringBuilder]::new()

    $answerText = [System.Text.StringBuilder]::new()

    $final = $null

    # --------------------------------------------------------
    # Read NDJSON stream
    # --------------------------------------------------------

    while ($null -ne ($line = $reader.ReadLine())) {

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $obj = $line | ConvertFrom-Json

        $now = $sw.Elapsed.TotalMilliseconds

        # -----------------------
        # Thinking
        # -----------------------

        if (
            $null -ne $obj.thinking -and
            $obj.thinking.Length -gt 0
        ) {

            if ($null -eq $firstOutputMs) {
                $firstOutputMs = $now
            }

            if ($null -eq $thinkingStartMs) {
                $thinkingStartMs = $now
            }

            [void]$thinkingText.Append($obj.thinking)
        }

        # -----------------------
        # Final response
        # -----------------------

        if (
            $null -ne $obj.response -and
            $obj.response.Length -gt 0
        ) {

            if ($null -eq $firstOutputMs) {
                $firstOutputMs = $now
            }

            if ($null -eq $answerStartMs) {
                $answerStartMs = $now
            }

            [void]$answerText.Append($obj.response)
        }

        # -----------------------
        # Done
        # -----------------------

        if ($obj.done -eq $true) {

            $doneMs = $now
            $final = $obj

            break
        }
    }

    $sw.Stop()

    $reader.Dispose()
    $stream.Dispose()
    $response.Dispose()
    $request.Dispose()
    $content.Dispose()

    # --------------------------------------------------------
    # Wall-clock phase calculations
    # --------------------------------------------------------

    $preOutputSec = 0.0

    if ($null -ne $firstOutputMs) {
        $preOutputSec = $firstOutputMs / 1000.0
    }

    $thinkingSec = 0.0

    if ($null -ne $thinkingStartMs) {

        if ($null -ne $answerStartMs) {
            $thinkingSec =
                ($answerStartMs - $thinkingStartMs) / 1000.0
        }
        elseif ($null -ne $doneMs) {
            $thinkingSec =
                ($doneMs - $thinkingStartMs) / 1000.0
        }
    }

    $answerSec = 0.0

    if (
        $null -ne $answerStartMs -and
        $null -ne $doneMs
    ) {
        $answerSec =
            ($doneMs - $answerStartMs) / 1000.0
    }

    # --------------------------------------------------------
    # Ollama server metrics
    # --------------------------------------------------------

    $promptEvalSec =
        Convert-NsToSec $final.prompt_eval_duration

    $evalSec =
        Convert-NsToSec $final.eval_duration

    $loadSec =
        Convert-NsToSec $final.load_duration

    $serverTotalSec =
        Convert-NsToSec $final.total_duration

    $promptTps =
        Get-TokensPerSec `
            $final.prompt_eval_count `
            $final.prompt_eval_duration

    $outputTps =
        Get-TokensPerSec `
            $final.eval_count `
            $final.eval_duration

    $cachedTokens = 0

    if ($null -ne $final.prompt_eval_cached_count) {
        $cachedTokens = $final.prompt_eval_cached_count
    }

    $result = [PSCustomObject]@{

        Run = $Run

        Model = $Model

        ThinkMode = $Think

        # -------------------------
        # INPUT
        # -------------------------

        PromptTokens =
            $final.prompt_eval_count

        PromptCachedTokens =
            $cachedTokens

        PromptEvalSec =
            [Math]::Round($promptEvalSec, 4)

        PromptTokPerSec =
            [Math]::Round($promptTps, 2)

        # -------------------------
        # LATENCY
        # -------------------------

        PreOutputSec =
            [Math]::Round($preOutputSec, 4)

        # -------------------------
        # THINKING
        # -------------------------

        ThinkingSec =
            [Math]::Round($thinkingSec, 4)

        ThinkingChars =
            $thinkingText.Length

        # -------------------------
        # ANSWER
        # -------------------------

        AnswerSec =
            [Math]::Round($answerSec, 4)

        AnswerChars =
            $answerText.Length

        # -------------------------
        # OUTPUT
        # -------------------------

        OutputTokens =
            $final.eval_count

        OutputEvalSec =
            [Math]::Round($evalSec, 4)

        OutputTokPerSec =
            [Math]::Round($outputTps, 2)

        # -------------------------
        # TOTAL
        # -------------------------

        LoadSec =
            [Math]::Round($loadSec, 4)

        ServerTotalSec =
            [Math]::Round($serverTotalSec, 4)

        WallSec =
            [Math]::Round($sw.Elapsed.TotalSeconds, 4)
    }

    if (-not $Warmup) {

        Write-Host ""

        Write-Host "Run $Run"

        Write-Host (
            "  Input    : {0:N2} tok/s ({1:N3}s)" -f `
            $result.PromptTokPerSec,
            $result.PromptEvalSec
        )

        Write-Host (
            "  PreOutput: {0:N3}s" -f `
            $result.PreOutputSec
        )

        Write-Host (
            "  Thinking : {0:N3}s" -f `
            $result.ThinkingSec
        )

        Write-Host (
            "  Answer   : {0:N3}s" -f `
            $result.AnswerSec
        )

        Write-Host (
            "  Output   : {0:N2} tok/s ({1} tokens)" -f `
            $result.OutputTokPerSec,
            $result.OutputTokens
        )

        Write-Host (
            "  Total    : {0:N3}s" -f `
            $result.WallSec
        )
    }

    return $result
}

# ------------------------------------------------------------
# Warm-up
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================="
Write-Host " Ollama LLM Benchmark"
Write-Host "========================================="
Write-Host "Model : $Model"
Write-Host "Think : $Think"
Write-Host "Runs  : $Runs"
Write-Host ""

Write-Host "Warming up..."

$null = Invoke-BenchmarkRun `
    -Run 0 `
    -Warmup $true

Write-Host "Warm-up complete."

# ------------------------------------------------------------
# Runs
# ------------------------------------------------------------

$results = @()

for ($i = 1; $i -le $Runs; $i++) {

    $result = Invoke-BenchmarkRun `
        -Run $i

    $results += $result
}

# ------------------------------------------------------------
# CSV
# ------------------------------------------------------------

$results |
    Export-Csv `
        -Path $OutputCsv `
        -NoTypeInformation `
        -Encoding UTF8

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

$avgPromptTps =
    ($results.PromptTokPerSec |
        Measure-Object -Average).Average

$avgThinking =
    ($results.ThinkingSec |
        Measure-Object -Average).Average

$avgAnswer =
    ($results.AnswerSec |
        Measure-Object -Average).Average

$avgOutputTps =
    ($results.OutputTokPerSec |
        Measure-Object -Average).Average

$avgWall =
    ($results.WallSec |
        Measure-Object -Average).Average

$avgPreOutput =
    ($results.PreOutputSec |
        Measure-Object -Average).Average

$medianOutputTps =
    Get-Median ([double[]]$results.OutputTokPerSec)

$medianWall =
    Get-Median ([double[]]$results.WallSec)

$medianThinking =
    Get-Median ([double[]]$results.ThinkingSec)

Write-Host ""
Write-Host "========================================="
Write-Host " Summary"
Write-Host "========================================="

Write-Host (
    "Input speed       : {0:N2} tok/s avg" -f `
    $avgPromptTps
)

Write-Host (
    "Pre-output        : {0:N3} sec avg" -f `
    $avgPreOutput
)

Write-Host (
    "Thinking          : {0:N3} sec avg / {1:N3} sec median" -f `
    $avgThinking,
    $medianThinking
)

Write-Host (
    "Answer            : {0:N3} sec avg" -f `
    $avgAnswer
)

Write-Host (
    "Output speed      : {0:N2} tok/s avg / {1:N2} tok/s median" -f `
    $avgOutputTps,
    $medianOutputTps
)

Write-Host (
    "Total wall time   : {0:N3} sec avg / {1:N3} sec median" -f `
    $avgWall,
    $medianWall
)

Write-Host ""
Write-Host "CSV: $OutputCsv"

$client.Dispose()
