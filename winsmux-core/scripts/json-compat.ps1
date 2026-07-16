$script:WinsmuxJsonCommand = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
$script:WinsmuxJsonSupportsDepth = $script:WinsmuxJsonCommand.Parameters.ContainsKey('Depth')
$script:WinsmuxJsonSupportsHashtable = $script:WinsmuxJsonCommand.Parameters.ContainsKey('AsHashtable')

function ConvertFrom-WinsmuxJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][string]$Json,
        [ValidateRange(1, 1024)][int]$Depth = 1024,
        [switch]$AsHashtable
    )

    process {
        if ($AsHashtable -and -not $script:WinsmuxJsonSupportsHashtable) {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
            $serializer.MaxJsonLength = [int]::MaxValue
            $serializer.RecursionLimit = $Depth
            return $serializer.DeserializeObject($Json)
        }
        $arguments = @{}
        if ($script:WinsmuxJsonSupportsDepth) { $arguments['Depth'] = $Depth }
        if ($AsHashtable -and $script:WinsmuxJsonSupportsHashtable) {
            $arguments['AsHashtable'] = $true
        }
        return ($Json | ConvertFrom-Json @arguments)
    }
}
