[CmdletBinding()]
param(
    [string]$PipeName = 'winsmux-rpc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RpcBridgeScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\psmux-bridge.ps1'))
$script:RpcRoleGateScriptPath = Join-Path $PSScriptRoot 'role-gate.ps1'
$script:RpcSharedTaskScriptPath = Join-Path $PSScriptRoot 'shared-task-list.ps1'
$script:RpcServerState = @{
    PipeName      = $PipeName
    StopRequested = $false
    IsRunning     = $false
    CurrentServer = $null
}

. $script:RpcRoleGateScriptPath
. $script:RpcSharedTaskScriptPath

function Get-RpcPowerShellPath {
    $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $currentProcess -and -not [string]::IsNullOrWhiteSpace($currentProcess.Path)) {
        return $currentProcess.Path
    }

    foreach ($candidate in @('pwsh', 'powershell')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
                return $command.Source
            }

            return $command.Name
        }
    }

    throw 'Could not find a PowerShell executable for bridge command invocation.'
}

function ConvertTo-RpcHashtable {
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[[string]$key] = $InputObject[$key]
        }

        return $hash
    }

    $hash = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $hash[$property.Name] = $property.Value
    }

    return $hash
}

function Test-RpcHasProperty {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Hashtable,
        [Parameter(Mandatory)][string]$Name
    )

    return $Hashtable.Contains($Name)
}

function Get-RequiredRpcString {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Params,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-RpcHasProperty -Hashtable $Params -Name $Name)) {
        throw [System.ArgumentException]::new("Missing required parameter: $Name")
    }

    $value = [string]$Params[$Name]
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw [System.ArgumentException]::new("Parameter '$Name' must not be empty.")
    }

    return $value
}

function Get-OptionalRpcInt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Params,
        [Parameter(Mandatory)][string]$Name,
        [int]$Default
    )

    if (-not (Test-RpcHasProperty -Hashtable $Params -Name $Name)) {
        return $Default
    }

    try {
        return [int]$Params[$Name]
    } catch {
        throw [System.ArgumentException]::new("Parameter '$Name' must be an integer.")
    }
}

function Get-RpcStringArray {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Params,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-RpcHasProperty -Hashtable $Params -Name $Name)) {
        return @()
    }

    $value = $Params[$Name]
    if ($value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            return @()
        }

        return @($value)
    }

    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        $items = @()
        foreach ($item in $value) {
            if ($null -eq $item) {
                continue
            }

            $items += [string]$item
        }

        return $items
    }

    throw [System.ArgumentException]::new("Parameter '$Name' must be a string or array of strings.")
}

function New-RpcSuccessResponse {
    param(
        [AllowNull()]$Id,
        [AllowNull()]$Result
    )

    return [ordered]@{
        jsonrpc = '2.0'
        result  = $Result
        id      = $Id
    }
}

function New-RpcErrorResponse {
    param(
        [AllowNull()]$Id,
        [int]$Code,
        [string]$Message,
        [AllowNull()]$Data
    )

    $errorBody = [ordered]@{
        code    = $Code
        message = $Message
    }

    if ($null -ne $Data) {
        $errorBody.data = $Data
    }

    return [ordered]@{
        jsonrpc = '2.0'
        error   = $errorBody
        id      = $Id
    }
}

function Assert-RpcRole {
    param(
        [AllowNull()][string]$Role,
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][string]$TargetPane
    )

    $resolvedRole = if ([string]::IsNullOrWhiteSpace($Role)) { $env:WINSMUX_ROLE } else { $Role }
    if ([string]::IsNullOrWhiteSpace($resolvedRole)) {
        throw [System.UnauthorizedAccessException]::new('WINSMUX_ROLE not set.')
    }

    $canonicalRole = ConvertTo-CanonicalWinsmuxRole $resolvedRole
    if ($null -eq $canonicalRole) {
        throw [System.UnauthorizedAccessException]::new("Invalid WINSMUX_ROLE: $resolvedRole")
    }

    $originalRole = $env:WINSMUX_ROLE
    try {
        $env:WINSMUX_ROLE = $canonicalRole
        $allowed = & { Assert-Role -Command $Command -TargetPane $TargetPane } 2>$null
    } finally {
        if ($null -eq $originalRole) {
            Remove-Item Env:WINSMUX_ROLE -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_ROLE = $originalRole
        }
    }

    if (-not $allowed) {
        throw [System.UnauthorizedAccessException]::new("DENIED: [$canonicalRole] cannot execute [$Command]")
    }

    return $canonicalRole
}

