Param(
    [parameter(Mandatory = $false, HelpMessage="Kubernetes version to use")] [string] $KubernetesVersion="v1.18.0",
    [parameter(Mandatory = $false, HelpMessage="Kubernetes home path")] [string] $KubernetesHome="c:\k",
    [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
    [parameter(Mandatory = $false, HelpMessage="Antrea version to use")] [string] $AntreaVersion="latest",
    [parameter(Mandatory = $false, HelpMessage="Antrea home path")] [string] $AntreaHome="c:\k\antrea"
)
$ErrorActionPreference = "Stop"


$kubectl = "$KubernetesHome\kubectl.exe"
$KubeProxy = "$KubernetesHome\kube-proxy.exe"
$yq = "$KubernetesHome\yq.exe"

$CNIPath = "c:\opt\cni\bin"
$CNIConfigPath = "c:\etc\cni\net.d"
$AntreaCNIConfigFile = "$CNIPath\10-antrea.conflist"
$HostLocalIpam = "$CNIPath\host-local.exe"

$AntreaEtc = "$AntreaHome\etc"
$AntreaAgentConfigPath = "$AntreaEtc\antrea-agent.conf"
$AntreaAgent = "$AntreaHome\bin\antrea-agent.exe"
$AntreaCNI = "$CNIPath\antrea.exe"
$PrepareServiceInterface = "$AntreaHome\Prepare-ServiceInterface.ps1"
$StartKubeProxy = "$AntreaHome\Start-KubeProxy.ps1"
$StartAntreaAgent = "$AntreaHome\Start-AntreaAgent.ps1"
$StopScript = "$AntreaHome\Stop.ps1"
$Owner = "vmware-tanzu"
$Repo = "antrea"

$env:Path = "$KubernetesHome;" + $env:Path
$helper = "$AntreaHome\Helper.psm1"
Import-Module $helper

if ($AntreaVersion -eq "latest") {
    $AntreaVersion = (GetGithubLatestReleaseTag $Owner $Repo)
}
Write-Host "Antrea version: $AntreaVersion"
$AntreaRawUrlBase = "https://raw.githubusercontent.com/$Owner/$Repo/$AntreaVersion"
$AntreaReleaseUrlBase = "https://github.com/$Owner/$Repo/releases/download"
$AntreaRawUrlBase = "https://raw.githubusercontent.com/$Owner/$Repo/$AntreaVersion"


CreateDirectory $KubernetesHome
# Download kubectl
DownloadFileIfNotExist $kubectl  "https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/kubectl.exe"
# Download kube-proxy
DownloadFileIfNotExist $KubeProxy "https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/kube-proxy.exe"
# Download yq
DownloadFileIfNotExist $yq "https://github.com/mikefarah/yq/releases/download/3.3.2/yq_windows_amd64.exe"

CreateDirectory $AntreaHome
CreateDirectory "$AntreaHome\bin"
CreateDirectory "$CNIPath"
CreateDirectory "$CNIConfigPath"
# Download antrea-agent for windows
DownloadFileIfNotExist $AntreaAgent  "$AntreaReleaseUrlBase/$AntreaVersion/antrea-agent-windows-x86_64.exe"
DownloadFileIfNotExist $AntreaCNI  "$AntreaReleaseUrlBase/$AntreaVersion/antrea-cni-windows-x86_64.exe"
# Prepare antrea scripts
DownloadFileIfNotExist $PrepareServiceInterface  "$AntreaRawUrlBase/hack/windows/Prepare-ServiceInterface.ps1"
DownloadFileIfNotExist $StartKubeProxy  "$AntreaRawUrlBase/hack/windows/Start-KubeProxy.ps1"
DownloadFileIfNotExist $StartAntreaAgent  "$AntreaRawUrlBase/hack/windows/Start-AntreaAgent.ps1"
DownloadFileIfNotExist $StopScript  "$AntreaRawUrlBase/hack/windows/Stop.ps1"

# Download host-local IPAM plugin
if (!(Test-Path $HostLocalIpam)) {
    curl.exe -sLO https://github.com/containernetworking/plugins/releases/download/v0.8.1/cni-plugins-windows-amd64-v0.8.1.tgz
    C:\Windows\system32\tar.exe -xzf cni-plugins-windows-amd64-v0.8.1.tgz  -C $CNIPath "./host-local.exe"
    Remove-Item cni-plugins-windows-amd64-v0.8.1.tgz
}

CreateDirectory $AntreaEtc
DownloadFileIfNotExist $AntreaCNIConfigFile "$AntreaRawUrlBase/build/yamls/windows/base/conf/antrea-cni.conflist"
if (!(Test-Path $AntreaAgentConfigPath)) {
    DownloadFileIfNotExist $AntreaAgentConfigPath "$AntreaRawUrlBase/build/yamls/windows/base/conf/antrea-agent.conf"
    yq w -i $AntreaAgentConfigPath featureGates.AntreaProxy true
    yq w -i $AntreaAgentConfigPath clientConnection.kubeconfig $AntreaEtc\antrea-agent.kubeconfig
    yq w -i $AntreaAgentConfigPath antreaClientConnection.kubeconfig $AntreaEtc\antrea-agent.antrea.kubeconfig
    $env:kubeconfig = $KubeConfig
    # Create the kubeconfig file that contains the K8s APIServer service and the token of antrea ServiceAccount.
    $APIServer=$(kubectl get service kubernetes -o jsonpath='{.spec.clusterIP}')
    $APIServerPort=$(kubectl get service kubernetes -o jsonpath='{.spec.ports[0].port}')
    $APIServer="https://$APIServer" + ":" + $APIServerPort
    $TOKEN=$(kubectl get secrets -n kube-system -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']=='antrea-agent')].data.token}")
    $TOKEN=$([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($TOKEN)))
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.kubeconfig set-cluster kubernetes --server=$APIServer --insecure-skip-tls-verify
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.kubeconfig set-credentials antrea-agent --token=$TOKEN
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.kubeconfig set-context antrea-agent@kubernetes --cluster=kubernetes --user=antrea-agent
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.kubeconfig use-context antrea-agent@kubernetes

    # Create the kubeconfig file that contains the antrea-controller APIServer service and the token of antrea ServiceAccount.
    $AntreaAPISServer=$(kubectl get service -n kube-system antrea -o jsonpath='{.spec.clusterIP}')
    $AntreaAPISServerPort=$(kubectl get service -n kube-system antrea -o jsonpath='{.spec.ports[0].port}')
    $AntreaAPISServer="https://$AntreaAPISServer" + ":" + $AntreaAPISServerPort
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.antrea.kubeconfig set-cluster antrea --server=$AntreaAPISServer --insecure-skip-tls-verify
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.antrea.kubeconfig set-credentials antrea-agent --token=$TOKEN
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.antrea.kubeconfig set-context antrea-agent@antrea --cluster=antrea --user=antrea-agent
    kubectl config --kubeconfig=$AntreaEtc\antrea-agent.antrea.kubeconfig use-context antrea-agent@antrea
}
