<#
.SYNOPSIS
    This script downloads NSX OVS and converts directory organization to a new zip file.

.DESCRIPTION
    This script downloads NSX OVS and converts directory organization to a new zip file.

.PARAMETER DownloadDir
    Specifies the path to download NSX OVS and Microsoft Visual C++ Redistributable packages.

.PARAMETER OVSUrl
    Specifies the download URL of NSX OVS.

.PARAMETER VCRedistUrl
    Specifies the download URL of Microsoft Visual C++ Redistributable packages.

.PARAMETER OutPutFile
    Specifies the output file path.

.EXAMPLE
    The example below does blah
    PS C:\> .\Get-NSXOVS.ps1

#>
Param(
    [parameter(Mandatory = $false)] [string] $DownloadDir,
    [parameter(Mandatory = $false)] [string] $OVSUrl,
    [parameter(Mandatory = $false)] [string] $VCRedistUrl,
    [parameter(Mandatory = $false)] [string] $OutPutFile = "ovs-win64.zip"
)
$ErrorActionPreference = "Stop"

function Log($Info) {
    $time = $(get-date -Format g)
    "$time $Info `n`r" | Tee-Object $InstallLog -Append | Write-Host
}

if (!$OVSUrl) {
    $OVSUrl = "http://build-squid.eng.vmware.com/build/mts/release/bora-17332456/publish/windows_x64/openvswitch_2.13.1.16806810-win64.zip"
}

if (!$VCRedistUrl) {
    $VCRedistUrl = "http://build-artifactory.eng.vmware.com/artifactory/nsbu-windows-local/vcredists.zip"
}

if (!$DownloadDir) {
    $DownloadDir = [System.IO.Path]::GetDirectoryName($myInvocation.MyCommand.Definition)
}

$TempDir = Join-Path -Path $DownloadDir -ChildPath "nsx-ovs-temp"

$InstallLog = "$DownloadDir\install_ovs.log"
$OVSZip = "$DownloadDir\nsx-ovs.zip"
$VCRedistZip = "$DownloadDir\vcredists.zip"

if (Test-Path -Path $OutPutFile) {
    Log "File $OutPutFile already exists"
    return
}

# Download nsx-ovs zip
if (!(Test-Path -Path $DownloadDir)) {
    mkdir -p $DownloadDir
}
if (!(Test-Path -Path $TempDir)) {
    mkdir -p $TempDir
}
Log "Using temp dir: $TempDir"
if (Test-Path -Path $OVSZip) {
    Log "File: $OVSZip already exists"
} else {
    Log "Downloading OVS package from $OVSUrl to $OVSZip"
    curl.exe -sLo $OVSZip $OVSUrl
}

if (Test-Path -Path $VCRedistZip) {
    Log "File: $VCRedistZip already exists"
} else {
    Log "Downloading Microsoft Visual C++ Redistributable package from $VCRedistUrl to $VCRedistZip"
    curl.exe -sLo $VCRedistZip $VCRedistUrl
}


# Expand nsx-ovs and vcredists zip
Log "Extracting $OVSZip to $DownloadDir"
Expand-Archive -Path $OVSZip -DestinationPath $TempDir | Out-Null
Log "Extracting $VCRedistZip to $DownloadDir"
Expand-Archive -Path $VCRedistZip -DestinationPath $TempDir | Out-Null

# Reorganize OVS directory to keep the dir structure same with upstream OVS
$OVSDir = "$TempDir/openvswitch"
$OVSDriverDir = "$OVSDir/driver"
$VCRedistDir = "$OVSDir/redist"
Move-Item $TempDir\include $OVSDir
Move-Item $TempDir\lib $OVSDir
Move-Item $TempDir\scripts $OVSDir
Move-Item $TempDir\vcredist2017 $VCRedistDir
Move-Item $TempDir\ovsext\win10_x64 $OVSDriverDir

# Generate new OVS zip
Log "Generating new OVS zip file: $OutPutFile"
Compress-Archive -Path "$TempDir\openvswitch" -DestinationPath $OutPutFile
Remove-Item -Recurse "$TempDir"
