
$confContent = @"
# Основни настройки
Server=192.168.200.40
ServerActive=192.168.200.40
Hostname=WS2

# TLS настройки
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=MyPSKIdentity
TLSPSKFile=C:\zabbix_agentd.psk

# Лог файл (по избор)
LogFile=C:\zabbix_agentd.log
"@

$confPath = "C:\Program Files\Zabbix Agent\zabbix_agentd.conf"

# Create the configuration file with the specified content
New-Item -Path $confPath -ItemType File -Force
Set-Content -Path $confPath -Value $confContent
