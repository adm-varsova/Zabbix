# Creates two private Zabbix dashboards for Agura - Omeks.
# SAFE MODE:
#   - Reads host and items.
#   - Creates two new private dashboards.
#   - Does NOT modify host, templates, items, triggers, discovery rules, tags,
#     proxy configuration, agent configuration or existing dashboards.
#   - Does NOT delete dashboards. If a dashboard already exists, script stops.

$ErrorActionPreference = 'Stop'

$ApiUrl = 'https://10.222.50.102/zabbix/api_jsonrpc.php'
$HostTechnicalName = 'Agura - Omeks'
$HostVisibleName = 'Agura - Omeks'

$HardwareDashboardName = 'Agura - Omeks - Hardware'
$ApplicationDashboardName = 'Agura - Omeks - Application'

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

function Find-ItemByNameRegex {
    param(
        $Items,
        [Parameter(Mandatory)][string]$Pattern
    )

    return $Items |
        Where-Object {
            ([string]$_.status -eq '0') -and
            ([string]$_.name -match $Pattern)
        } |
        Select-Object -First 1
}

function New-ItemWidget {
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [int]$Width = 12,
        [int]$Height = 4,
        [ValidateSet('None','Good1Bad0','Good0Bad1','Utilization')]
        [string]$ThresholdMode = 'None'
    )

    if ($null -eq $Item) {
        Write-Host "  Skipped item widget '$Name': matching item was not found yet." -ForegroundColor Yellow
        return $null
    }

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
    elseif ($ThresholdMode -eq 'Utilization') {
        # 0-79 green, 80-89 yellow, 90+ red.
        $fields += New-WidgetField -Type 1 -Name 'thresholds.0.color' -Value '2E7D32'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.0.threshold' -Value '0'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.1.color' -Value 'F9A825'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.1.threshold' -Value '80'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.2.color' -Value 'C62828'
        $fields += New-WidgetField -Type 1 -Name 'thresholds.2.threshold' -Value '90'
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
        [string]$Name = 'Active problems',
        [int]$X,
        [int]$Y,
        [int]$Width = 48,
        [int]$Height = 6
    )

    return [ordered]@{
        type      = 'problems'
        name      = $Name
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
                name    = 'Main'
                widgets = @($Widgets)
            }
        )
    }

    return [string]$result.dashboardids[0]
}

Write-Host 'SAFE MODE: this script can only READ data and CREATE TWO new private dashboards.' -ForegroundColor Cyan
Write-Host 'It contains no host.update, item.update, trigger.update, dashboard.update or delete API calls.' -ForegroundColor Cyan
Write-Host "Zabbix API: $ApiUrl"
Write-Host "Target host: $HostTechnicalName"
Write-Host "Dashboards:"
Write-Host "  $HardwareDashboardName"
Write-Host "  $ApplicationDashboardName"

$secureToken = Read-Host 'Paste your Zabbix API token (input is hidden)' -AsSecureString
$token = ConvertFrom-SecureStringPlainText -SecureValue $secureToken

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host 'No token supplied. Nothing was changed.' -ForegroundColor Yellow
    exit 1
}