function Invoke-RpcBridgeCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [AllowNull()][string]$Role
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-RpcPowerShellPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.ArgumentList.Add('-NoProfile') | Out-Null
    $startInfo.ArgumentList.Add('-File') | Out-Null
    $startInfo.ArgumentList.Add($script:RpcBridgeScriptPath) | Out-Null

    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add([string]$argument) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        $startInfo.Environment['WINSMUX_ROLE'] = $Role
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = ''
    $stderr = ''
    $exitCode = 1
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    return [PSCustomObject]@{
        Arguments = @($Arguments)
        ExitCode  = $exitCode
        StdOut    = [regex]::Replace($stdout, '(?:\r?\n)+$', '')
        StdErr    = [regex]::Replace($stderr, '(?:\r?\n)+$', '')
    }
}

function ConvertFrom-RpcCliResult {
    param([Parameter(Mandatory)]$CliResult)

    if ($CliResult.ExitCode -ne 0) {
        $message = if (-not [string]::IsNullOrWhiteSpace($CliResult.StdErr)) {
            $CliResult.StdErr
        } elseif (-not [string]::IsNullOrWhiteSpace($CliResult.StdOut)) {
            $CliResult.StdOut
        } else {
            "Bridge command failed with exit code $($CliResult.ExitCode)."
        }

        throw [System.InvalidOperationException]::new($message)
    }

    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($CliResult.StdOut)) {
        $lines = @($CliResult.StdOut -split '\r?\n')
    }

    return [ordered]@{
        command = @($CliResult.Arguments) -join ' '
        output  = $CliResult.StdOut
        lines   = $lines
    }
}

function Invoke-RpcBridgeRead {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $target = Get-RequiredRpcString -Params $Params -Name 'target'
    $lines = Get-OptionalRpcInt -Params $Params -Name 'lines' -Default 200
    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }

    $resolvedRole = Assert-RpcRole -Role $role -Command 'read' -TargetPane $target
    $cliResult = Invoke-RpcBridgeCli -Arguments @('read', $target, [string]$lines) -Role $resolvedRole
    $result = ConvertFrom-RpcCliResult -CliResult $cliResult
    $result.target = $target
    $result.text = $cliResult.StdOut
    return $result
}

function Invoke-RpcBridgeSend {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $target = Get-RequiredRpcString -Params $Params -Name 'target'
    $text = Get-RequiredRpcString -Params $Params -Name 'text'
    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }

    $resolvedRole = Assert-RpcRole -Role $role -Command 'send' -TargetPane $target
    $cliResult = Invoke-RpcBridgeCli -Arguments @('send', $target, $text) -Role $resolvedRole
    $result = ConvertFrom-RpcCliResult -CliResult $cliResult
    $result.target = $target
    return $result
}

function ConvertFrom-RpcHealthCliResult {
    param([Parameter(Mandatory)]$CliResult)

    $result = ConvertFrom-RpcCliResult -CliResult $CliResult
    $items = @()
    foreach ($line in $result.lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split '\s+', 3
        if ($parts.Count -lt 3) {
            continue
        }

        $items += [ordered]@{
            label  = $parts[0]
            paneId = $parts[1]
            status = $parts[2]
        }
    }

    $result.items = $items
    return $result
}

