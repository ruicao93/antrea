Param(
    [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeProxy = "c:\k\kube-proxy.exe",
    [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
    [parameter(Mandatory = $false)] [string] $LogDir = "c:\var\log\kube-proxy"
)
$ErrorActionPreference = "Stop"

$PrepareServiceInterface = "c:\k\antrea\Prepare-ServiceInterface.ps1"
Import-Module c:\k\antrea\Helper.psm1

if (Get-Process -Name kube-proxy -ErrorAction SilentlyContinue) {
    Write-Host "kube-proxy is already in running, exit"
    exit 0
}

CreateDirectory $LogDir

powershell $PrepareServiceInterface

if ($LastExitCode) {
    Write-Host "Prepare kube-proxy service interface failed, exit"
    exit 1
}

& $KubeProxy --proxy-mode=userspace --kubeconfig=$KubeConfig --log-dir=$LogDir --logtostderr=false --alsologtostderr --v=4
