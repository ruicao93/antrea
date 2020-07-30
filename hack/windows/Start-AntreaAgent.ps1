Param(
    [parameter(Mandatory = $false, HelpMessage="Antrea home path")] [string] $AntreaHome="c:\k\antrea",
    [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
    [parameter(Mandatory = $false)] [string] $LogDir
)
$ErrorActionPreference = "Stop"

if (Get-Process -Name antrea-agent -ErrorAction SilentlyContinue) {
    Write-Host "antrea-agent is already in running, exit"
    exit 0
}

Import-Module c:\k\antrea\Helper.psm1
$AntreaAgent = "$AntreaHome\bin\antrea-agent.exe"
$AntreaAgentConfigPath = "$AntreaHome\etc\antrea-agent.conf"
if ($LogDir -eq "") {
    $LogDir = "$AntreaHome\logs"
}

CreateDirectory $LogDir
[Environment]::SetEnvironmentVariable("NODE_NAME", (hostname).ToLower())
& $AntreaAgent  --config=$AntreaAgentConfigPath --logtostderr=false --log_dir=$LogDir --alsologtostderr --log_file_max_size=100 --log_file_max_num=4