function Invoke-RpcBridgeHealth {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }
    $resolvedRole = Assert-RpcRole -Role $role -Command 'health-check' -TargetPane $null
    $cliResult = Invoke-RpcBridgeCli -Arguments @('health-check') -Role $resolvedRole
    return ConvertFrom-RpcHealthCliResult -CliResult $cliResult
}

function Invoke-RpcBridgeList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }
    $resolvedRole = Assert-RpcRole -Role $role -Command 'list' -TargetPane $null
    $cliResult = Invoke-RpcBridgeCli -Arguments @('list') -Role $resolvedRole
    return ConvertFrom-RpcCliResult -CliResult $cliResult
}

function Invoke-RpcBridgeVaultGet {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $key = Get-RequiredRpcString -Params $Params -Name 'key'
    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }

    $resolvedRole = Assert-RpcRole -Role $role -Command 'vault' -TargetPane $null
    $cliResult = Invoke-RpcBridgeCli -Arguments @('vault', 'get', $key) -Role $resolvedRole
    $result = ConvertFrom-RpcCliResult -CliResult $cliResult
    $result.key = $key
    $result.value = $cliResult.StdOut
    return $result
}

function Invoke-RpcBridgeVaultInject {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $target = Get-RequiredRpcString -Params $Params -Name 'target'
    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }

    $resolvedRole = Assert-RpcRole -Role $role -Command 'vault' -TargetPane $target
    $cliResult = Invoke-RpcBridgeCli -Arguments @('vault', 'inject', $target) -Role $resolvedRole
    $result = ConvertFrom-RpcCliResult -CliResult $cliResult
    $result.target = $target
    return $result
}

function Invoke-RpcBridgeDispatch {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }
    $target = if (Test-RpcHasProperty -Hashtable $Params -Name 'target') { [string]$Params['target'] } else { $null }

    $resolvedRole = Assert-RpcRole -Role $role -Command 'dispatch' -TargetPane $target

    $arguments = @('dispatch')
    if (Test-RpcHasProperty -Hashtable $Params -Name 'args') {
        $arguments += Get-RpcStringArray -Params $Params -Name 'args'
    } else {
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            $arguments += $target
        }

        if (Test-RpcHasProperty -Hashtable $Params -Name 'text') {
            $text = [string]$Params['text']
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $arguments += $text
            }
        }

        if (Test-RpcHasProperty -Hashtable $Params -Name 'rest') {
            $arguments += Get-RpcStringArray -Params $Params -Name 'rest'
        }
    }

    $cliResult = Invoke-RpcBridgeCli -Arguments $arguments -Role $resolvedRole
    return ConvertFrom-RpcCliResult -CliResult $cliResult
}

function Invoke-RpcTaskList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }
    $resolvedRole = Assert-RpcRole -Role $role -Command 'tasks.list' -TargetPane $null
    return [ordered]@{
        role  = $resolvedRole
        tasks = @(Get-SharedTasks)
    }
}

function Invoke-RpcTaskClaim {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $taskId = Get-RequiredRpcString -Params $Params -Name 'taskId'
    $agent = Get-RequiredRpcString -Params $Params -Name 'agent'
    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }

    $resolvedRole = Assert-RpcRole -Role $role -Command 'tasks.claim' -TargetPane $null
    $claimResult = Claim-SharedTask -TaskId $taskId -AgentName $agent

    return [ordered]@{
        role   = $resolvedRole
        taskId = $taskId
        result = $claimResult
    }
}

function Invoke-RpcTaskComplete {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Params)

    $taskId = Get-RequiredRpcString -Params $Params -Name 'taskId'
    $role = if (Test-RpcHasProperty -Hashtable $Params -Name 'role') { [string]$Params['role'] } else { $null }

    $resolvedRole = Assert-RpcRole -Role $role -Command 'tasks.complete' -TargetPane $null
    $task = Complete-SharedTask -TaskId $taskId

    return [ordered]@{
        role = $resolvedRole
        task = $task
    }
}

