# Creates one private global Zabbix dashboard for the Windows Server AG-HQ-HV01-SM.
# SAFE MODE:
#   - Reads the host, items and graphs.
#   - Creates ONE new private dashboard.
#   - Does NOT modify the host, template, items, triggers, discovery rules, tags,
#     existing dashboards, proxy configuration or agent configuration.
#
# The script asks for the Zabbix API token every time.
# The token is not stored in this file.

$ErrorActionPreference = 'Stop'

$ApiUrl = 'https://10.222.50.102/zabbix/api_jsonrpc.php'
$HostTechnicalName = 'AG-HQ-HV01-SM'
$HostVisibleName = 'Agura - AG-HQ-HV01-SM'
$DashboardName = 'Agura - Windows Server Overview'

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

    # Hard safety allow-list.
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
    } | ConvertTo-Json -Depth 60 -Compress

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

function Get-EnabledItems {
    param($Items)

    return @($Items | Where-Object {
        ([string]$_.status -eq '0') -and ([string]$_.state -ne '1')
    })
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

function Find-ItemByKeyRegex {
    param(
        $Items,
        [Parameter(Mandatory)][string]$Pattern
    )

    return $Items |
        Where-Object {
            ([string]$_.status -eq '0') -and
            ([string]$_.key_ -match $Pattern)
        } |
        Select-Object -First 1
}

function Find-ItemsByKeyRegex {
    param(
        $Items,
        [Parameter(Mandatory)][string]$Pattern,
        [int]$Limit = 12
    )

    return @(
        $Items |
        Where-Object {
            ([string]$_.status -eq '0') -and
            ([string]$_.key_ -match $Pattern)
        } |
        Sort-Object name |
        Select-Object -First $Limit
    )
}

function Find-ItemByNameParts {
    param(
        $Items,
        [Parameter(Mandatory)][string[]]$Parts
    )

    foreach ($item in $Items) {
        if ([string]$item.status -ne '0') {
            continue
        }

        $name = ([string]$item.name).ToLowerInvariant()
        $allMatch = $true

        foreach ($part in $Parts) {
            if (-not $name.Contains($part.ToLowerInvariant())) {
                $allMatch = $false
                break
            }
        }

        if ($allMatch) {
            return $item
        }
    }

    return $null
}

function New-ItemWidget {
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [int]$Width = 12,
        [int]$Height = 4
    )

    if ($null -eq $Item) {
        Write-Host "  Skipped item widget '$Name': matching item was not found yet." -ForegroundColor Yellow
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
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [int]$Width = 36,
        [int]$Height = 8,
        [Parameter(Mandatory)][string]$Reference
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

function New-ProblemsBySeverityWidget {
    param(
        [Parameter(Mandatory)][string]$HostId,
        [int]$X,
        [int]$Y,
        [int]$Width = 24,
        [int]$Height = 6
    )

    return [ordered]@{
        type      = 'problemsbysv'
        name      = 'Problems by severity'
        x         = $X
        y         = $Y
        width     = $Width
        height    = $Height
        view_mode = 0
        fields    = @(
            (New-WidgetField -Type 3 -Name 'hostids.0' -Value $HostId),
            (New-WidgetField -Type 0 -Name 'show_type' -Value 1),
            (New-WidgetField -Type 1 -Name 'reference' -Value 'PBSV1'),
            (New-WidgetField -Type 0 -Name 'rf_rate' -Value 60)
        )
    }
}

function New-ProblemsWidget {
    param(
        [Parameter(Mandatory)][string]$HostId,
        [int]$X,
        [int]$Y,
        [int]$Width = 48,
        [int]$Height = 6
    )

    return [ordered]@{
        type      = 'problems'
        name      = 'Active problems'
        x         = $X
        y         = $Y
        width     = $Width
        height    = $Height
        view_mode = 0
        fields    = @(
            (New-WidgetField -Type 3 -Name 'hostids.0' -Value $HostId),
            (New-WidgetField -Type 0 -Name 'show' -Value 3),
            (New-WidgetField -Type 0 -Name 'rf_rate' -Value 60),
            (New-WidgetField -Type 0 -Name 'show_timeline' -Value 1)
        )
    }
}

function Select-GraphsByPatterns {
    param(
        $Graphs,
        [Parameter(Mandatory)][string[]]$Patterns,
        [int]$Limit = 8
    )

    $selected = @()

    foreach ($pattern in $Patterns) {
        foreach ($graph in $Graphs) {
            if ($selected.graphid -contains $graph.graphid) {
                continue
            }

            if (([string]$graph.name) -match $pattern) {
                $selected += $graph
            }

            if ($selected.Count -ge $Limit) {
                return @($selected)
            }
        }
    }

    return @($selected)
}

Write-Host 'SAFE MODE: this script can only READ data and CREATE ONE new private dashboard.' -ForegroundColor Cyan
Write-Host 'It contains no host.update, item.update, template.update, dashboard.update or delete API calls.' -ForegroundColor Cyan
Write-Host "Zabbix API: $ApiUrl"
Write-Host "Target host: $HostTechnicalName"
Write-Host "Dashboard: $DashboardName"

$secureToken = Read-Host 'Paste your Zabbix API token (input is hidden)' -AsSecureString
$token = ConvertFrom-SecureStringPlainText -SecureValue $secureToken

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host 'No token supplied. Nothing was changed.' -ForegroundColor Yellow
    exit 1
}

try {
    # This first authenticated call also verifies whether the API token is still valid.
    $existing = @(
        Invoke-ZabbixApi -Token $token -Method 'dashboard.get' -Params @{
            output = @('dashboardid', 'name')
            filter = @{ name = $DashboardName }
        }
    )

    if ($existing.Count -gt 0) {
        Write-Host "Dashboard already exists: $DashboardName (ID $($existing[0].dashboardid))." -ForegroundColor Yellow
        Write-Host 'Nothing was changed.'
        exit 0
    }

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

    Write-Host "Host found: $($zbxHost.name) (hostid=$hostId)" -ForegroundColor Green

    $items = @(
        Invoke-ZabbixApi -Token $token -Method 'item.get' -Params @{
            output    = @(
                'itemid',
                'name',
                'key_',
                'status',
                'state',
                'lastvalue',
                'units',
                'value_type'
            )
            hostids   = $hostId
            sortfield = 'name'
        }
    )

    $graphs = @(
        Invoke-ZabbixApi -Token $token -Method 'graph.get' -Params @{
            output    = @('graphid', 'name', 'flags')
            hostids   = $hostId
            sortfield = 'name'
        }
    )

    Write-Host "Items found: $($items.Count)"
    Write-Host "Graphs found: $($graphs.Count)"

    # -------------------------
    # Page 1: Overview
    # -------------------------
    $overviewItems = [ordered]@{
        'Agent availability' = Find-ExactKeyItem -Items $items -Key 'agent.ping'
        'Uptime'             = Find-ExactKeyItem -Items $items -Key 'system.uptime'
        'CPU utilization'    = Find-ExactKeyItem -Items $items -Key 'system.cpu.util'
        'Memory utilization' = Find-ExactKeyItem -Items $items -Key 'vm.memory.util'
        'Total memory'       = Find-ExactKeyItem -Items $items -Key 'vm.memory.size[total]'
        'CPU count'          = Find-ExactKeyItem -Items $items -Key 'system.cpu.num'
        'Operating system'   = Find-ExactKeyItem -Items $items -Key 'system.sw.os'
        'Agent version'      = Find-ExactKeyItem -Items $items -Key 'agent.version'
        'System information' = Find-ExactKeyItem -Items $items -Key 'system.uname'
        'Boot time'          = Find-ExactKeyItem -Items $items -Key 'system.boottime'
    }

    # Fallbacks for templates where the exact key/name differs.
    if ($null -eq $overviewItems['CPU utilization']) {
        $overviewItems['CPU utilization'] = Find-ItemByNameParts -Items $items -Parts @('cpu', 'utilization')
    }
    if ($null -eq $overviewItems['Memory utilization']) {
        $overviewItems['Memory utilization'] = Find-ItemByNameParts -Items $items -Parts @('memory', 'utilization')
    }
    if ($null -eq $overviewItems['Operating system']) {
        $overviewItems['Operating system'] = Find-ItemByNameParts -Items $items -Parts @('operating system')
    }
    if ($null -eq $overviewItems['CPU count']) {
        $overviewItems['CPU count'] = Find-ItemByNameParts -Items $items -Parts @('number', 'cpu')
    }

    $overviewWidgets = @()
    $overviewPositions = @(
        @('Agent availability', 0, 0, 12),
        @('Uptime', 12, 0, 12),
        @('CPU utilization', 24, 0, 12),
        @('Memory utilization', 36, 0, 12),
        @('Total memory', 48, 0, 12),
        @('CPU count', 60, 0, 12),
        @('Operating system', 0, 4, 24),
        @('System information', 24, 4, 24),
        @('Agent version', 48, 4, 12),
        @('Boot time', 60, 4, 12)
    )

    foreach ($position in $overviewPositions) {
        $label = [string]$position[0]
        $x = [int]$position[1]
        $y = [int]$position[2]
        $width = [int]$position[3]

        $widget = New-ItemWidget `
            -Item $overviewItems[$label] `
            -Name $label `
            -X $x `
            -Y $y `
            -Width $width `
            -Height 4

        if ($null -ne $widget) {
            $overviewWidgets += $widget
        }
    }

    $overviewWidgets += New-ProblemsBySeverityWidget -HostId $hostId -X 0 -Y 8 -Width 24 -Height 6
    $overviewWidgets += New-ProblemsWidget -HostId $hostId -X 24 -Y 8 -Width 48 -Height 6

    $pages = @(
        [ordered]@{
            name    = 'Overview'
            widgets = @($overviewWidgets)
        }
    )

    # -------------------------
    # Page 2: Performance
    # -------------------------
    $performanceGraphs = Select-GraphsByPatterns `
        -Graphs $graphs `
        -Patterns @(
            '(?i)^CPU utilization$',
            '(?i)CPU.*utilization',
            '(?i)memory.*utilization',
            '(?i)memory.*usage',
            '(?i)processor.*queue',
            '(?i)page.*fault',
            '(?i)page.*second',
            '(?i)system.*load'
        ) `
        -Limit 8

    if ($performanceGraphs.Count -gt 0) {
        $performanceWidgets = @()

        for ($index = 0; $index -lt $performanceGraphs.Count; $index++) {
            $x = if (($index % 2) -eq 0) { 0 } else { 36 }
            $y = [math]::Floor($index / 2) * 8
            $reference = ('PER{0:D2}' -f $index)

            $performanceWidgets += New-GraphWidget `
                -Graph $performanceGraphs[$index] `
                -X $x `
                -Y $y `
                -Width 36 `
                -Height 8 `
                -Reference $reference
        }

        $pages += [ordered]@{
            name    = 'Performance'
            widgets = @($performanceWidgets)
        }
    }
    else {
        Write-Host '  No CPU/memory performance graphs were found yet; Performance page will be omitted.' -ForegroundColor Yellow
    }

    # -------------------------
    # Page 3: Storage
    # -------------------------
    $filesystemItems = Find-ItemsByKeyRegex `
        -Items $items `
        -Pattern '^vfs\.fs\.(?:dependent\.)?size\[.+,pused\]$' `
        -Limit 12

    $storageGraphs = Select-GraphsByPatterns `
        -Graphs $graphs `
        -Patterns @(
            '(?i)space.*utilization',
            '(?i)filesystem',
            '(?i)file system',
            '(?i)physical disk',
            '(?i)disk.*read',
            '(?i)disk.*write',
            '(?i)disk.*utilization'
        ) `
        -Limit 6

    $storageWidgets = @()

    for ($index = 0; $index -lt $filesystemItems.Count; $index++) {
        $x = ($index % 4) * 18
        $y = [math]::Floor($index / 4) * 4
        $displayName = [string]$filesystemItems[$index].name

        $storageWidgets += New-ItemWidget `
            -Item $filesystemItems[$index] `
            -Name $displayName `
            -X $x `
            -Y $y `
            -Width 18 `
            -Height 4
    }

    $storageGraphStartY = if ($filesystemItems.Count -gt 0) {
        [math]::Ceiling($filesystemItems.Count / 4.0) * 4
    }
    else {
        0
    }

    for ($index = 0; $index -lt $storageGraphs.Count; $index++) {
        $x = if (($index % 2) -eq 0) { 0 } else { 36 }
        $y = $storageGraphStartY + ([math]::Floor($index / 2) * 8)
        $reference = ('DSK{0:D2}' -f $index)

        $storageWidgets += New-GraphWidget `
            -Graph $storageGraphs[$index] `
            -X $x `
            -Y $y `
            -Width 36 `
            -Height 8 `
            -Reference $reference
    }

    if ($storageWidgets.Count -gt 0) {
        $pages += [ordered]@{
            name    = 'Storage'
            widgets = @($storageWidgets)
        }
    }
    else {
        Write-Host '  No discovered filesystem/disk items or graphs were found yet; Storage page will be omitted.' -ForegroundColor Yellow
    }

    # -------------------------
    # Page 4: Network
    # -------------------------
    $networkGraphs = Select-GraphsByPatterns `
        -Graphs $graphs `
        -Patterns @(
            '(?i)network traffic',
            '(?i)traffic.*interface',
            '(?i)interface.*traffic',
            '(?i)bits received',
            '(?i)bits sent'
        ) `
        -Limit 8

    $networkWidgets = @()

    if ($networkGraphs.Count -gt 0) {
        for ($index = 0; $index -lt $networkGraphs.Count; $index++) {
            $x = if (($index % 2) -eq 0) { 0 } else { 36 }
            $y = [math]::Floor($index / 2) * 8
            $reference = ('NET{0:D2}' -f $index)

            $networkWidgets += New-GraphWidget `
                -Graph $networkGraphs[$index] `
                -X $x `
                -Y $y `
                -Width 36 `
                -Height 8 `
                -Reference $reference
        }
    }
    else {
        # Fallback: show individual discovered interface counters if no graphs exist.
        $networkItems = Find-ItemsByKeyRegex `
            -Items $items `
            -Pattern '^net\.if\.(?:in|out)\[' `
            -Limit 12

        for ($index = 0; $index -lt $networkItems.Count; $index++) {
            $x = ($index % 4) * 18
            $y = [math]::Floor($index / 4) * 4

            $networkWidgets += New-ItemWidget `
                -Item $networkItems[$index] `
                -Name ([string]$networkItems[$index].name) `
                -X $x `
                -Y $y `
                -Width 18 `
                -Height 4
        }
    }

    if ($networkWidgets.Count -gt 0) {
        $pages += [ordered]@{
            name    = 'Network'
            widgets = @($networkWidgets)
        }
    }
    else {
        Write-Host '  No discovered network graphs/items were found yet; Network page will be omitted.' -ForegroundColor Yellow
    }

    $widgetCount = 0
    foreach ($page in $pages) {
        $widgetCount += @($page.widgets).Count
    }

    Write-Host ''
    Write-Host "Ready to create private dashboard '$DashboardName'." -ForegroundColor Cyan
    Write-Host "Pages: $($pages.Count)"
    Write-Host "Widgets: $widgetCount"

    if ($pages.Count -lt 3) {
        Write-Host ''
        Write-Host 'NOTE: Disk/network discovery may still be running because the host was added recently.' -ForegroundColor Yellow
        Write-Host 'You can cancel now, wait several minutes, and run the script again for more complete pages.' -ForegroundColor Yellow
    }

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
