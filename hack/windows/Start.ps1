Param(
    [parameter(Mandatory = $false, HelpMessage="Kubernetes version to use")] [string] $KubernetesVersion="v1.18.0",
    [parameter(Mandatory = $false, HelpMessage="Kubernetes home path")] [string] $KubernetesHome="c:\k",
    [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
    [parameter(Mandatory = $false, HelpMessage="Antrea version to use")] [string] $AntreaVersion="latest",
    [parameter(Mandatory = $false, HelpMessage="Antrea home path")] [string] $AntreaHome="c:\k\antrea"
)
$ErrorActionPreference = "Stop"

$Owner = "vmware-tanzu"
$Repo = "antrea"
if ($AntreaVersion -eq "latest") {
    $AntreaVersion = (curl.exe -s "https://api.github.com/repos/$Owner/$Repo/releases" | ConvertFrom-Json)[0].tag_name
}
Write-Host "KubernetesVersion version: $KubernetesVersion"
Write-Host "Antrea version: $AntreaVersion"
$AntreaRawUrlBase = "https://raw.githubusercontent.com/$Owner/$Repo/$AntreaVersion"

if (!(Test-Path $AntreaHome)) {
    mkdir $AntreaHome
}

$helper = "$AntreaHome\Helper.psm1"
if (!(Test-Path $helper))
{
    curl.exe -sLo $helper "$AntreaRawUrlBase/hack/windows/Helper.psm1"
}
Import-Module $helper

Write-Host "Checking kube-proxy and antrea-agent installation..."
Install-AntreaAgent -KubernetesVersion $KubernetesVersion -KubernetesHome $KubernetesHome -KubeConfig $KubeConfig -AntreaVersion $AntreaVersion -AntreaHome $AntreaHome

if ($LastExitCode) {
    Write-Host "Install antrea-agent failed, exit"
    exit 1
}

Write-Host "Starting kube-proxy..."
Start-KubeProxy -KubeProxy $KubernetesHome\kube-proxy.exe -KubeConfig $KubeConfig

$env:kubeconfig = $KubeConfig
$APIServer=$(kubectl get service kubernetes -o jsonpath='{.spec.clusterIP}')
$APIServerPort=$(kubectl get service kubernetes -o jsonpath='{.spec.ports[0].port}')
$APIServer="https://$APIServer" + ":" + $APIServerPort
$APIServer=[System.Uri]$APIServer

Write-Host "Test connection to kubernetes API server"
$result = Test-ConnectionWithRetry $APIServer.Host $APIServer.Port 20 3
if (!$result) {
    Write-Host "Failed to connection to kubernetes API server service, exit"
    exit 1
}

Write-Host "Starting antrea-agent..."
Start-AntreaAgent -AntreaHome $AntreaHome -KubeConfig $KubeConfig
