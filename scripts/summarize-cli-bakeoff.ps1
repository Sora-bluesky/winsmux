param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$RunDir = '',
    [string]$OutputDir = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Get-BakeoffJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json -Depth 32
}

function Get-BakeoffNumber {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }

    return $null
}

function Get-BakeoffAverage {
    param([AllowNull()]$Values)

    $numbers = @($Values | ForEach-Object { Get-BakeoffNumber $_ } | Where-Object { $null -ne $_ })
    if ($numbers.Count -eq 0) {
        return $null
    }

    return [Math]::Round((($numbers | Measure-Object -Average).Average), 2)
}

function Get-BakeoffMedian {
    param([AllowNull()]$Values)

    $numbers = @($Values | ForEach-Object { Get-BakeoffNumber $_ } | Where-Object { $null -ne $_ } | Sort-Object)
    if ($numbers.Count -eq 0) {
        return $null
    }

    $middle = [int][Math]::Floor($numbers.Count / 2)
    if (($numbers.Count % 2) -eq 1) {
        return [Math]::Round([double]$numbers[$middle], 2)
    }

    return [Math]::Round(([double]$numbers[$middle - 1] + [double]$numbers[$middle]) / 2.0, 2)
}

function Format-BakeoffMarkdownCell {
    param([AllowNull()]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    return (($text -replace '\|', '\|') -replace "`r?`n", '<br>')
}

function Get-BakeoffRate {
    param(
        [int]$Numerator,
        [int]$Denominator
    )

    if ($Denominator -le 0) {
        return $null
    }

    return [Math]::Round(($Numerator / [double]$Denominator) * 100.0, 1)
}

function Get-BakeoffSeverityCount {
    param(
        [AllowNull()]$Result,
        [string]$Severity
    )

    if ($null -eq $Result -or $null -eq $Result.review_counts) {
        return 0
    }

    $property = $Result.review_counts.PSObject.Properties[$Severity]
    if ($null -eq $property) {
        return 0
    }

    return [int]$property.Value
}

function Get-BakeoffOverallScore {
    param([AllowNull()]$Result)

    if ($null -eq $Result) {
        return $null
    }

    $overall = Get-BakeoffNumber $Result.scores.overall
    if ($null -ne $overall) {
        return $overall
    }

    $weights = [ordered]@{
        accuracy         = 30
        review_findings  = 20
        speed            = 15
        parallelism      = 15
        async_terminal   = 10
        evidence_quality = 10
    }

    $weighted = 0.0
    $totalWeight = 0.0
    foreach ($axis in $weights.Keys) {
        $score = Get-BakeoffNumber $Result.scores.$axis
        if ($null -eq $score) {
            continue
        }

        $weighted += ($score * $weights[$axis])
        $totalWeight += $weights[$axis]
    }

    if ($totalWeight -le 0) {
        return $null
    }

    return [Math]::Round(($weighted / $totalWeight), 2)
}

function Get-BakeoffFit {
    param(
        [AllowNull()][double]$AverageScore,
        [int]$RunCount,
        [int]$P0,
        [int]$P1
    )

    if ($null -eq $AverageScore) {
        return 'pending'
    }
    if ($P0 -gt 0 -or $AverageScore -lt 40) {
        return 'avoid'
    }
    if ($P1 -gt 1 -or $AverageScore -lt 65) {
        return 'conditional'
    }
    if ($RunCount -lt 2) {
        return 'conditional'
    }
    if ($AverageScore -ge 85 -and $P1 -eq 0) {
        return 'best'
    }
    return 'strong'
}

function Get-BakeoffConfidence {
    param(
        [int]$RunCount,
        [AllowNull()][double]$VarianceHint
    )

    if ($RunCount -ge 5 -and ($null -eq $VarianceHint -or $VarianceHint -le 12)) {
        return 'high'
    }
    if ($RunCount -ge 2) {
        return 'medium'
    }
    return 'low'
}

function Get-BakeoffFitRank {
    param([AllowNull()][string]$Fit)

    switch ($Fit) {
        'best' { return 0 }
        'strong' { return 1 }
        'conditional' { return 2 }
        'avoid' { return 3 }
        default { return 4 }
    }
}

function Get-BakeoffConfidenceRank {
    param([AllowNull()][string]$Confidence)

    switch ($Confidence) {
        'high' { return 0 }
        'medium' { return 1 }
        'low' { return 2 }
        default { return 3 }
    }
}

function ConvertTo-BakeoffEmbeddedJson {
    param([Parameter(Mandatory = $true)]$Value)

    $json = $Value | ConvertTo-Json -Depth 32
    return (($json -replace '&', '\u0026') -replace '<', '\u003c') -replace '>', '\u003e'
}

function New-BakeoffHtmlReport {
    param([Parameter(Mandatory = $true)]$ReportData)

    $embeddedJson = ConvertTo-BakeoffEmbeddedJson -Value $ReportData
    $template = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>winsmux Benchmark Report</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f8fb;
      --paper: #ffffff;
      --ink: #101827;
      --muted: #64748b;
      --line: #dbe3ef;
      --blue: #4f9cf9;
      --cyan: #1cc8c8;
      --violet: #8768f2;
      --green: #23b67b;
      --amber: #f0a927;
      --rose: #e65f7b;
      --shadow: 0 18px 45px rgba(15, 23, 42, .10);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background:
        radial-gradient(circle at 18% 0%, rgba(79, 156, 249, .18), transparent 34rem),
        radial-gradient(circle at 90% 10%, rgba(28, 200, 200, .16), transparent 30rem),
        var(--bg);
      color: var(--ink);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0;
    }
    .shell { width: min(1180px, calc(100vw - 48px)); margin: 0 auto; padding: 42px 0 56px; }
    header { display: grid; gap: 12px; margin-bottom: 28px; }
    .eyebrow { color: var(--blue); font-size: 13px; font-weight: 800; text-transform: uppercase; }
    h1 { margin: 0; font-size: clamp(34px, 5vw, 58px); line-height: 1; letter-spacing: 0; }
    .subtitle { max-width: 860px; margin: 0; color: var(--muted); font-size: 17px; line-height: 1.62; }
    .kpis { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 14px; margin: 26px 0 28px; }
    .kpi, .panel {
      background: rgba(255, 255, 255, .86);
      border: 1px solid rgba(203, 213, 225, .82);
      border-radius: 8px;
      box-shadow: var(--shadow);
    }
    .kpi { padding: 18px; }
    .kpi-label { color: var(--muted); font-size: 12px; font-weight: 700; text-transform: uppercase; }
    .kpi-value { margin-top: 8px; font-size: 30px; font-weight: 850; }
    .grid { display: grid; grid-template-columns: 1.1fr .9fr; gap: 18px; align-items: start; }
    .panel { padding: 20px; overflow: hidden; }
    .panel h2 { margin: 0 0 14px; font-size: 19px; }
    .leaderboard { display: grid; gap: 12px; }
    .condition-row { display: grid; grid-template-columns: minmax(190px, 1fr) minmax(280px, 2fr) 72px; gap: 12px; align-items: center; }
    .condition-name { min-width: 0; }
    .condition-name strong { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .condition-name span { display: block; margin-top: 3px; color: var(--muted); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .bar-track { position: relative; height: 34px; background: #edf2f7; border: 1px solid #d8e2ee; border-radius: 6px; overflow: hidden; }
    .bar-fill { height: 100%; border-radius: 6px; background: linear-gradient(90deg, var(--blue), var(--cyan)); }
    .bar-fill.warn { background: linear-gradient(90deg, var(--amber), var(--rose)); }
    .score { text-align: right; font-variant-numeric: tabular-nums; font-weight: 850; }
    .chart-card { min-height: 280px; }
    svg { width: 100%; height: auto; display: block; }
    .axis text, .axis-label { fill: var(--muted); font-size: 11px; }
    .point-label { fill: var(--ink); font-size: 11px; font-weight: 700; }
    .section { margin-top: 18px; }
    .heatmap { width: 100%; border-collapse: collapse; font-size: 13px; }
    .heatmap th, .heatmap td { border-bottom: 1px solid var(--line); padding: 10px; text-align: left; }
    .heatmap th { color: var(--muted); font-size: 12px; text-transform: uppercase; }
    .pill { display: inline-flex; align-items: center; min-height: 24px; padding: 3px 8px; border-radius: 999px; background: #eef6ff; color: #215a9d; font-size: 12px; font-weight: 750; }
    .notes { color: var(--muted); line-height: 1.58; font-size: 14px; }
    .empty { color: var(--muted); padding: 28px; border: 1px dashed var(--line); border-radius: 8px; background: #f8fafc; }
    @media (max-width: 860px) {
      .shell { width: min(100vw - 28px, 1180px); padding-top: 28px; }
      .kpis, .grid { grid-template-columns: 1fr; }
      .condition-row { grid-template-columns: 1fr; gap: 8px; }
      .score { text-align: left; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <header>
      <div class="eyebrow">winsmux HarnessBench-style comparison</div>
      <h1>Benchmark Report</h1>
      <p class="subtitle">A static, reference-friendly HTML report for comparing worker-pane conditions. It uses the same task-packet and deterministic evidence contract, then visualizes score, completion, speed, and task fit in a SWE-bench Pro style layout.</p>
    </header>
    <section class="kpis" id="kpis"></section>
    <section class="grid">
      <article class="panel">
        <h2>Score Leaderboard</h2>
        <div class="leaderboard" id="leaderboard"></div>
      </article>
      <article class="panel chart-card">
        <h2>Speed Quality Map</h2>
        <div id="scatter"></div>
      </article>
    </section>
    <section class="grid section">
      <article class="panel chart-card">
        <h2>Capability Radar</h2>
        <div id="radar"></div>
      </article>
      <article class="panel">
        <h2>Task-Class Heatmap</h2>
        <div id="heatmap"></div>
      </article>
    </section>
    <section class="panel section">
      <h2>Methodology Notes</h2>
      <p class="notes">Primary scoring must come from hidden or deterministic checks. LLM review is used for audit and explanation. Small samples remain directional until the task count and repeated runs are large enough.</p>
      <p class="notes" id="refs"></p>
    </section>
  </main>
  <script id="benchmark-data" type="application/json">
__BENCHMARK_DATA_JSON__
  </script>
  <script>
    const data = JSON.parse(document.getElementById("benchmark-data").textContent);
    const conditions = Array.isArray(data.conditions) ? data.conditions : [];
    const axes = [
      ["AverageAccuracy", "average_accuracy", "Accuracy"],
      ["AverageReview", "average_review", "Review"],
      ["AverageSpeed", "average_speed", "Speed"],
      ["AverageParallelism", "average_parallelism", "Parallel"],
      ["AverageAsyncTerminal", "average_async_terminal", "Async"],
      ["AverageEvidence", "average_evidence", "Evidence"]
    ];
    function pick(obj, ...names) {
      for (const name of names) {
        if (obj && Object.prototype.hasOwnProperty.call(obj, name) && obj[name] !== null && obj[name] !== "") return obj[name];
      }
      return null;
    }
    function num(value, fallback = 0) {
      const n = Number(value);
      return Number.isFinite(n) ? n : fallback;
    }
    function pct(value) {
      const n = num(value, NaN);
      return Number.isFinite(n) ? n.toFixed(1) + "%" : "n/a";
    }
    function label(c) {
      return [pick(c, "Cli", "cli"), pick(c, "Model", "model"), pick(c, "Effort", "effort")].filter(Boolean).join(" / ");
    }
    function metric(c) {
      return num(pick(c, "AverageOverall", "average_overall"), num(pick(c, "PassRate", "pass_rate"), num(pick(c, "CompletionRate", "completion_rate"), 0)));
    }
    function metricText(c) {
      const overall = pick(c, "AverageOverall", "average_overall");
      if (overall !== null) return Number(overall).toFixed(1);
      const pass = pick(c, "PassRate", "pass_rate");
      if (pass !== null) return pct(pass);
      return pct(pick(c, "CompletionRate", "completion_rate"));
    }
    function escapeHtml(s) {
      return String(s ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    }
    function conditionColor(i) {
      return ["#4f9cf9", "#1cc8c8", "#8768f2", "#23b67b", "#f0a927", "#e65f7b"][i % 6];
    }
    function renderKpis() {
      const total = conditions.length;
      const started = conditions.reduce((sum, c) => sum + num(pick(c, "Started", "started")), 0);
      const completed = conditions.reduce((sum, c) => sum + num(pick(c, "Completed", "completed")), 0);
      const timeouts = conditions.reduce((sum, c) => sum + num(pick(c, "TimeoutCount", "timeout_count")), 0);
      const best = conditions.length ? Math.max(...conditions.map(metric)) : 0;
      document.getElementById("kpis").innerHTML = [
        ["Conditions", total],
        ["Started runs", started],
        ["Completed runs", completed],
        ["Best score", best ? best.toFixed(1) : "n/a"]
      ].map(([k, v]) => '<div class="kpi"><div class="kpi-label">' + escapeHtml(k) + '</div><div class="kpi-value">' + escapeHtml(v) + '</div></div>').join("");
    }
    function renderLeaderboard() {
      const sorted = [...conditions].sort((a, b) => metric(b) - metric(a));
      const root = document.getElementById("leaderboard");
      if (!sorted.length) {
        root.innerHTML = '<div class="empty">No scored benchmark conditions yet.</div>';
        return;
      }
      root.innerHTML = sorted.map((c, i) => {
        const score = Math.max(0, Math.min(100, metric(c)));
        const cli = pick(c, "Cli", "cli") || "unknown";
        const model = pick(c, "Model", "model") || "unknown";
        const task = pick(c, "TaskClass", "task_class") || "unknown task";
        const runCount = pick(c, "RunCount", "run_count") || 0;
        const time = pick(c, "MedianWallTimeSec", "median_wall_time_sec");
        return '<div class="condition-row">'
          + '<div class="condition-name"><strong>' + escapeHtml(cli) + '</strong><span>' + escapeHtml(model + " / " + task + " / n=" + runCount) + '</span></div>'
          + '<div class="bar-track"><div class="bar-fill" style="width:' + score.toFixed(1) + '%; background:linear-gradient(90deg,' + conditionColor(i) + ',#1cc8c8)"></div></div>'
          + '<div class="score">' + escapeHtml(metricText(c)) + '</div>'
          + (time !== null ? '<div></div><div class="notes">median wall time: ' + Number(time).toFixed(1) + 's</div><div></div>' : '')
          + '</div>';
      }).join("");
    }
    function renderScatter() {
      const width = 520, height = 310, pad = 48;
      const points = conditions.filter(c => pick(c, "MedianWallTimeSec", "median_wall_time_sec") !== null || metric(c) > 0);
      if (!points.length) {
        document.getElementById("scatter").innerHTML = '<div class="empty">No speed-quality points yet.</div>';
        return;
      }
      const maxX = Math.max(1, ...points.map(c => num(pick(c, "MedianWallTimeSec", "median_wall_time_sec"), 0))) * 1.15;
      const maxY = Math.max(100, ...points.map(metric));
      const x = c => pad + (num(pick(c, "MedianWallTimeSec", "median_wall_time_sec"), 0) / maxX) * (width - pad * 1.4);
      const y = c => height - pad - (metric(c) / maxY) * (height - pad * 1.5);
      let svg = '<svg viewBox="0 0 ' + width + ' ' + height + '" role="img" aria-label="Speed quality scatter plot">';
      svg += '<line x1="' + pad + '" y1="' + (height-pad) + '" x2="' + (width-pad/2) + '" y2="' + (height-pad) + '" stroke="#cbd5e1"/>';
      svg += '<line x1="' + pad + '" y1="' + pad/2 + '" x2="' + pad + '" y2="' + (height-pad) + '" stroke="#cbd5e1"/>';
      svg += '<text class="axis-label" x="' + (width/2 - 64) + '" y="' + (height-10) + '">Median wall time (seconds)</text>';
      svg += '<text class="axis-label" x="8" y="20">Quality score</text>';
      points.forEach((c, i) => {
        const px = x(c), py = y(c), name = (pick(c, "Cli", "cli") || "worker") + " / " + (pick(c, "Model", "model") || "model");
        svg += '<circle cx="' + px.toFixed(1) + '" cy="' + py.toFixed(1) + '" r="7" fill="' + conditionColor(i) + '" opacity=".92"/>';
        svg += '<text class="point-label" x="' + Math.min(px + 10, width - 150).toFixed(1) + '" y="' + (py - 9).toFixed(1) + '">' + escapeHtml(name.slice(0, 34)) + '</text>';
      });
      svg += '</svg>';
      document.getElementById("scatter").innerHTML = svg;
    }
    function renderRadar() {
      const top = [...conditions].sort((a, b) => metric(b) - metric(a)).slice(0, 4);
      if (!top.length) {
        document.getElementById("radar").innerHTML = '<div class="empty">No capability data yet.</div>';
        return;
      }
      const width = 460, height = 330, cx = 230, cy = 165, maxR = 118;
      const angle = i => -Math.PI / 2 + (i / axes.length) * Math.PI * 2;
      let svg = '<svg viewBox="0 0 ' + width + ' ' + height + '" role="img" aria-label="Capability radar chart">';
      [0.25, 0.5, 0.75, 1].forEach(r => {
        const points = axes.map((_, i) => [cx + Math.cos(angle(i)) * maxR * r, cy + Math.sin(angle(i)) * maxR * r].join(",")).join(" ");
        svg += '<polygon points="' + points + '" fill="none" stroke="#dbe3ef"/>';
      });
      axes.forEach(([pascalKey, snakeKey, text], i) => {
        const ax = cx + Math.cos(angle(i)) * (maxR + 30), ay = cy + Math.sin(angle(i)) * (maxR + 30);
        svg += '<line x1="' + cx + '" y1="' + cy + '" x2="' + (cx + Math.cos(angle(i)) * maxR) + '" y2="' + (cy + Math.sin(angle(i)) * maxR) + '" stroke="#e2e8f0"/>';
        svg += '<text class="axis-label" x="' + (ax - 24) + '" y="' + ay + '">' + text + '</text>';
      });
      top.forEach((c, idx) => {
        const points = axes.map(([pascalKey, snakeKey], i) => {
          const value = num(pick(c, pascalKey, snakeKey), metric(c));
          const r = Math.max(0, Math.min(100, value)) / 100 * maxR;
          return [cx + Math.cos(angle(i)) * r, cy + Math.sin(angle(i)) * r].join(",");
        }).join(" ");
        const color = conditionColor(idx);
        svg += '<polygon points="' + points + '" fill="' + color + '" fill-opacity=".16" stroke="' + color + '" stroke-width="2"/>';
      });
      svg += '</svg><div class="notes">' + top.map((c, i) => '<span class="pill" style="margin-right:6px;color:' + conditionColor(i) + '">' + escapeHtml(label(c).slice(0, 42)) + '</span>').join(" ") + '</div>';
      document.getElementById("radar").innerHTML = svg;
    }
    function renderHeatmap() {
      if (!conditions.length) {
        document.getElementById("heatmap").innerHTML = '<div class="empty">No task-class cells yet.</div>';
        return;
      }
      const sorted = [...conditions].sort((a, b) => String(pick(a, "TaskClass", "task_class")).localeCompare(String(pick(b, "TaskClass", "task_class"))) || metric(b) - metric(a));
      let html = '<table class="heatmap"><thead><tr><th>Task class</th><th>Condition</th><th>Score</th><th>Run state</th></tr></thead><tbody>';
      sorted.forEach(c => {
        const score = metric(c);
        const hue = 8 + Math.round(score * 1.25);
        const bg = 'hsl(' + hue + ' 78% 88%)';
        html += '<tr><td>' + escapeHtml(pick(c, "TaskClass", "task_class") || "unknown") + '</td>'
          + '<td>' + escapeHtml(label(c)) + '</td>'
          + '<td style="background:' + bg + ';font-weight:800">' + escapeHtml(metricText(c)) + '</td>'
          + '<td><span class="pill">completed ' + escapeHtml(pick(c, "Completed", "completed") || 0) + ' / started ' + escapeHtml(pick(c, "Started", "started") || 0) + '</span></td></tr>';
      });
      html += '</tbody></table>';
      document.getElementById("heatmap").innerHTML = html;
    }
    function renderRefs() {
      const refs = data.methodology && Array.isArray(data.methodology.references) ? data.methodology.references : [];
      document.getElementById("refs").innerHTML = refs.length ? "Methodology references: " + refs.map(r => '<a href="' + escapeHtml(r) + '">' + escapeHtml(r) + '</a>').join(" / ") : "";
    }
    renderKpis();
    renderLeaderboard();
    renderScatter();
    renderRadar();
    renderHeatmap();
    renderRefs();
  </script>
</body>
</html>
'@

    return $template.Replace('__BENCHMARK_DATA_JSON__', $embeddedJson)
}

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$runRoot = Join-Path (Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'evidence') 'cli-bakeoff'
if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) {
    throw "CLI bakeoff evidence directory does not exist: $runRoot"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = if ([string]::IsNullOrWhiteSpace($RunDir)) {
        Join-Path $runRoot 'summary'
    } else {
        Join-Path (Resolve-Path -LiteralPath $RunDir).Path 'summary'
    }
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$runDirectories = if ([string]::IsNullOrWhiteSpace($RunDir)) {
    @(Get-ChildItem -LiteralPath $runRoot -Directory | Where-Object {
        -not [string]::Equals($_.Name, 'summary', [System.StringComparison]::OrdinalIgnoreCase)
    })
} else {
    @(Get-Item -LiteralPath (Resolve-Path -LiteralPath $RunDir).Path)
}

$runs = @()
$workerRuns = @()
foreach ($runDirInfo in $runDirectories) {
    $manifest = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName 'manifest.json')
    $result = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName 'result.json')
    $recording = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName 'screen-recording.json')
    if ($null -eq $manifest -or $null -eq $result) {
        continue
    }

    $runs += [PSCustomObject]@{
        RunId                = [string]$manifest.run_id
        Cli                  = [string]$manifest.cli
        Model                = [string]$manifest.model
        Effort               = [string]$manifest.effort
        TaskClass            = [string]$manifest.task_class
        Overall              = Get-BakeoffOverallScore -Result $result
        Accuracy             = Get-BakeoffNumber $result.scores.accuracy
        ReviewFindings       = Get-BakeoffNumber $result.scores.review_findings
        Speed                = Get-BakeoffNumber $result.scores.speed
        Parallelism          = Get-BakeoffNumber $result.scores.parallelism
        AsyncTerminal        = Get-BakeoffNumber $result.scores.async_terminal
        EvidenceQuality      = Get-BakeoffNumber $result.scores.evidence_quality
        Quality              = Get-BakeoffNumber $result.capability_vector.quality
        CapabilityEvidence   = Get-BakeoffNumber $result.capability_vector.evidence
        Autonomy             = Get-BakeoffNumber $result.capability_vector.autonomy
        TerminalOperation    = Get-BakeoffNumber $result.capability_vector.terminal_operation
        Safety               = Get-BakeoffNumber $result.capability_vector.safety
        Continuity           = Get-BakeoffNumber $result.capability_vector.continuity
        P0                   = Get-BakeoffSeverityCount -Result $result -Severity 'P0'
        P1                   = Get-BakeoffSeverityCount -Result $result -Severity 'P1'
        P2                   = Get-BakeoffSeverityCount -Result $result -Severity 'P2'
        P3                   = Get-BakeoffSeverityCount -Result $result -Severity 'P3'
        Verdict              = [string]$result.verdict
        RecordingStatus      = if ($null -eq $recording) { '' } else { [string]$recording.status }
        RecordingPublishable = if ($null -eq $recording) { $false } else { [bool]$recording.publishable }
        EvidenceDir          = [string]$runDirInfo.FullName
    }

    if ($null -ne $manifest.active_workers) {
        foreach ($worker in @($manifest.active_workers)) {
            $paneId = [string]$worker.pane
            $safePaneId = if ([string]::IsNullOrWhiteSpace($paneId)) {
                'pane'
            } else {
                (($paneId.Trim() -replace '[^A-Za-z0-9._-]', '-').Trim('.'))
            }
            if ([string]::IsNullOrWhiteSpace($safePaneId)) {
                $safePaneId = 'pane'
            }

            $resultFileName = "$safePaneId-result.json"
            $workerExecutions = $manifest.PSObject.Properties['worker_executions']
            if ($null -ne $workerExecutions -and $null -ne $workerExecutions.Value) {
                $execution = $workerExecutions.Value.PSObject.Properties[$paneId]
                if ($null -ne $execution -and -not [string]::IsNullOrWhiteSpace([string]$execution.Value.pane_result)) {
                    $resultFileName = [string]$execution.Value.pane_result
                }
            }

            $workerResult = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName $resultFileName)
            $workerScores = if ($null -eq $workerResult) { $null } else { $workerResult.scores }
            $workerRuns += [PSCustomObject]@{
                RunId           = [string]$manifest.run_id
                PaneId          = $paneId
                Cli             = [string]$worker.cli
                Model           = [string]$worker.display_model
                ModelArg        = [string]$worker.model_arg
                Effort          = [string]$worker.effort
                TaskClass       = [string]$manifest.task_class
                Status          = if ($null -eq $workerResult) { 'pending' } else { [string]$workerResult.status }
                BlockedReason   = if ($null -eq $workerResult) { '' } else { [string]$workerResult.blocked_reason }
                ElapsedSeconds  = if ($null -eq $workerResult) { $null } else { Get-BakeoffNumber $workerResult.elapsed_seconds }
                TimedOut        = if ($null -eq $workerResult) { $false } else { [bool]$workerResult.timed_out }
                ExitCode        = if ($null -eq $workerResult) { $null } else { $workerResult.exit_code }
                Overall         = if ($null -eq $workerScores) { $null } else { Get-BakeoffOverallScore -Result $workerResult }
                Accuracy        = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.accuracy }
                ReviewFindings  = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.review_findings }
                Speed           = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.speed }
                Parallelism     = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.parallelism }
                AsyncTerminal   = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.async_terminal }
                EvidenceQuality = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.evidence_quality }
                Verdict         = if ($null -eq $workerResult) { 'pending' } else { [string]$workerResult.verdict }
                EvidenceDir     = [string]$runDirInfo.FullName
            }
        }
    }
}

