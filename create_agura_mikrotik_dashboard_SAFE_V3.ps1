# Creates one private global Zabbix dashboard for the Agura MikroTik host.
# It only reads hosts/items/graphs and calls dashboard.create.
# It does not modify templates, hosts, items, discovery rules, tags, or existing dashboards.

$ErrorActionPreference = 'Stop'

$ApiUrl = 'https://10.222.50.102/zabbix/api_jsonrpc.php'
$HostTechnicalName = 'AGURA-RTR-01'
$HostVisibleName = 'Agura - MikroTik RB2011UiAS'
$DashboardName = 'Agura - MikroTik Overview'

# Internal Zabbix uses an untrusted/self-signed certificate.
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
        'graph.get',
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
    } | ConvertTo-Json -Depth 50 -Compress

    try {
        $response = Invoke-RestMethod `
            -Uri $ApiUrl `
            -Method Post `
            -ContentType 'application/json-rpc' `
            -Headers @{ Authorization = "Bearer $Token" } `
            -Body $payload `
            -TimeoutSec 30
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
    return [ordered]@{ type = $Type; name = $Name; value = $Value }
}

function Find-ExactKeyItem {
    param($Items, [string]$Key)
    return $Items | Where-Object { $_.key_ -eq $Key } | Select-Object -First 1
}

function Find-ItemByNameParts {
    param($Items, [string[]]$Parts)
    foreach ($item in $Items) {
        if ($item.status -ne '0') { continue }
        $name = ([string]$item.name).ToLowerInvariant()
        $allMatch = $true
        foreach ($part in $Parts) {
            if (-not $name.Contains($part.ToLowerInvariant())) {
                $allMatch = $false
                break
            }
        }
        if ($allMatch) { return $item }
    }
    return $null
}

function New-ItemWidget {
    param(
        $Item,
        [string]$Name,
        [int]$X,
        [int]$Y,
        [int]$Width = 12,
        [int]$Height = 4
    )

    if ($null -eq $Item) {
        Write-Host "  Skipped widget '$Name': matching item was not found." -ForegroundColor Yellow
        return $null
    }

    return [ordered]@{
        type      = 'item'
        name      = $Name
        x         = $X
        y         = $Y
        width     = $Width
        height    = $Height
        view_mode = 0
        fields    = @(
            (New-WidgetField -Type 4 -Name 'itemid.0' -Value ([string]$Item.itemid)),
            (New-WidgetField -Type 0 -Name 'rf_rate' -Value 60)
        )
    }
}

function New-GraphWidget {
    param(
        $Graph,
        [int]$X,
        [int]$Y,
        [int]$Width = 36,
        [int]$Height = 8,
        [string]$Reference = 'ABCDE'
    )

    return [ordered]@{
        type      = 'graph'
        name      = [string]$Graph.name
        x         = $X
        y         = $Y
        width     = $Width
        height    = $Height
        view_mode = 0
        fields    = @(
            (New-WidgetField -Type 0 -Name 'source_type' -Value 0),
            (New-WidgetField -Type 6 -Name 'graphid.0' -Value ([string]$Graph.graphid)),
            (New-WidgetField -Type 1 -Name 'reference' -Value $Reference),
            (New-WidgetField -Type 0 -Name 'rf_rate' -Value 60),
            (New-WidgetField -Type 0 -Name 'show_legend' -Value 1)
        )
    }
}

Write-Host 'SAFE MODE: this script can only READ data and CREATE ONE new private dashboard.' -ForegroundColor Cyan
Write-Host 'It contains no host.update, item.update, template.update, dashboard.update, or delete API calls.' -ForegroundColor Cyan
Write-Host "Zabbix API: $ApiUrl"

$secureToken = Read-Host 'Paste your Zabbix API token (input is hidden)' -AsSecureString
$token = ConvertFrom-SecureStringPlainText -SecureValue $secureToken
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host 'No token supplied. Nothing was changed.' -ForegroundColor Yellow
    exit 1
}