try {
    # Validate that dashboards do not exist.
    Test-DashboardDoesNotExist -Token $token -DashboardName $HardwareDashboardName
    Test-DashboardDoesNotExist -Token $token -DashboardName $ApplicationDashboardName

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
        throw "Host not found. Expected name '$HostTechnicalName'."
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

    Write-Host "Items found: $($items.Count)"

    # -------------------------
    # Hardware dashboard
    # -------------------------
    $hardwareItems = [ordered]@{
        'Agent ping'         = Find-ExactKeyItem -Items $items -Key 'agent.ping'
        'CPU utilization'    = Find-ExactKeyItem -Items $items -Key 'system.cpu.util'
        'Memory utilization' = Find-ExactKeyItem -Items $items -Key 'vm.memory.util'
        'Disk C used'        = Find-ItemByNameRegex -Items $items -Pattern 'FS \[.*C:.*\]: Space: Used, in %'
        'Disk E used'        = Find-ItemByNameRegex -Items $items -Pattern 'FS \[.*E:.*\]: Space: Used, in %'
        'Uptime'             = Find-ExactKeyItem -Items $items -Key 'system.uptime'
    }

    if ($null -eq $hardwareItems['CPU utilization']) {
        $hardwareItems['CPU utilization'] = Find-ItemByNameParts -Items $items -Parts @('cpu', 'utilization')
    }
    if ($null -eq $hardwareItems['Memory utilization']) {
        $hardwareItems['Memory utilization'] = Find-ItemByNameParts -Items $items -Parts @('memory', 'utilization')
    }
    if ($null -eq $hardwareItems['Uptime']) {
        $hardwareItems['Uptime'] = Find-ItemByNameParts -Items $items -Parts @('uptime')
    }

    $hardwareWidgets = @()
    $hardwareWidgets += New-ItemWidget -Item $hardwareItems['Agent ping']         -Name 'Agent ping'         -X 0  -Y 0 -Width 12 -Height 4 -ThresholdMode 'Good1Bad0'
    $hardwareWidgets += New-ItemWidget -Item $hardwareItems['CPU utilization']    -Name 'CPU utilization'    -X 12 -Y 0 -Width 12 -Height 4 -ThresholdMode 'Utilization'
    $hardwareWidgets += New-ItemWidget -Item $hardwareItems['Memory utilization'] -Name 'Memory utilization' -X 24 -Y 0 -Width 12 -Height 4 -ThresholdMode 'Utilization'
    $hardwareWidgets += New-ItemWidget -Item $hardwareItems['Disk C used']        -Name 'Disk C used'        -X 36 -Y 0 -Width 12 -Height 4 -ThresholdMode 'Utilization'
    $hardwareWidgets += New-ItemWidget -Item $hardwareItems['Disk E used']        -Name 'Disk E used'        -X 48 -Y 0 -Width 12 -Height 4 -ThresholdMode 'Utilization'
    $hardwareWidgets += New-ItemWidget -Item $hardwareItems['Uptime']             -Name 'Uptime'             -X 60 -Y 0 -Width 12 -Height 4 -ThresholdMode 'None'

    $hardwareWidgets += New-ProblemsBySeverityWidget -HostId $hostId -X 0  -Y 4 -Width 24 -Height 6
    $hardwareWidgets += New-ProblemsWidget           -HostId $hostId -Name 'Active problems' -X 24 -Y 4 -Width 48 -Height 6

    # -------------------------
    # Omeks Application dashboard
    # -------------------------
    $appItems = [ordered]@{
        'OmeksServer service'     = Find-ExactKeyItem -Items $items -Key 'service.info["OmeksServer",state]'
        'OmeksWebWatcher service' = Find-ExactKeyItem -Items $items -Key 'service.info["OmeksWebWatcher",state]'
        'Firebird service'        = Find-ExactKeyItem -Items $items -Key 'service.info["FirebirdGuardianDefaultInstance",state]'
        'Agent ping'              = Find-ExactKeyItem -Items $items -Key 'agent.ping'
        'Firebird 3050'           = Find-ExactKeyItem -Items $items -Key 'net.tcp.listen[3050]'
        'Omeks 8921'              = Find-ExactKeyItem -Items $items -Key 'net.tcp.listen[8921]'
        'Omeks 8922'              = Find-ExactKeyItem -Items $items -Key 'net.tcp.listen[8922]'
        'WebWatcher 8923'         = Find-ExactKeyItem -Items $items -Key 'net.tcp.listen[8923]'
    }

    if ($null -eq $appItems['OmeksServer service']) {
        $appItems['OmeksServer service'] = Find-ItemByNameRegex -Items $items -Pattern 'State of service "OmeksServer"'
    }
    if ($null -eq $appItems['OmeksWebWatcher service']) {
        $appItems['OmeksWebWatcher service'] = Find-ItemByNameRegex -Items $items -Pattern 'State of service "OmeksWebWatcher"'
    }
    if ($null -eq $appItems['Firebird service']) {
        $appItems['Firebird service'] = Find-ItemByNameRegex -Items $items -Pattern 'State of service "FirebirdGuardianDefaultInstance"'
    }

    $appWidgets = @()
    $appWidgets += New-ItemWidget -Item $appItems['OmeksServer service']     -Name 'OmeksServer service'     -X 0  -Y 0 -Width 18 -Height 4 -ThresholdMode 'Good0Bad1'
    $appWidgets += New-ItemWidget -Item $appItems['OmeksWebWatcher service'] -Name 'OmeksWebWatcher service' -X 18 -Y 0 -Width 18 -Height 4 -ThresholdMode 'Good0Bad1'
    $appWidgets += New-ItemWidget -Item $appItems['Firebird service']        -Name 'Firebird service'        -X 36 -Y 0 -Width 18 -Height 4 -ThresholdMode 'Good0Bad1'
    $appWidgets += New-ItemWidget -Item $appItems['Agent ping']              -Name 'Agent ping'              -X 54 -Y 0 -Width 18 -Height 4 -ThresholdMode 'Good1Bad0'

    $appWidgets += New-ItemWidget -Item $appItems['Firebird 3050']   -Name 'Firebird 3050 listening'   -X 0  -Y 4 -Width 18 -Height 4 -ThresholdMode 'Good1Bad0'
    $appWidgets += New-ItemWidget -Item $appItems['Omeks 8921']      -Name 'Omeks 8921 listening'      -X 18 -Y 4 -Width 18 -Height 4 -ThresholdMode 'Good1Bad0'
    $appWidgets += New-ItemWidget -Item $appItems['Omeks 8922']      -Name 'Omeks 8922 listening'      -X 36 -Y 4 -Width 18 -Height 4 -ThresholdMode 'Good1Bad0'
    $appWidgets += New-ItemWidget -Item $appItems['WebWatcher 8923'] -Name 'WebWatcher 8923 listening' -X 54 -Y 4 -Width 18 -Height 4 -ThresholdMode 'Good1Bad0'

    $appWidgets += New-ProblemsBySeverityWidget -HostId $hostId -X 0  -Y 8 -Width 24 -Height 6
    $appWidgets += New-ProblemsWidget           -HostId $hostId -Name 'Active Omeks problems' -X 24 -Y 8 -Width 48 -Height 6

    Write-Host ''
    Write-Host "Ready to create dashboards:" -ForegroundColor Cyan
    Write-Host "  $HardwareDashboardName"
    Write-Host "  $ApplicationDashboardName"
    Write-Host "Widgets: Hardware=$(@($hardwareWidgets | Where-Object { $_ -ne $null }).Count), Application=$(@($appWidgets | Where-Object { $_ -ne $null }).Count)"

    $confirmation = Read-Host 'Type CREATE to continue'

    if ($confirmation -cne 'CREATE') {
        Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
        exit 0
    }

    $hardwareDashboardId = Create-Dashboard -Token $token -DashboardName $HardwareDashboardName -Widgets @($hardwareWidgets | Where-Object { $_ -ne $null })
    $applicationDashboardId = Create-Dashboard -Token $token -DashboardName $ApplicationDashboardName -Widgets @($appWidgets | Where-Object { $_ -ne $null })

    Write-Host ''
    Write-Host 'SUCCESS' -ForegroundColor Green
    Write-Host "Created dashboard: $HardwareDashboardName"
    Write-Host "Dashboard ID: $hardwareDashboardId"
    Write-Host "Created dashboard: $ApplicationDashboardName"
    Write-Host "Dashboard ID: $applicationDashboardId"
    Write-Host 'Open Zabbix -> Dashboards. They will be visible to the API-token owner.'
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
