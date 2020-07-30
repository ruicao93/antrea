function Get-WebFileIfNotExist($Path, $URL) {
    if (Test-Path $Path) {
        return
    }
    Write-Host "Downloading $URL to $PATH"
    curl.exe -sLo $Path $URL
}

function New-DirectoryIfNotExist($Path)
{
    if (!(Test-Path $Path))
    {
        mkdir $Path
    }
}

function Test-ConnectionWithRetry($ComputerName, $Port, $MaxRetry, $Interval) {
    $RetryCountRange = 1..$MaxRetry
    foreach ($RetryCount in $RetryCountRange) {
        Write-Host "Testing connection to ($ComputerName,$Port) ($RetryCount/$MaxRetry)..."
        if (Test-NetConnection -ComputerName $ComputerName -Port $Port | ? { $_.TcpTestSucceeded }) {
            return $true
        }
        if ($RetryCount -eq $MaxRetry) {
            return $false
        }
        Start-Sleep -Seconds $Interval
    }
}

function Get-GithubLatestReleaseTag($Owner, $Repo) {
    return (curl.exe -s "https://api.github.com/repos/$Owner/$Repo/releases" | ConvertFrom-Json)[0].tag_name
}

function Install-AntreaAgent {
    Param(
        [parameter(Mandatory = $false, HelpMessage="Kubernetes version to use")] [string] $KubernetesVersion="v1.18.0",
        [parameter(Mandatory = $false, HelpMessage="Kubernetes home path")] [string] $KubernetesHome="c:\k",
        [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
        [parameter(Mandatory = $false, HelpMessage="Antrea version to use")] [string] $AntreaVersion="latest",
        [parameter(Mandatory = $false, HelpMessage="Antrea home path")] [string] $AntreaHome="c:\k\antrea"
    )

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
        $AntreaVersion = (Get-GithubLatestReleaseTag $Owner $Repo)
    }
    Write-Host "Antrea version: $AntreaVersion"
    $AntreaRawUrlBase = "https://raw.githubusercontent.com/$Owner/$Repo/$AntreaVersion"
    $AntreaReleaseUrlBase = "https://github.com/$Owner/$Repo/releases/download"
    $AntreaRawUrlBase = "https://raw.githubusercontent.com/$Owner/$Repo/$AntreaVersion"


    New-DirectoryIfNotExist $KubernetesHome
    # Download kubectl
    Get-WebFileIfNotExist $kubectl  "https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/kubectl.exe"
    # Download kube-proxy
    Get-WebFileIfNotExist $KubeProxy "https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/kube-proxy.exe"
    # Download yq
    Get-WebFileIfNotExist $yq "https://github.com/mikefarah/yq/releases/download/3.3.2/yq_windows_amd64.exe"

    New-DirectoryIfNotExist $AntreaHome
    New-DirectoryIfNotExist "$AntreaHome\bin"
    New-DirectoryIfNotExist "$CNIPath"
    New-DirectoryIfNotExist "$CNIConfigPath"
    # Download antrea-agent for windows
    Get-WebFileIfNotExist $AntreaAgent  "$AntreaReleaseUrlBase/$AntreaVersion/antrea-agent-windows-x86_64.exe"
    Get-WebFileIfNotExist $AntreaCNI  "$AntreaReleaseUrlBase/$AntreaVersion/antrea-cni-windows-x86_64.exe"
    # Prepare antrea scripts
    Get-WebFileIfNotExist $PrepareServiceInterface  "$AntreaRawUrlBase/hack/windows/Prepare-ServiceInterface.ps1"
    Get-WebFileIfNotExist $StartKubeProxy  "$AntreaRawUrlBase/hack/windows/Start-KubeProxy.ps1"
    Get-WebFileIfNotExist $StartAntreaAgent  "$AntreaRawUrlBase/hack/windows/Start-AntreaAgent.ps1"
    Get-WebFileIfNotExist $StopScript  "$AntreaRawUrlBase/hack/windows/Stop.ps1"

    # Download host-local IPAM plugin
    if (!(Test-Path $HostLocalIpam)) {
        curl.exe -sLO https://github.com/containernetworking/plugins/releases/download/v0.8.1/cni-plugins-windows-amd64-v0.8.1.tgz
        C:\Windows\system32\tar.exe -xzf cni-plugins-windows-amd64-v0.8.1.tgz  -C $CNIPath "./host-local.exe"
        Remove-Item cni-plugins-windows-amd64-v0.8.1.tgz
    }

    New-DirectoryIfNotExist $AntreaEtc
    Get-WebFileIfNotExist $AntreaCNIConfigFile "$AntreaRawUrlBase/build/yamls/windows/base/conf/antrea-cni.conflist"
    if (!(Test-Path $AntreaAgentConfigPath)) {
        Get-WebFileIfNotExist $AntreaAgentConfigPath "$AntreaRawUrlBase/build/yamls/windows/base/conf/antrea-agent.conf"
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
}

function New-KubeProxyServiceInterface {
    Param(
        [parameter(Mandatory = $false, HelpMessage="Interface to be added service IPs by kube-proxy")] [string] $InterfaceAlias="HNS Internal NIC"
    )

    $INTERFACE_TO_ADD_SERVICE_IP = "vEthernet ($InterfaceAlias)"
    Write-Host "Creating netadapter $INTERFACE_TO_ADD_SERVICE_IP for kube-proxy"
    if (Get-NetAdapter -InterfaceAlias $INTERFACE_TO_ADD_SERVICE_IP -ErrorAction SilentlyContinue) {
        Write-Host "NetAdapter $INTERFACE_TO_ADD_SERVICE_IP exists, exit."
        return
    }
    [Environment]::SetEnvironmentVariable("INTERFACE_TO_ADD_SERVICE_IP", $INTERFACE_TO_ADD_SERVICE_IP, [System.EnvironmentVariableTarget]::Machine)
    $hnsSwitchName = $(Get-VMSwitch -SwitchType Internal).Name
    Add-VMNetworkAdapter -ManagementOS -Name $InterfaceAlias -SwitchName $hnsSwitchName
    Set-NetIPInterface -ifAlias $INTERFACE_TO_ADD_SERVICE_IP -Forwarding Enabled
}

function Start-KubeProxy {
    Param(
        [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeProxy = "c:\k\kube-proxy.exe",
        [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
        [parameter(Mandatory = $false)] [string] $LogDir = "c:\var\log\kube-proxy"
    )

    if (Get-Process -Name kube-proxy -ErrorAction SilentlyContinue) {
        Write-Host "kube-proxy is already in running, exit"
        return
    }

    New-DirectoryIfNotExist $LogDir

    New-KubeProxyServiceInterface

    Start-Process -FilePath $KubeProxy -ArgumentList "--proxy-mode=userspace --kubeconfig=$KubeConfig --log-dir=$LogDir --logtostderr=false --alsologtostderr --v=4"
}

function Start-AntreaAgent {
    Param(
        [parameter(Mandatory = $false, HelpMessage="Antrea home path")] [string] $AntreaHome="c:\k\antrea",
        [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
        [parameter(Mandatory = $false)] [string] $LogDir
    )

    if (Get-Process -Name antrea-agent -ErrorAction SilentlyContinue) {
        Write-Host "antrea-agent is already in running, exit"
        return
    }

    $AntreaAgent = "$AntreaHome\bin\antrea-agent.exe"
    $AntreaAgentConfigPath = "$AntreaHome\etc\antrea-agent.conf"
    if ($LogDir -eq "") {
        $LogDir = "$AntreaHome\logs"
    }
    New-DirectoryIfNotExist $LogDir
    [Environment]::SetEnvironmentVariable("NODE_NAME", (hostname).ToLower())
    Start-Process -FilePath $AntreaAgent  -ArgumentList "--config=$AntreaAgentConfigPath --logtostderr=false --log_dir=$LogDir --alsologtostderr --log_file_max_size=100 --log_file_max_num=4"
}

Export-ModuleMember Get-WebFileIfNotExist
Export-ModuleMember New-DirectoryIfNotExist
Export-ModuleMember Test-ConnectionWithRetry
Export-ModuleMember Install-AntreaAgent
Export-ModuleMember New-KubeProxyServiceInterface
Export-ModuleMember Start-KubeProxy
Export-ModuleMember Start-AntreaAgent