function Invoke-RpcMethod {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Params
    )

    switch ($Method) {
        'bridge.read'           { return Invoke-RpcBridgeRead -Params $Params }
        'bridge.send'           { return Invoke-RpcBridgeSend -Params $Params }
        'bridge.health'         { return Invoke-RpcBridgeHealth -Params $Params }
        'bridge.list'           { return Invoke-RpcBridgeList -Params $Params }
        'bridge.vault.get'      { return Invoke-RpcBridgeVaultGet -Params $Params }
        'bridge.vault.inject'   { return Invoke-RpcBridgeVaultInject -Params $Params }
        'bridge.dispatch'       { return Invoke-RpcBridgeDispatch -Params $Params }
        'bridge.tasks.list'     { return Invoke-RpcTaskList -Params $Params }
        'bridge.tasks.claim'    { return Invoke-RpcTaskClaim -Params $Params }
        'bridge.tasks.complete' { return Invoke-RpcTaskComplete -Params $Params }
        default {
            throw [System.Management.Automation.ItemNotFoundException]::new("Method not found: $Method")
        }
    }
}

function Invoke-RpcRequest {
    param([Parameter(Mandatory)]$Request)

    if ($Request -isnot [System.Collections.IDictionary]) {
        throw [System.ArgumentException]::new('Request must be a JSON object.')
    }

    if (@($Request).Count -eq 0) {
        throw [System.ArgumentException]::new('Request must not be empty.')
    }

    $requestMap = ConvertTo-RpcHashtable -InputObject $Request
    $requestId = if (Test-RpcHasProperty -Hashtable $requestMap -Name 'id') { $requestMap['id'] } else { $null }

    try {
        if (-not (Test-RpcHasProperty -Hashtable $requestMap -Name 'jsonrpc') -or [string]$requestMap['jsonrpc'] -ne '2.0') {
            throw [System.ArgumentException]::new("Invalid Request: jsonrpc must be '2.0'.")
        }

        if (-not (Test-RpcHasProperty -Hashtable $requestMap -Name 'method')) {
            throw [System.ArgumentException]::new('Invalid Request: method is required.')
        }

        $method = [string]$requestMap['method']
        if ([string]::IsNullOrWhiteSpace($method)) {
            throw [System.ArgumentException]::new('Invalid Request: method must not be empty.')
        }

        $params = @{}
        if (Test-RpcHasProperty -Hashtable $requestMap -Name 'params') {
            if ($null -eq $requestMap['params']) {
                $params = @{}
            } elseif ($requestMap['params'] -is [System.Collections.IDictionary] -or ($requestMap['params'] -isnot [string] -and $requestMap['params'] -isnot [System.Array] -and $requestMap['params'].PSObject.Properties.Count -gt 0)) {
                $params = ConvertTo-RpcHashtable -InputObject $requestMap['params']
            } else {
                throw [System.ArgumentException]::new('Invalid params: params must be an object.')
            }
        }

        $result = Invoke-RpcMethod -Method $method -Params $params
        return New-RpcSuccessResponse -Id $requestId -Result $result
    } catch [System.Management.Automation.ItemNotFoundException] {
        return New-RpcErrorResponse -Id $requestId -Code -32601 -Message $_.Exception.Message -Data $null
    } catch [System.ArgumentException] {
        $code = if ($_.Exception.Message -like 'Invalid Request:*' -or $_.Exception.Message -eq 'Request must be a JSON object.' -or $_.Exception.Message -eq 'Request must not be empty.') { -32600 } else { -32602 }
        return New-RpcErrorResponse -Id $requestId -Code $code -Message $_.Exception.Message -Data $null
    } catch [System.UnauthorizedAccessException] {
        return New-RpcErrorResponse -Id $requestId -Code -32001 -Message $_.Exception.Message -Data $null
    } catch {
        return New-RpcErrorResponse -Id $requestId -Code -32603 -Message $_.Exception.Message -Data $null
    }
}