$csvRows = @()
foreach ($run in $runs) {
    foreach ($axis in @('Accuracy', 'ReviewFindings', 'Speed', 'Parallelism', 'AsyncTerminal', 'EvidenceQuality', 'Overall')) {
        $csvRows += [PSCustomObject]@{
            run_id                = $run.RunId
            cli                   = $run.Cli
            model                 = $run.Model
            task_class            = $run.TaskClass
            axis                  = $axis
            score                 = $run.$axis
            p0                    = $run.P0
            p1                    = $run.P1
            p2                    = $run.P2
            p3                    = $run.P3
            verdict               = $run.Verdict
            recording_status      = $run.RecordingStatus
            recording_publishable = $run.RecordingPublishable
            evidence_dir          = $run.EvidenceDir
        }
    }
}

$rawScorePath = Join-Path $OutputDir 'raw-score-matrix.csv'
$csvRows | Export-Csv -LiteralPath $rawScorePath -NoTypeInformation -Encoding UTF8

$conditionRows = @()
$workerSource = if (@($workerRuns).Count -gt 0) { @($workerRuns) } else { @($runs) }
foreach ($group in $workerSource | Group-Object Cli, Model, Effort, TaskClass) {
    $items = @($group.Group)
    if ($items.Count -eq 0) {
        continue
    }

    $started = @($items | Where-Object { [string]$_.Status -ne 'pending' }).Count
    $completed = @($items | Where-Object { [string]$_.Status -eq 'completed' }).Count
    $pending = @($items | Where-Object { [string]$_.Status -eq 'pending' }).Count
    $timeouts = @($items | Where-Object { [bool]$_.TimedOut -or [string]$_.BlockedReason -eq 'timeout' }).Count
    $passItems = @($items | Where-Object { [string]$_.Verdict -in @('pass', 'passed') }).Count
    $passDenominator = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Verdict) -and [string]$_.Verdict -ne 'pending' }).Count
    $conditionRows += [PSCustomObject]@{
        Cli                  = [string]$items[0].Cli
        Model                = [string]$items[0].Model
        Effort               = [string]$items[0].Effort
        TaskClass            = [string]$items[0].TaskClass
        RunCount             = $items.Count
        Started              = $started
        Pending              = $pending
        Completed            = $completed
        CompletionRate       = Get-BakeoffRate -Numerator $completed -Denominator $started
        PassCount            = $passItems
        PassRate             = Get-BakeoffRate -Numerator $passItems -Denominator $passDenominator
        MedianWallTimeSec    = Get-BakeoffMedian ($items | ForEach-Object { $_.ElapsedSeconds })
        TimeoutCount         = $timeouts
        AverageOverall       = Get-BakeoffAverage ($items | ForEach-Object { $_.Overall })
        AverageAccuracy      = Get-BakeoffAverage ($items | ForEach-Object { $_.Accuracy })
        AverageReview        = Get-BakeoffAverage ($items | ForEach-Object { $_.ReviewFindings })
        AverageSpeed         = Get-BakeoffAverage ($items | ForEach-Object { $_.Speed })
        AverageParallelism   = Get-BakeoffAverage ($items | ForEach-Object { $_.Parallelism })
        AverageAsyncTerminal = Get-BakeoffAverage ($items | ForEach-Object { $_.AsyncTerminal })
        AverageEvidence      = Get-BakeoffAverage ($items | ForEach-Object { $_.EvidenceQuality })
        EvidenceRuns         = (@($items | ForEach-Object { $_.RunId }) | Sort-Object -Unique) -join ', '
    }
}

