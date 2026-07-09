# Creates one private Zabbix dashboard ONLY for Workflow DB / PostgreSQL.
# SAFE MODE:
#   - Reads host and items.
#   - Creates one new private dashboard.
#   - Does NOT modify host, templates, items, triggers, discovery rules, tags,
#     proxy configuration, agent configuration or existing dashboards.
#   - Does NOT delete dashboards. If the dashboard already exists, script stops.

$ErrorActionPreference = 'Stop'

$ApiUrl = 'https://10.222.50.102/zabbix/api_jsonrpc.php'

# Technical host name.
$HostTechnicalName = 'AG-HQ-HV01-SM'

# Visible name, fallback only.
$HostVisibleName = 'Agura - AG-HQ-HV01-SM'

$DashboardName = 'Agura - Workflow DB'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

function ConvertFrom-SecureStringPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$SecureValue)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Invoke-ZabbixApi {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)]$Params
    )

    $allowedMethods = @(
        'dashboard.get',
        'host.get',
        'item.get',
        'dashboard.create'
    )

    if ($Method -notin $allowedMethods) {
        throw "Safety block: API method '$Method' is not allowed by this script."
    }

    $payload = @{
        jsonrpc = '2.0'
        method  = $Method
        params  = $Params
        id      = 1
    } | ConvertTo-Json -Depth 80 -Compress

    try {
        $response = Invoke-RestMethod `
            -Uri $ApiUrl `
            -Method Post `
            -ContentType 'application/json-rpc' `
            -Headers @{ Authorization = "Bearer $Token" } `
            -Body $payload `
            -TimeoutSec 45
    }
    catch {
        throw "Cannot connect to $ApiUrl. $($_.Exception.Message)"
    }

    if ($null -ne $response.error) {
        throw "$Method`: $($response.error.message) | $($response.error.data)"
    }

    return $response.result
}

function New-WidgetField {
    param(
        [Parameter(Mandatory)][int]$Type,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value
    )

    return [ordered]@{
        type  = $Type
        name  = $Name
        value = $Value
    }
}

function Find-ExactKeyItem {
    param(
        $Items,
        [Parameter(Mandatory)][string]$Key
    )

    return $Items |
        Where-Object { ([string]$_.key_ -eq $Key) -and ([string]$_.status -eq '0') } |
        Select-Object -First 1
}

function New-ItemWidget {
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [int]$Width = 36,
        [int]$Height = 5,
        [ValidateSet('Good1Bad0','Good0Bad1')]
        [string]$ThresholdMode
    )

    if ($null -eq $Item) {
        Write-Host "  Skipped item widget '$Name': matching item was not found." -ForegroundColor Yellow
        return $null
    }

    # This widget format is the same style that already worked in the previous Zabbix dashboards.
    $fields = @(
        (New-WidgetField -Type 4 -Name 'itemid.0' -Value ([string]$Item.itemid)),
        (New-WidgetField -Type 0 -Name 'show.0' -Value 1),
        (New-WidgetField -Type 0 -Name 'show.1' -Value 2),
        (New-WidgetField -Type 0 -Name 'show.2' -Value 3),
        (New-WidgetField -Type 1 -Name 'description' -Value $Name),
        (New-WidgetField -Type 0 -Name 'rf_rate' -Value 60)
    )

    if ($ThresholdMode -eq 'Good1Bad0') {
        # 0 = red, 1 = green.
        $fields += New-WidgetField -Type 1 -Name 'thresholds.0.color' -Value 'C62828'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.0.threshold' -Value '0'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.1.color' -Value '2E7D32'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.1.threshold' -Value '1'
    }
    elseif ($ThresholdMode -eq 'Good0Bad1') {
        # 0 = green, 1+ = red.
        $fields += New-WidgetField -Type 1 -Name 'thresholds.0.color' -Value '2E7D32'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.0.threshold' -Value '0'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.1.color' -Value 'C62828'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.1.threshold' -Value '1'
    }

    return [ordered]@{
        type      = 'item'
        name      = $Name
        x         = $X
        y         = $Y
        width     = $Width
        height    = $Height
        view_mode = 0
        fields    = @($fields)
    }
}

function Test-DashboardDoesNotExist {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DashboardName
    )

    $existing = @(
        Invoke-ZabbixApi -Token $Token -Method 'dashboard.get' -Params @{
            output = @('dashboardid', 'name')
            filter = @{ name = $DashboardName }
        }
    )

    if ($existing.Count -gt 0) {
        throw "Dashboard already exists: '$DashboardName' (ID $($existing[0].dashboardid)). Delete it manually or rename it, then run the script again."
    }
}