try {
    # The first authenticated dashboard.get call below verifies API access and the token.
    # apiinfo.version is intentionally not called here because Zabbix requires it
    # to be called without an Authorization header.

    $existing = @(Invoke-ZabbixApi -Token $token -Method 'dashboard.get' -Params @{
        output = @('dashboardid', 'name')
        filter = @{ name = $DashboardName }
    })
    if ($existing.Count -gt 0) {
        Write-Host "Dashboard already exists: $DashboardName (ID $($existing[0].dashboardid))." -ForegroundColor Yellow
        Write-Host 'Nothing was changed.'
        exit 0
    }

    $hosts = @(Invoke-ZabbixApi -Token $token -Method 'host.get' -Params @{
        output = @('hostid', 'host', 'name')
        filter = @{ host = $HostTechnicalName }
    })
    if ($hosts.Count -eq 0) {
        $hosts = @(Invoke-ZabbixApi -Token $token -Method 'host.get' -Params @{
            output = @('hostid', 'host', 'name')
            filter = @{ name = $HostVisibleName }
        })
    }
    if ($hosts.Count -eq 0) {
        throw "Host not found. Expected technical name '$HostTechnicalName' or visible name '$HostVisibleName'."
    }

    $zbxHost = $hosts[0]
    $hostId = [string]$zbxHost.hostid
    Write-Host "Host found: $($zbxHost.name) (hostid=$hostId)" -ForegroundColor Green

    $items = @(Invoke-ZabbixApi -Token $token -Method 'item.get' -Params @{
        output    = @('itemid', 'name', 'key_', 'status', 'state', 'lastvalue')
        hostids   = $hostId
        sortfield = 'name'
    })

    $selected = @{
        'SNMP availability'   = Find-ExactKeyItem -Items $items -Key 'zabbix[host,snmp,available]'
        'Uptime'              = Find-ExactKeyItem -Items $items -Key 'system.net.uptime[sysUpTime.0]'
        'CPU utilization'     = Find-ItemByNameParts -Items $items -Parts @('cpu utilization')
        'Memory utilization'  = Find-ExactKeyItem -Items $items -Key 'vm.memory.util[memoryUsedPercentage.Memory]'
        'Device temperature'  = Find-ItemByNameParts -Items $items -Parts @('device', 'temperature')
        'RouterOS version'    = Find-ExactKeyItem -Items $items -Key 'system.sw.os[mtxrLicVersion.0]'
        'Firmware version'    = Find-ExactKeyItem -Items $items -Key 'system.hw.firmware'
        'Hardware model'      = Find-ExactKeyItem -Items $items -Key 'system.hw.model'
        'ICMP loss'           = Find-ExactKeyItem -Items $items -Key 'icmppingloss'
        'ICMP response time'  = Find-ExactKeyItem -Items $items -Key 'icmppingsec'
    }

    $overviewWidgets = @()
    $positions = @(
        @('SNMP availability', 0, 0),
        @('Uptime', 12, 0),
        @('CPU utilization', 24, 0),
        @('Memory utilization', 36, 0),
        @('Device temperature', 48, 0),
        @('ICMP loss', 60, 0),
        @('RouterOS version', 0, 4),
        @('Firmware version', 18, 4),
        @('Hardware model', 36, 4),
        @('ICMP response time', 54, 4)
    )

    foreach ($position in $positions) {
        $label = [string]$position[0]
        $x = [int]$position[1]
        $y = [int]$position[2]
        $width = if ($y -eq 4) { 18 } else { 12 }
        $widget = New-ItemWidget -Item $selected[$label] -Name $label -X $x -Y $y -Width $width -Height 4
        if ($null -ne $widget) { $overviewWidgets += $widget }
    }

    $overviewWidgets += [ordered]@{
        type      = 'problemsbysv'
        name      = 'Problems by severity'
        x         = 0
        y         = 8
        width     = 24
        height    = 6
        view_mode = 0
        fields    = @(
            (New-WidgetField -Type 3 -Name 'hostids.0' -Value $hostId),
            (New-WidgetField -Type 0 -Name 'show_type' -Value 1),
            (New-WidgetField -Type 1 -Name 'reference' -Value 'PBSV1'),
            (New-WidgetField -Type 0 -Name 'rf_rate' -Value 60)
        )
    }

    $overviewWidgets += [ordered]@{
        type      = 'problems'
        name      = 'Active problems'
        x         = 24
        y         = 8
        width     = 48
        height    = 6
        view_mode = 0
        fields    = @(
            (New-WidgetField -Type 3 -Name 'hostids.0' -Value $hostId),
            (New-WidgetField -Type 0 -Name 'show' -Value 3),
            (New-WidgetField -Type 0 -Name 'rf_rate' -Value 60),
            (New-WidgetField -Type 0 -Name 'show_timeline' -Value 1)
        )
    }

    $graphs = @(Invoke-ZabbixApi -Token $token -Method 'graph.get' -Params @{
        output    = @('graphid', 'name', 'flags')
        hostids   = $hostId
        sortfield = 'name'
    })

    $trafficGraphs = @($graphs | Where-Object { ([string]$_.name).ToLowerInvariant().Contains('network traffic') })
    $trafficGraphs = @($trafficGraphs | Sort-Object `
        @{ Expression = { if (([string]$_.name).ToLowerInvariant().Contains('ether')) { 0 } else { 1 } } }, `
        @{ Expression = { ([string]$_.name).ToLowerInvariant() } } | Select-Object -First 8)

    $pages = @(
        [ordered]@{ name = 'Overview'; widgets = @($overviewWidgets) }
    )

    if ($trafficGraphs.Count -gt 0) {
        $networkWidgets = @()
        for ($index = 0; $index -lt $trafficGraphs.Count; $index++) {
            $x = if (($index % 2) -eq 0) { 0 } else { 36 }
            $y = [math]::Floor($index / 2) * 8
            $reference = ('NET{0:D2}' -f $index)
            if ($reference.Length -gt 5) { $reference = $reference.Substring(0, 5) }
            $networkWidgets += New-GraphWidget -Graph $trafficGraphs[$index] -X $x -Y $y -Reference $reference
        }
        $pages += [ordered]@{ name = 'Network traffic'; widgets = @($networkWidgets) }
    }
    else {
        Write-Host "  No discovered 'Network traffic' graphs were found; Network page will be omitted." -ForegroundColor Yellow
    }

    $widgetCount = 0
    foreach ($page in $pages) { $widgetCount += @($page.widgets).Count }

    Write-Host "`nReady to create private dashboard '$DashboardName' with $($pages.Count) page(s) and $widgetCount widget(s)." -ForegroundColor Cyan
    $confirmation = Read-Host 'Type CREATE to continue'
    if ($confirmation -cne 'CREATE') {
        Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
        exit 0
    }

    $result = Invoke-ZabbixApi -Token $token -Method 'dashboard.create' -Params @{
        name           = $DashboardName
        private        = 1
        display_period = 30
        auto_start     = 0
        pages          = @($pages)
    }

    $dashboardId = [string]$result.dashboardids[0]
    Write-Host "`nSUCCESS" -ForegroundColor Green
    Write-Host "Created dashboard: $DashboardName"
    Write-Host "Dashboard ID: $dashboardId"
    Write-Host 'Open Zabbix -> Dashboards. It will be visible to the API-token owner.'
    Write-Host 'The script did not modify the template, host, items, discovery rules, tags, or existing dashboards.'
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Nothing else was intentionally changed. If dashboard.create failed, no dashboard was created.' -ForegroundColor Yellow
    exit 2
}
finally {
    $token = $null
}
