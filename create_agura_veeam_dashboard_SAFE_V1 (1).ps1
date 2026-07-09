<#
SAFE script: Create or update a Zabbix dashboard for Agura Veeam backup job status.

What it does:
- Reads the existing Zabbix host AG-HQ-HV01-SM.
- Finds the six existing Veeam result_code items.
- Creates or updates ONE dashboard: "Agura - Veeam Backup Overview".
- Adds six Item value widgets as status tiles.
- Adds one Problems widget filtered by host + tag component=veeam.

What it does NOT do:
- It does not delete hosts.
- It does not delete items.
- It does not delete triggers.
- It does not change Veeam jobs.
#>

$ErrorActionPreference = "Stop"

$ZabbixApiUrl  = "https://10.222.50.102/zabbix/api_jsonrpc.php"
$HostName      = "AG-HQ-HV01-SM"
$DashboardName = "Agura - Veeam Backup Overview"

$Jobs = @(
    "AG-HQ-AP-CTRL Backup",
    "Backup Job Omeks VM",
    "Host and AD Backup",
    "Old_server_data Backup",
    "WF Backup",
    "Zabbix Proxy Backup"
)

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
catch {
}

$ApiToken = Read-Host "Paste Zabbix API token"

if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    throw "API token is empty. Stop."
}

$script:RpcId = 1