$chartDataPath = Join-Path $OutputDir 'chart-data.json'
$chartData = [ordered]@{
    version          = 1
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    methodology      = [ordered]@{
        references = @(
            'https://nyosegawa.com/posts/harness-bench/',
            'https://nyosegawa.com/posts/harness-bench-antigravity-composer-25/'
        )
        note = 'Use hidden or deterministic checks for primary scoring; use LLM review for failure audit and explanation.'
    }
    conditions       = @($conditionRows)
    charts           = @(
        [ordered]@{ id = 'completion_rate_bar'; title = 'Completion or pass rate by condition'; x = 'condition'; y = 'completion_rate'; source = 'conditions' },
        [ordered]@{ id = 'median_wall_time_bar'; title = 'Median wall time by condition'; x = 'condition'; y = 'median_wall_time_sec'; source = 'conditions' },
        [ordered]@{ id = 'speed_quality_scatter'; title = 'Speed-quality tradeoff'; x = 'median_wall_time_sec'; y = 'average_overall'; source = 'conditions' },
        [ordered]@{ id = 'capability_radar'; title = 'Capability vector by condition'; axes = @('accuracy', 'review_findings', 'speed', 'parallelism', 'async_terminal', 'evidence_quality'); source = 'conditions' },
        [ordered]@{ id = 'task_class_heatmap'; title = 'Task-class fit heatmap'; x = 'condition'; y = 'task_class'; color = 'average_overall'; source = 'conditions' }
    )
}
$chartData | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $chartDataPath -Encoding UTF8