function Create-Dashboard {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DashboardName,
        [Parameter(Mandatory)]$Widgets
    )

    $result = Invoke-ZabbixApi -Token $Token -Method 'dashboard.create' -Params @{
        name           = $DashboardName
        private        = 1
        display_period = 30
        auto_start     = 0
        pages          = @(
            [ordered]@{
                name    = 'Workflow DB'
                widgets = @($Widgets)
            }
        )
    }

    return [string]$result.dashboardids[0]
}

Write-Host 'SAFE MODE: this script can only READ data and CREATE ONE new private dashboard.' -ForegroundColor Cyan
Write-Host 'It contains no host.update, item.update, trigger.update, dashboard.update or delete API calls.' -ForegroundColor Cyan
Write-Host "Zabbix API: $ApiUrl"
Write-Host "Target host technical name: $HostTechnicalName"
Write-Host "Dashboard: $DashboardName"

$secureToken = Read-Host 'Paste your Zabbix API token (input is hidden)' -AsSecureString
$token = ConvertFrom-SecureStringPlainText -SecureValue $secureToken

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host 'No token supplied. Nothing was changed.' -ForegroundColor Yellow
    exit 1
}

try {
    Test-DashboardDoesNotExist -Token $token -DashboardName $DashboardName

    $hosts = @(
        Invoke-ZabbixApi -Token $token -Method 'host.get' -Params @{
            output = @('hostid', 'host', 'name', 'status')
            filter = @{ host = $HostTechnicalName }
        }
    )

    if ($hosts.Count -eq 0) {
        $hosts = @(
            Invoke-ZabbixApi -Token $token -Method 'host.get' -Params @{
                output = @('hostid', 'host', 'name', 'status')
                filter = @{ name = $HostVisibleName }
            }
        )
    }

    if ($hosts.Count -eq 0) {
        throw "Host not found. Expected technical name '$HostTechnicalName' or visible name '$HostVisibleName'."
    }

    $zbxHost = $hosts[0]
    $hostId = [string]$zbxHost.hostid

    Write-Host "Host found: $($zbxHost.name) / $($zbxHost.host) (hostid=$hostId)" -ForegroundColor Green

    $items = @(
        Invoke-ZabbixApi -Token $token -Method 'item.get' -Params @{
            output    = @('itemid','name','key_','status','lastvalue')
            hostids   = $hostId
            sortfield = 'name'
        }
    )

    Write-Host "Items found: $($items.Count)"

    $postgresService = Find-ExactKeyItem -Items $items -Key 'service.info["postgresql-x64-17",state]'
    $postgresPort    = Find-ExactKeyItem -Items $items -Key 'net.tcp.listen[5432]'

    $widgets = @()
    $widgets += New-ItemWidget -Item $postgresService -Name 'Workflow DB - PostgreSQL service' -X 0  -Y 0 -Width 36 -Height 5 -ThresholdMode 'Good0Bad1'
    $widgets += New-ItemWidget -Item $postgresPort    -Name 'Workflow DB - PostgreSQL 5432 listening' -X 36 -Y 0 -Width 36 -Height 5 -ThresholdMode 'Good1Bad0'

    $widgets = @($widgets | Where-Object { $_ -ne $null })

    if ($widgets.Count -eq 0) {
        throw 'No matching Workflow DB items were found. Dashboard was not created.'
    }

    Write-Host ''
    Write-Host "Ready to create dashboard:" -ForegroundColor Cyan
    Write-Host "  $DashboardName"
    Write-Host "Widgets: $($widgets.Count)"

    $confirmation = Read-Host 'Type CREATE to continue'

    if ($confirmation -cne 'CREATE') {
        Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
        exit 0
    }

    $dashboardId = Create-Dashboard -Token $token -DashboardName $DashboardName -Widgets $widgets

    Write-Host ''
    Write-Host 'SUCCESS' -ForegroundColor Green
    Write-Host "Created dashboard: $DashboardName"
    Write-Host "Dashboard ID: $dashboardId"
    Write-Host 'Open Zabbix -> Dashboards. It will be visible to the API-token owner.'
    Write-Host 'The script did not modify the host, template, items, triggers, discovery rules, tags, proxy, agent or existing dashboards.'
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Nothing else was intentionally changed. If dashboard.create failed, no dashboard was created.' -ForegroundColor Yellow
    exit 2
}
finally {
    $token = $null
}
