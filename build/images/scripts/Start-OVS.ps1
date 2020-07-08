$ErrorActionPreference = "Stop"

$OVSDir = "/openvswitch"
$OVSSbinDir = "$OVSDir/usr/sbin"
$OVSBinDir = "$OVSDir/usr/bin"
$OVSRunDir = "$OVSDir/var/run/openvswitch"
$OVSEtcDir = "$OVSDir/etc/openvswitch"
$OVSDBSchemaPath = "$OVSDir/usr/share/openvswitch/vswitch.ovsschema"
$OVSDBFile = "$OVSEtcDir/conf.db"

$OVSDBJobSb = [scriptblock]::Create("$OVSSbinDir/ovsdb-server.exe $OVSDBFile  -vfile:info --remote=punix:db.sock  --remote=ptcp:6640  --log-file  --pidfile")
$OVSVswitchdJobSb = [scriptblock]::Create("$OVSSbinDir/ovs-vswitchd.exe --pidfile -vfile:info --log-file")

$OVSDBJob = $null
$OVSVswitchdJob = $null

$MaxRetry = 10
$CurRetry = 0
$RetryInterval = 5
$RemoveOVSDBFileOnExit = $False

function Log($Msg) {
    $time = $(get-date -Format g)
    Write-Host "$time $Msg"
}

function Log-Info($Msg) {
    Log("INFO: $Msg")
}

function Log-Warning($Msg) {
    Log("WARNING: $Msg")
}

function Log-Error($Msg) {
    Log("ERROR: $Msg")
}

function Get-RunningProcess([string] $Name) {
    return Get-Process $Name -ErrorAction SilentlyContinue
}

function Wait-Process([string] $Name, [int] $MaxRetry, [double] $RetryInterval) {
    $Retry = 0
    while ($Retry -le $MaxRetry) {
        if (Get-RunningProcess $Name) {
            return $true
        }
        $Retry += 1
        Start-Sleep -Seconds $RetryInterval
    }
    return $false
}

function CleanupOVSRunFiles {
    rm -Force $OVSRunDir/ovs*.pid -ErrorAction SilentlyContinue
    rm -Force $OVSRunDir/ovs*.ctl -ErrorAction SilentlyContinue
    rm -Force $OVSEtcDir/.conf.db.~lock~ -ErrorAction SilentlyContinue
}

function Start-OVS {
    $InitOVSDB = $false
    if ($(Test-Path $OVSDBSchemaPath) -and !$(Test-Path $OVSDBFile)) {
        Log-Info "Creating ovsdb file"
        if (-Not $(Test-Path $OVSDBSchemaPath)) {
            Log-Error "Create ovsdb file failed due to schema file not found: $OVSDBSchemaPath, exit"
            exit 1
        }
        ovsdb-tool.exe create "$OVSDBFile" "$OVSDBSchemaPath"
        $InitOVSDB = $true
        $script:RemoveOVSDBFileOnExit = $true
    }
    if(Get-RunningProcess ovsdb-server) {
        Log-Info "$ContainerName ovsdb-server is already running"
    } else {
        Log-Info "Starting ovsdb-server"
        $script:OVSDBJob = Start-Job -ScriptBlock $OVSDBJobSb
        $JobId = $script:OVSDBJob.Id
        Log-Info "Started ovsdb-server at job: $JobId"
    }
    if ($InitOVSDB) {
        $OVSVersion = ovs-vswitchd.exe --version | %{ $_.Split(' ')[-1]; }
        if ([string]::IsNullOrEmpty($OVSVersion)) {
            Log-Error "Create ovsdb file failed due to OVS version not found, exit"
            exit 1
        }
        if (-Not (Wait-Process ovsdb-server 20 0.5)) {
            Log-Error "Timeout to wait ovsdb-server start, exit "
            exit 1
        }
        ovs-vsctl.exe --no-wait set Open_vSwitch . ovs_version=$OVSVersion
        $script:RemoveOVSDBFileOnExit = $false
    }
    if(Get-RunningProcess ovs-vswitchd) {
        Log-Info "$ContainerName ovs-vswitchd is already running"
    } else {
        Log-Info "Starting ovs-vswitchd"
        $script:OVSVswitchdJob = Start-Job -ScriptBlock $OVSVswitchdJobSb
        $JobId = $script:OVSVswitchdJob.Id
        Log-Info "Started ovs-vswitchd at job: $JobId"
    }
}

function Stop-OVS {
    Log-Info "Stopping OVS"
    Stop-Process -Name ovsdb-server -ErrorAction SilentlyContinue -Force
    Stop-Process -Name ovs-vswitchd -ErrorAction SilentlyContinue -Force
    if ($RemoveOVSDBFileOnExit) {
        rm -Force $OVSDBFile
    }
}

function Quit {
    Log-Info "Stopping OVS before quit"
    Stop-OVS
    $host.SetShouldExit(0)
}

if (-Not $(Test-Path $OVSRunDir)) {
    mkdir -p $OVSRunDir
}

$env:Path += ";$OVSSbinDir;$OVSBinDir"

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Quit
}

Stop-OVS

CleanupOVSRunFiles

Get-VMSwitch -SwitchType External | Enable-VMSwitchExtension "Open vSwitch Extension"

Start-OVS

while ($CurRetry -le $MaxRetry) {
    Wait-Job -Id $OVSDBJob.id -Any
    $CurRetry += 1
    Log-Warning "OVS was stopped. Will retry($CurRetry/$MaxRetry) after $RetryInterval seconds..."
    Start-Sleep -Seconds $RetryInterval
    Start-OVS
}