$profileModels = [ordered]@{}
$fitRows = @()
foreach ($group in $runs | Group-Object Cli, Model, TaskClass) {
    $items = @($group.Group)
    if ($items.Count -eq 0) {
        continue
    }

    $cli = [string]$items[0].Cli
    $model = [string]$items[0].Model
    $taskClass = [string]$items[0].TaskClass
    $profileKey = "$cli`t$model"
    $averageOverall = Get-BakeoffAverage ($items | ForEach-Object { $_.Overall })
    $p0 = [int](($items | Measure-Object -Property P0 -Sum).Sum)
    $p1 = [int](($items | Measure-Object -Property P1 -Sum).Sum)
    $fit = Get-BakeoffFit -AverageScore $averageOverall -RunCount $items.Count -P0 $p0 -P1 $p1
    $confidence = Get-BakeoffConfidence -RunCount $items.Count -VarianceHint $null
    $evidenceRuns = @($items | ForEach-Object { $_.RunId })
    $caveat = if ($fit -eq 'pending') {
        'Scores are incomplete.'
    } elseif ($confidence -eq 'low') {
        'Only one run is available; treat this as a hypothesis.'
    } elseif ($p0 -gt 0 -or $p1 -gt 0) {
        'Review findings require cross-family review before assignment.'
    } else {
        ''
    }

    $fitRows += [PSCustomObject]@{
        Cli        = $cli
        Model      = $model
        TaskClass  = $taskClass
        Fit        = $fit
        Confidence = $confidence
        Caveat     = $caveat
        Evidence   = ($evidenceRuns -join ', ')
    }

    if (-not $profileModels.Contains($profileKey)) {
        $profileModels[$profileKey] = [ordered]@{
            cli            = $cli
            model          = $model
            run_count      = 0
            task_classes   = @()
            evidence_runs  = @()
            scores_average = [ordered]@{}
            capability_average = [ordered]@{}
        }
    }

    $profileModels[$profileKey].run_count += $items.Count
    $profileModels[$profileKey].task_classes = @($profileModels[$profileKey].task_classes + $taskClass | Sort-Object -Unique)
    $profileModels[$profileKey].evidence_runs = @($profileModels[$profileKey].evidence_runs + $evidenceRuns | Sort-Object -Unique)
}