function ConvertFrom-RpcRequestText {
    param([Parameter(Mandatory)][string]$RequestText)

    try {
        return $RequestText | ConvertFrom-Json -AsHashtable -Depth 32 -ErrorAction Stop
    } catch {
        throw [System.FormatException]::new('Parse error: invalid JSON payload.')
    }
}

function ConvertTo-RpcResponseText {
    param([Parameter(Mandatory)][string]$RequestText)

    try {
        $request = ConvertFrom-RpcRequestText -RequestText $RequestText
    } catch [System.FormatException] {
        $response = New-RpcErrorResponse -Id $null -Code -32700 -Message $_.Exception.Message -Data $null
        return $response | ConvertTo-Json -Depth 32 -Compress
    }

    $response = Invoke-RpcRequest -Request $request
    return $response | ConvertTo-Json -Depth 32 -Compress
}

function Read-RpcPipeMessage {
    param([Parameter(Mandatory)][System.IO.Pipes.NamedPipeServerStream]$Pipe)

    $buffer = New-Object byte[] 4096
    $stream = [System.IO.MemoryStream]::new()
    try {
        do {
            $bytesRead = $Pipe.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) {
                break
            }

            $stream.Write($buffer, 0, $bytesRead)
        } while (-not $Pipe.IsMessageComplete)

        return [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    } finally {
        $stream.Dispose()
    }
}

function Write-RpcPipeMessage {
    param(
        [Parameter(Mandatory)][System.IO.Pipes.NamedPipeServerStream]$Pipe,
        [Parameter(Mandatory)][string]$Message
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $Pipe.Write($bytes, 0, $bytes.Length)
    $Pipe.Flush()
}

function Wait-RpcClientConnection {
    param([Parameter(Mandatory)][System.IO.Pipes.NamedPipeServerStream]$Pipe)

    $waitTask = $Pipe.WaitForConnectionAsync()
    while (-not $waitTask.Wait(250)) {
        if ($script:RpcServerState.StopRequested) {
            return $false
        }
    }

    return $Pipe.IsConnected
}

function Start-RpcServer {
    param([string]$PipeName = $script:RpcServerState.PipeName)

    if ($script:RpcServerState.IsRunning) {
        throw 'RPC server is already running.'
    }

    $script:RpcServerState.IsRunning = $true
    $script:RpcServerState.StopRequested = $false
    $script:RpcServerState.PipeName = $PipeName

    try {
        while (-not $script:RpcServerState.StopRequested) {
            $server = [System.IO.Pipes.NamedPipeServerStream]::new(
                $PipeName,
                [System.IO.Pipes.PipeDirection]::InOut,
                1,
                [System.IO.Pipes.PipeTransmissionMode]::Message,
                [System.IO.Pipes.PipeOptions]::Asynchronous
            )
            $script:RpcServerState.CurrentServer = $server

            try {
                if (-not (Wait-RpcClientConnection -Pipe $server)) {
                    continue
                }

                $server.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message
                $requestText = Read-RpcPipeMessage -Pipe $server
                $responseText = ConvertTo-RpcResponseText -RequestText $requestText
                Write-RpcPipeMessage -Pipe $server -Message $responseText
            } catch [System.ObjectDisposedException] {
                if (-not $script:RpcServerState.StopRequested) {
                    throw
                }
            } finally {
                if ($server.IsConnected) {
                    $server.Disconnect()
                }

                $server.Dispose()
                $script:RpcServerState.CurrentServer = $null
            }
        }
    } finally {
        $script:RpcServerState.IsRunning = $false
        $script:RpcServerState.CurrentServer = $null
    }
}

function Stop-RpcServer {
    $script:RpcServerState.StopRequested = $true

    if ($null -ne $script:RpcServerState.CurrentServer) {
        try {
            $script:RpcServerState.CurrentServer.Dispose()
        } catch {
        } finally {
            $script:RpcServerState.CurrentServer = $null
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-RpcServer -PipeName $PipeName
}