function Invoke-ZabbixApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$false)]$Params = @{}
    )

    $bodyObject = [ordered]@{
        jsonrpc = "2.0"
        method  = $Method
        params  = $Params
        id      = $script:RpcId
    }

    $script:RpcId++

    $body = $bodyObject | ConvertTo-Json -Depth 50

    $headers = @{
        Authorization = "Bearer $ApiToken"
    }

    $response = Invoke-RestMethod `
        -Uri $ZabbixApiUrl `
        -Method Post `
        -Headers $headers `
        -ContentType "application/json-rpc" `
        -Body $body

    if ($response.error) {
        $msg = $response.error.message
        $data = $response.error.data
        throw "Zabbix API error in method '$Method': $msg $data"
    }

    return $response.result
}

function FieldInt {
    param([string]$Name, [int]$Value)
    return @{
        type  = 0
        name  = $Name
        value = $Value
    }
}

function FieldStr {
    param([string]$Name, [string]$Value)
    return @{
        type  = 1
        name  = $Name
        value = $Value
    }
}

function FieldHost {
    param([string]$Name, [string]$Value)
    return @{
        type  = 3
        name  = $Name
        value = $Value
    }
}

function FieldItem {
    param([string]$Name, [string]$Value)
    return @{
        type  = 4
        name  = $Name
        value = $Value
    }
}

function New-VeeamStatusTile {
    param(
        [string]$JobName,
        [string]$ItemId,
        [int]$X,
        [int]$Y
    )

    return @{
        type      = "item"
        name      = $JobName
        x         = $X
        y         = $Y
        width     = 24
        height    = 5
        view_mode = 0
        fields    = @(
            (FieldItem "itemid.0" $ItemId)

            # Show description + value + time.
            (FieldInt "show.0" 1)
            (FieldInt "show.1" 2)
            (FieldInt "show.2" 3)

            # Description.
            (FieldStr "description" $JobName)
            (FieldInt "desc_h_pos" 1)
            (FieldInt "desc_v_pos" 0)
            (FieldInt "desc_size" 11)
            (FieldInt "desc_bold" 1)

            # Value.
            (FieldInt "value_h_pos" 1)
            (FieldInt "value_v_pos" 1)
            (FieldInt "value_size" 22)
            (FieldInt "value_bold" 1)
            (FieldInt "units_show" 0)

            # Time.
            (FieldInt "time_h_pos" 1)
            (FieldInt "time_v_pos" 2)
            (FieldInt "time_size" 9)

            # Dynamic background thresholds:
            # 0 Success, 1 Warning, 2 Failed, 3 Unknown/Error, 4 Running.
            (FieldStr "thresholds.0.color" "2ECC71")
            (FieldStr "thresholds.0.threshold" "0")
            (FieldStr "thresholds.1.color" "F1C40F")
            (FieldStr "thresholds.1.threshold" "1")
            (FieldStr "thresholds.2.color" "E74C3C")
            (FieldStr "thresholds.2.threshold" "2")
            (FieldStr "thresholds.3.color" "95A5A6")
            (FieldStr "thresholds.3.threshold" "3")
            (FieldStr "thresholds.4.color" "3498DB")
            (FieldStr "thresholds.4.threshold" "4")
        )
    }
}

Write-Host "Skipping apiinfo.version check..." -ForegroundColor Cyan

Write-Host "Finding host '$HostName'..." -ForegroundColor Cyan
$hosts = Invoke-ZabbixApi -Method "host.get" -Params @{
    output = @("hostid","host","name")
    filter = @{
        host = @($HostName)
    }
}

if (-not $hosts -or $hosts.Count -eq 0) {
    throw "Host '$HostName' was not found by technical host name."
}

$hostObj = $hosts[0]
$hostId = [string]$hostObj.hostid
Write-Host "Host found: $($hostObj.host) / hostid=$hostId" -ForegroundColor Green

$itemsByJob = @{}

foreach ($job in $Jobs) {
    $key = 'veeam.job["' + $job + '","result_code"]'

    $items = Invoke-ZabbixApi -Method "item.get" -Params @{
        output = @("itemid","name","key_")
        hostids = @($hostId)
        filter = @{
            key_ = @($key)
        }
    }

    if (-not $items -or $items.Count -eq 0) {
        throw "Missing item for job '$job'. Expected key: $key"
    }

    $itemsByJob[$job] = [string]$items[0].itemid
    Write-Host "Item OK: $job -> itemid=$($items[0].itemid)" -ForegroundColor Green
}

$widgets = @()

# 6 status tiles: 3 columns x 2 rows.
for ($i = 0; $i -lt $Jobs.Count; $i++) {
    $job = $Jobs[$i]
    $col = $i % 3
    $row = [Math]::Floor($i / 3)

    $x = [int]($col * 24)
    $y = [int]($row * 5)

    $widgets += New-VeeamStatusTile -JobName $job -ItemId $itemsByJob[$job] -X $x -Y $y
}

# Problems widget filtered by host + tag component=veeam.
$widgets += @{
    type      = "problems"
    name      = "Veeam Backup Problems"
    x         = 0
    y         = 10
    width     = 72
    height    = 8
    view_mode = 0
    fields    = @(
        (FieldInt  "rf_rate" 60)
        (FieldInt  "show" 3)
        (FieldHost "hostids.0" $hostId)

        (FieldInt "evaltype" 0)
        (FieldStr "tags.0.tag" "component")
        (FieldInt "tags.0.operator" 1)
        (FieldStr "tags.0.value" "veeam")

        (FieldInt "show_tags" 3)
        (FieldInt "tag_name_format" 0)
        (FieldStr "tag_priority" "component,scope,status,job")
        (FieldInt "show_opdata" 1)
        (FieldInt "sort_triggers" 4)
        (FieldInt "show_timeline" 1)
        (FieldInt "highlight_row" 1)
        (FieldInt "show_lines" 10)
        (FieldStr "reference" "VMPRO")
    )
}

$pages = @(
    @{
        name = "Veeam Backup Status"
        display_period = 0
        widgets = $widgets
    }
)

Write-Host "Checking dashboard '$DashboardName'..." -ForegroundColor Cyan

$existing = Invoke-ZabbixApi -Method "dashboard.get" -Params @{
    output = @("dashboardid","name")
    filter = @{
        name = @($DashboardName)
    }
}

if ($existing -and $existing.Count -gt 0) {
    $dashboardId = [string]$existing[0].dashboardid
    Write-Host "Dashboard exists. Updating dashboardid=$dashboardId ..." -ForegroundColor Yellow

    $result = Invoke-ZabbixApi -Method "dashboard.update" -Params @{
        dashboardid = $dashboardId
        name = $DashboardName
        display_period = 30
        auto_start = 0
        pages = $pages
    }

    Write-Host "Dashboard updated: $($result.dashboardids -join ', ')" -ForegroundColor Green
}
else {
    Write-Host "Dashboard does not exist. Creating..." -ForegroundColor Cyan

    $result = Invoke-ZabbixApi -Method "dashboard.create" -Params @{
        name = $DashboardName
        private = 1
        display_period = 30
        auto_start = 0
        pages = $pages
    }

    Write-Host "Dashboard created: $($result.dashboardids -join ', ')" -ForegroundColor Green
}

Write-Host ""
Write-Host "DONE." -ForegroundColor Green
Write-Host "Open in Zabbix: Dashboards -> $DashboardName" -ForegroundColor Cyan