foreach ($profileKey in @($profileModels.Keys)) {
    $profile = $profileModels[$profileKey]
    $modelRuns = @($runs | Where-Object { $_.Cli -eq $profile.cli -and $_.Model -eq $profile.model })
    $profileModels[$profileKey].scores_average = [ordered]@{
        accuracy         = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Accuracy })
        review_findings  = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.ReviewFindings })
        speed            = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Speed })
        parallelism      = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Parallelism })
        async_terminal   = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.AsyncTerminal })
        evidence_quality = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.EvidenceQuality })
        overall          = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Overall })
    }
    $profileModels[$profileKey].capability_average = [ordered]@{
        quality            = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Quality })
        speed              = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Speed })
        autonomy           = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Autonomy })
        parallelism        = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Parallelism })
        terminal_operation = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.TerminalOperation })
        evidence           = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.CapabilityEvidence })
        safety             = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Safety })
        continuity         = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Continuity })
    }
}

$profilePath = Join-Path $OutputDir 'model-evidence-profile.json'
([ordered]@{
    version      = 1
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    run_count    = @($runs).Count
    models       = @($profileModels.Values)
}) | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $profilePath -Encoding UTF8

$fitPath = Join-Path $OutputDir 'model-task-fit.md'
$fitLines = @(
    '# Model Task Fit',
    '',
    '| CLI | Model | Task class | Fit | Confidence | Caveat | Evidence |',
    '| --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $fitRows | Sort-Object Cli, Model, TaskClass) {
    $fitLines += "| $($row.Cli) | $($row.Model) | $($row.TaskClass) | $($row.Fit) | $($row.Confidence) | $($row.Caveat) | $($row.Evidence) |"
}
if ($fitRows.Count -eq 0) {
    $fitLines += '|  |  |  | pending | low | No scored runs found. |  |'
}
$fitLines | Set-Content -LiteralPath $fitPath -Encoding UTF8

$assignmentPath = Join-Path $OutputDir 'assignment-policy.md'
$assignmentLines = @(
    '# Assignment Policy',
    '',
    'Use this as a generated starting point. Human review remains required before changing the default worker layout.',
    ''
)
foreach ($taskGroup in $fitRows | Group-Object TaskClass | Sort-Object Name) {
    $best = @(
        $taskGroup.Group |
            Where-Object { $_.Fit -in @('best', 'strong') } |
            Sort-Object `
                @{ Expression = { Get-BakeoffFitRank -Fit $_.Fit }; Descending = $false },
                @{ Expression = { Get-BakeoffConfidenceRank -Confidence $_.Confidence }; Descending = $false },
                Cli,
                Model |
            Select-Object -First 1
    )
    $assignmentLines += "## $($taskGroup.Name)"
    if ($best.Count -eq 0) {
        $assignmentLines += ''
        $assignmentLines += 'No model has enough evidence for an automatic recommendation.'
        $assignmentLines += ''
        continue
    }
    $assignmentLines += ''
    $assignmentLines += "- Recommended CLI/model: $($best[0].Cli) / $($best[0].Model)"
    $assignmentLines += "- Fit: $($best[0].Fit)"
    $assignmentLines += "- Confidence: $($best[0].Confidence)"
    $assignmentLines += "- Evidence: $($best[0].Evidence)"
    if (-not [string]::IsNullOrWhiteSpace($best[0].Caveat)) {
        $assignmentLines += "- Caveat: $($best[0].Caveat)"
    }
    $assignmentLines += ''
}
$assignmentLines | Set-Content -LiteralPath $assignmentPath -Encoding UTF8

$articleReportPath = Join-Path $OutputDir 'article-report.md'
$conditionTableLines = @(
    '| CLI | Model | Effort | Task class | Started | Pending | Completed | Completion rate | Pass | Pass rate | Median wall time | Timeout | Avg overall |',
    '| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
)
foreach ($row in $conditionRows | Sort-Object TaskClass, Cli, Model, Effort) {
    $completionRate = if ($null -eq $row.CompletionRate) { '' } else { "$($row.CompletionRate)%" }
    $passRate = if ($null -eq $row.PassRate) { '' } else { "$($row.PassRate)%" }
    $conditionTableLines += "| $(Format-BakeoffMarkdownCell $row.Cli) | $(Format-BakeoffMarkdownCell $row.Model) | $(Format-BakeoffMarkdownCell $row.Effort) | $(Format-BakeoffMarkdownCell $row.TaskClass) | $($row.Started)/$($row.RunCount) | $($row.Pending) | $($row.Completed) | $completionRate | $($row.PassCount) | $passRate | $($row.MedianWallTimeSec) | $($row.TimeoutCount) | $($row.AverageOverall) |"
}
if ($conditionRows.Count -eq 0) {
    $conditionTableLines += '|  |  |  |  | 0/0 | 0 | 0 |  | 0 |  |  |  |  |'
}

$chartPromptPath = Join-Path $OutputDir 'gpt-image-2-chart-prompts.md'
$articleLines = @(
    '# winsmux CLI Bakeoff Report',
    '',
    '## What Was Evaluated',
    '',
    'This report compares CLI harness and model conditions inside winsmux worker panes. The primary unit is not only the model; it is the combination of CLI, model, effort, permissions, timeout behavior, terminal handling, and evidence quality.',
    '',
    '## Methodology',
    '',
    '- Every candidate receives the same saved `task-packet.md`.',
    '- `preflight.json` must pass before a recorded run starts.',
    '- Deterministic checks and hidden-style assertions are preferred for primary scoring.',
    '- `gpt-5.5` review is used for failure audit, quality control, and explanation, not as the only score source.',
    '- Completion, timeout, wall time, review findings, evidence quality, and task-class fit are reported separately.',
    '',
    '## Conditions And Results',
    ''
) + $conditionTableLines + @(
    '',
    '## How To Read The Result',
    '',
    'Small differences should be treated as directional until the task count is large enough. A condition can be useful even when it is not the top scorer, if it has a better speed-to-quality tradeoff or produces cleaner evidence for winsmux operation.',
    '',
    '## Chart Outputs',
    '',
    ('- Chart data: `' + $chartDataPath + '`'),
    ('- GPT image 2.0 prompts: `' + $chartPromptPath + '`'),
    '',
    'Recommended charts:',
    '',
    '- Completion or pass rate by condition.',
    '- Median wall time by condition.',
    '- Speed-quality scatter plot.',
    '- Capability radar chart.',
    '- Task-class fit heatmap.',
    '',
    '## References',
    '',
    '- https://nyosegawa.com/posts/harness-bench/',
    '- https://nyosegawa.com/posts/harness-bench-antigravity-composer-25/',
    ''
)
$articleLines | Set-Content -LiteralPath $articleReportPath -Encoding UTF8

$chartPromptLines = @(
    '# GPT image 2.0 Chart Prompts',
    '',
    'Use GPT image 2.0 for every final chart image. Use the data in `chart-data.json`; do not invent scores, pass counts, or wall times.',
    '',
    '## Visual Direction',
    '',
    'Create a polished benchmark-report visual style: clean white or deep charcoal background, precise gridlines, high-contrast labels, readable axis titles, and restrained accent colors. The chart should look suitable for a technical blog post and a product demo slide.',
    '',
    '## Prompt: Pass Or Completion Rate',
    '',
    'Use GPT image 2.0 to create a high-quality horizontal bar chart from `chart-data.json`. Show each condition as `CLI / Model / Effort`. Plot completion rate only for started runs, or pass rate when pass data is available. Show pending runs as a separate neutral badge, not as failures. Sort descending. Include counts next to each bar. Add a small footnote: "Small differences are directional unless the task count is large enough."',
    '',
    '## Prompt: Median Wall Time',
    '',
    'Use GPT image 2.0 to create a high-quality median wall-time chart from `chart-data.json`. Show minutes or seconds consistently. Highlight the fastest condition and mark timeout count as a small badge. Keep labels readable at 16:9 and 4:3 crops.',
    '',
    '## Prompt: Speed-Quality Scatter',
    '',
    'Use GPT image 2.0 to create a high-quality scatter plot from `chart-data.json`. X axis is median wall time; Y axis is average overall score, or completion rate if overall score is unavailable. Place the best speed-quality balance in the upper-left region. Label every point directly.',
    '',
    '## Prompt: Capability Radar',
    '',
    'Use GPT image 2.0 to create a high-quality radar chart for accuracy, review findings, speed, parallelism, async terminal, and evidence quality. Use one translucent polygon per condition. Avoid clutter; if more than five conditions exist, split into two panels.',
    '',
    '## Prompt: Task-Class Heatmap',
    '',
    'Use GPT image 2.0 to create a high-quality heatmap from `chart-data.json`. Rows are task classes. Columns are conditions. Color is average overall score, or completion rate if score is unavailable. Include a legend and explain missing values as "not enough scored runs".',
    ''
)
$chartPromptLines | Set-Content -LiteralPath $chartPromptPath -Encoding UTF8

$htmlReportPath = Join-Path $OutputDir 'benchmark-report.html'
$htmlReport = New-BakeoffHtmlReport -ReportData $chartData
$htmlReport | Set-Content -LiteralPath $htmlReportPath -Encoding UTF8

$referenceReportDir = Join-Path (Join-Path $resolvedProjectDir '.references') 'benchmark-reports'
New-Item -ItemType Directory -Path $referenceReportDir -Force | Out-Null
$referenceHtmlReportPath = Join-Path $referenceReportDir 'cli-bakeoff-benchmark-report.html'
$htmlReport | Set-Content -LiteralPath $referenceHtmlReportPath -Encoding UTF8

$output = [ordered]@{
    run_count = @($runs).Count
    output_dir = (Resolve-Path -LiteralPath $OutputDir).Path
    raw_score_matrix = $rawScorePath
    chart_data = $chartDataPath
    article_report = $articleReportPath
    benchmark_report_html = $htmlReportPath
    reference_benchmark_report_html = $referenceHtmlReportPath
    gpt_image_2_chart_prompts = $chartPromptPath
    model_task_fit = $fitPath
    assignment_policy = $assignmentPath
    model_evidence_profile = $profilePath
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
} else {
    Write-Output "summarized CLI bakeoff runs: $($output.output_dir)"
}
