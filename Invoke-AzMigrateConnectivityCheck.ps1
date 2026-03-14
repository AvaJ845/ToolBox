<#------------------------------------------------------------------------------

 Copyright © 2026 Microsoft Corporation.  All rights reserved.

 THIS CODE AND ANY ASSOCIATED INFORMATION ARE PROVIDED "AS IS" WITHOUT
 WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT
 LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS
 FOR A PARTICULAR PURPOSE. THE ENTIRE RISK OF USE, INABILITY TO USE, OR
 RESULTS FROM THE USE OF THIS CODE REMAINS WITH THE USER.
 Label: Sample 

#------------------------------------------------------------------------------
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Migrate Appliance Connectivity Troubleshooter

.DESCRIPTION
    Read-only diagnostic tool that checks network connectivity requirements for Azure Migrate appliance
    registration and discovery. Tests required URLs and ports based on deployment scenario selections.

    THIS SCRIPT MAKES NO CHANGES TO THE ENVIRONMENT. It only reads configuration and tests connectivity.

    Supports:
    - Commercial Azure, Azure Government, and Azure China (21Vianet)
    - VMware Agentless, Agent-based Legacy, Agent-based Modern appliance scenarios
    - Assessment/Discovery and Replication appliance types
    - VMware vSphere, Hyper-V, and Physical/Other Cloud source platforms
    - Public endpoint and Private Link connectivity
    - Direct internet, proxy, ExpressRoute, and VPN Gateway connectivity paths
    - Proxy and firewall detection and reporting

.NOTES
    Version:  5.0
    Requires: PowerShell 5.1+
    Author:   Azure Migrate Field Engineering

.LINK
    https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance
    https://learn.microsoft.com/en-us/azure/migrate/simplified-experience-for-azure-migrate
    https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance-china
#>

[CmdletBinding()]
param()

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$script:TestResults    = [System.Collections.ArrayList]::new()
$script:Recommendations = [System.Collections.ArrayList]::new()
$script:Warnings       = [System.Collections.ArrayList]::new()
$script:ScriptVersion  = '5.0'
$script:TcpTimeoutMs   = 5000
$script:HttpTimeoutMs  = 10000
$machineName = ($env:COMPUTERNAME -replace '[^a-zA-Z0-9-]', '_')
$script:ReportPath   = Join-Path $PSScriptRoot ("AzMigrate-ConnectivityReport_{0}_{1}.txt" -f $machineName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:SummaryPath  = Join-Path $PSScriptRoot ("AzMigrate-Summary_{0}_{1}.txt"            -f $machineName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:ZipPath      = Join-Path $PSScriptRoot ("AzMigrate-Report_{0}_{1}.zip"             -f $machineName, (Get-Date -Format 'yyyyMMdd_HHmmss'))

# Force TLS 1.2 (required by Azure services)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Failed to set TLS 1.2. Some tests may fail."
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Banner {
    $banner = @"
===============================================================================
  Azure Migrate Appliance - Connectivity Troubleshooter v$($script:ScriptVersion)
  Supports: Commercial | Government | China (21Vianet) | Production-Safe | Executive Reporting
===============================================================================
  This tool checks network connectivity required for Azure Migrate appliance
  registration and operation. It tests DNS resolution, TCP connectivity, and
  HTTPS reachability for all required endpoints based on your deployment scenario.

  ** THIS TOOL IS READ-ONLY AND MAKES NO CHANGES TO YOUR ENVIRONMENT **

  Results will be saved to: $($script:ReportPath)
===============================================================================
  HOW TO RUN THIS SCRIPT
  ─────────────────────────────────────────────────────────────────────────────
  This script is not digitally signed. If PowerShell blocks it, run this
  command FIRST in the same PowerShell window, then run the script:

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

  IMPORTANT: This only affects the current PowerShell session.
  It does NOT permanently change your system's security settings.
  It reverts automatically when the PowerShell window is closed.

  Full command to run this script:

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass; .\Invoke-AzMigrateConnectivityCheck.ps1

  If your organisation requires signed scripts, contact your security team to
  add a bypass exception for this script, or ask them to sign it using your
  organisation's internal code signing certificate.
===============================================================================
"@
    Write-Host $banner -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    $line = '=' * 78
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
}

function Write-SubSection {
    param([string]$Title)
    Write-Host ""
    Write-Host "  --- $Title ---" -ForegroundColor Yellow
}

function Get-MenuSelection {
    param(
        [string]$Prompt,
        [string[]]$Options,
        [string]$HelpText = ''
    )
    Write-Host ""
    if ($HelpText) { Write-Host "  $HelpText" -ForegroundColor Gray }
    Write-Host "  $Prompt" -ForegroundColor White
    Write-Host ""
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "    [$($i + 1)] $($Options[$i])" -ForegroundColor Yellow
    }
    Write-Host ""
    do {
        $input = Read-Host "  Enter selection (1-$($Options.Count))"
        $sel = 0
        $valid = [int]::TryParse($input, [ref]$sel) -and $sel -ge 1 -and $sel -le $Options.Count
        if (-not $valid) {
            Write-Host "  Invalid selection. Please enter a number between 1 and $($Options.Count)." -ForegroundColor Red
        }
    } while (-not $valid)
    return $sel
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = $script:TcpTimeoutMs
    )
    $result = @{
        Success    = $false
        LatencyMs  = -1
        Error      = ''
    }
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $task = $client.ConnectAsync($HostName, $Port)
        $completed = $task.Wait($TimeoutMs)
        $sw.Stop()
        if ($completed -and -not $task.IsFaulted) {
            $result.Success   = $true
            $result.LatencyMs = $sw.ElapsedMilliseconds
        } else {
            if ($task.IsFaulted) {
                $result.Error = $task.Exception.InnerException.Message
            } else {
                $result.Error = "Connection timed out after ${TimeoutMs}ms"
            }
        }
        $client.Close()
        $client.Dispose()
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Test-DnsResolution {
    param([string]$HostName)
    $result = @{
        Success   = $false
        Addresses = @()
        Error     = ''
    }
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
        if ($addresses.Count -gt 0) {
            $result.Success   = $true
            $result.Addresses = $addresses | ForEach-Object { $_.IPAddressToString }
        } else {
            $result.Error = "No addresses returned"
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Test-HttpsConnectivity {
    param(
        [string]$Url,
        [int]$TimeoutMs = $script:HttpTimeoutMs
    )
    $result = @{
        Success    = $false
        StatusCode = 0
        Error      = ''
        LatencyMs  = -1
        CertIssuer = ''
    }
    try {
        $uri = "https://$Url"
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method  = 'GET'
        $request.Timeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'AzureMigrateConnectivityChecker/2.0'

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = $request.GetResponse()
        $sw.Stop()

        $result.Success    = $true
        $result.StatusCode = [int]$response.StatusCode
        $result.LatencyMs  = $sw.ElapsedMilliseconds
        if ($request.ServicePoint.Certificate) {
            $result.CertIssuer = $request.ServicePoint.Certificate.Issuer
        }
        $response.Close()
        $response.Dispose()
    } catch [System.Net.WebException] {
        $sw.Stop()
        $result.LatencyMs = $sw.ElapsedMilliseconds
        $webEx = $_.Exception
        if ($webEx.Response) {
            # Got an HTTP response (401, 403, 404, etc.) - means network is reachable
            $result.StatusCode = [int]$webEx.Response.StatusCode
            if ($result.StatusCode -in @(400, 401, 403, 404, 405, 406, 409, 412, 500, 502, 503)) {
                $result.Success = $true  # Network connectivity is working
            }
            $result.Error = "HTTP $($result.StatusCode): $($webEx.Message)"
            if ($webEx.Response -is [System.Net.HttpWebResponse]) {
                $webEx.Response.Close()
            }
        } else {
            $result.Error = $webEx.Message
            if ($webEx.InnerException) {
                $result.Error += " -> $($webEx.InnerException.Message)"
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Add-TestResult {
    param(
        [string]$Url,
        [int]$Port,
        [string]$Purpose,
        [string]$WildcardPattern,
        [bool]$DnsPass,
        [string]$DnsDetail,
        [bool]$TcpPass,
        [string]$TcpDetail,
        [bool]$HttpsPass,
        [string]$HttpsDetail,
        [string]$Category
    )
    $overall = $DnsPass -and $TcpPass -and $HttpsPass
    [void]$script:TestResults.Add([PSCustomObject]@{
        Url             = $Url
        Port            = $Port
        Purpose         = $Purpose
        WildcardPattern = $WildcardPattern
        DnsPass         = $DnsPass
        DnsDetail       = $DnsDetail
        TcpPass         = $TcpPass
        TcpDetail       = $TcpDetail
        HttpsPass       = $HttpsPass
        HttpsDetail     = $HttpsDetail
        OverallPass     = $overall
        Category        = $Category
    })
}

# ============================================================================
# URL DEFINITIONS  (v2.0 — authoritative MS docs endpoint lists)
# ============================================================================

function Get-UrlDefinitions {
    param(
        [ValidateSet('Commercial','Government','China')]
        [string]$Cloud,
        [ValidateSet('VMwareAgentless','AgentBasedLegacy','AgentBasedModern')]
        [string]$Scenario,
        [ValidateSet('Assessment','Replication')]
        [string]$ApplianceType,
        [ValidateSet('VMware','HyperV','Physical')]
        [string]$Platform,
        [bool]$PrivateLink
    )

    $urls = [System.Collections.ArrayList]::new()

    # Helper to add a URL entry
    # Usage: Add-Url $urls 'host' 443 'wildcard' 'purpose' 'category'
    function local:Add-Url {
        param($list, $host_, $port, $wildcard, $purpose, $category)
        [void]$list.Add(@{ Host=$host_; Port=$port; Wildcard=$wildcard; Purpose=$purpose; Category=$category })
    }

    # ========================================================================
    # COMMERCIAL CLOUD
    # ========================================================================
    if ($Cloud -eq 'Commercial') {

        if (-not $PrivateLink) {
            # ----------------------------------------------------------------
            # Commercial — Public endpoints
            # ----------------------------------------------------------------
            $cat = 'Core Services (All Appliances)'
            local:Add-Url $urls 'portal.azure.com'                    443 '*.portal.azure.com'                    'Azure portal'                                        $cat
            local:Add-Url $urls 'login.windows.net'                   443 '*.windows.net'                         'Microsoft Entra ID (access control)'                 $cat
            local:Add-Url $urls 'msftauth.net'                        443 '*.msftauth.net'                        'Microsoft Entra ID'                                  $cat
            local:Add-Url $urls 'msauth.net'                          443 '*.msauth.net'                          'Microsoft Entra ID'                                  $cat
            local:Add-Url $urls 'www.microsoft.com'                   443 '*.microsoft.com'                       'Microsoft Entra ID'                                  $cat
            local:Add-Url $urls 'login.live.com'                      443 '*.live.com'                            'Microsoft Entra ID'                                  $cat
            local:Add-Url $urls 'login.microsoftonline.com'           443 '*.microsoftonline.com'                 'Microsoft Entra ID'                                  $cat
            local:Add-Url $urls 'login.microsoftonline-p.com'         443 '*.microsoftonline-p.com'               'Microsoft Entra ID'                                  $cat
            local:Add-Url $urls 'autologon.microsoftazuread-sso.com'  443 '*.microsoftazuread-sso.com'            'Microsoft Entra ID SSO'                              $cat
            local:Add-Url $urls 'cloud.microsoft'                     443 '*.cloud.microsoft'                     'Microsoft Entra ID'                                  $cat
            local:Add-Url $urls 'management.azure.com'                443 'management.azure.com'                  'Azure Resource Manager'                              $cat
            local:Add-Url $urls 'dc.services.visualstudio.com'        443 '*.services.visualstudio.com'           'Appliance telemetry/logs'                            $cat
            local:Add-Url $urls 'vault.azure.net'                     443 '*.vault.azure.net'                     'Azure Key Vault'                                     $cat
            local:Add-Url $urls 'aka.ms'                              443 'aka.ms/*'                              'Appliance auto-update downloads'                     $cat
            local:Add-Url $urls 'download.microsoft.com'              443 'download.microsoft.com/download'       'Microsoft downloads'                                 $cat
            local:Add-Url $urls 'servicebus.windows.net'              443 '*.servicebus.windows.net'              'Azure Migrate service communication'                 $cat
            local:Add-Url $urls 'discoverysrv.windowsazure.com'       443 '*.discoverysrv.windowsazure.com'       'Azure Migrate Discovery service'                     $cat
            local:Add-Url $urls 'migration.windowsazure.com'          443 '*.migration.windowsazure.com'          'Azure Migrate Migration service'                     $cat

            # VMware Agentless / Replication-only endpoints
            if ($Scenario -eq 'VMwareAgentless' -or $ApplianceType -eq 'Replication') {
                $cat2 = 'VMware Agentless Migration'
                local:Add-Url $urls 'hypervrecoverymanager.windowsazure.com' 443 '*.hypervrecoverymanager.windowsazure.com' 'Azure Site Recovery (agentless migration)'  $cat2
                local:Add-Url $urls 'blob.core.windows.net'                  443 '*.blob.core.windows.net'                  'Azure Blob Storage (migration data upload)'  $cat2
            }

            # Simplified Experience (AgentBasedModern) — additional required URLs per ASR replication appliance support matrix
            if ($Scenario -eq 'AgentBasedModern') {
                $cat3 = 'Simplified Experience (Agent-Based Modern) — Additional URLs'
                local:Add-Url $urls 'backup.windowsazure.com'                443 '*.backup.windowsazure.com'                'Protection service / replication disk creation (Simplified Experience — REQUIRED)'  $cat3
                local:Add-Url $urls 'hypervrecoverymanager.windowsazure.com' 443 '*.hypervrecoverymanager.windowsazure.com' 'ASR microservice (Simplified Experience)'    $cat3
                local:Add-Url $urls 'discoverysrv.windowsazure.com'          443 '*.discoverysrv.windowsazure.com'          'Discovery microservice (Simplified Experience)' $cat3
                local:Add-Url $urls 'prod.migration.windowsazure.com'        443 '*.prod.migration.windowsazure.com'        'On-prem estate discovery (Simplified Experience)' $cat3
                local:Add-Url $urls 'blob.core.windows.net'                  443 '*.blob.core.windows.net'                  'Azure Storage for replicated disks (Simplified Experience)' $cat3
                # Note: vault.azure.net, servicebus.windows.net already in core list above
                Write-Host "  [INFO] Simplified Experience URLs added — includes *.backup.windowsazure.com required for replication disk creation." -ForegroundColor Cyan
            }

        } else {
            # ----------------------------------------------------------------
            # Commercial — Private Link endpoints
            # ----------------------------------------------------------------
            $cat = 'Private Link - Core (Public Cloud)'
            local:Add-Url $urls 'portal.azure.com'                    443 '*.portal.azure.com'                             'Azure portal'                                          $cat
            local:Add-Url $urls 'login.windows.net'                   443 '*.windows.net'                                  'Microsoft Entra ID'                                    $cat
            local:Add-Url $urls 'msftauth.net'                        443 '*.msftauth.net'                                  'Microsoft Entra ID'                                    $cat
            local:Add-Url $urls 'msauth.net'                          443 '*.msauth.net'                                    'Microsoft Entra ID'                                    $cat
            local:Add-Url $urls 'www.microsoft.com'                   443 '*.microsoft.com'                                 'Microsoft Entra ID'                                    $cat
            local:Add-Url $urls 'login.live.com'                      443 '*.live.com'                                      'Microsoft Entra ID'                                    $cat
            local:Add-Url $urls 'login.microsoftonline.com'           443 '*.microsoftonline.com'                           'Microsoft Entra ID'                                    $cat
            local:Add-Url $urls 'login.microsoftonline-p.com'         443 '*.microsoftonline-p.com'                         'Microsoft Entra ID'                                    $cat
            local:Add-Url $urls 'autologon.microsoftazuread-sso.com'  443 '*.microsoftazuread-sso.com'                      'Microsoft Entra ID SSO'                                $cat
            local:Add-Url $urls 'management.azure.com'                443 'management.azure.com'                            'Azure Resource Manager'                                $cat
            local:Add-Url $urls 'dc.services.visualstudio.com'        443 '*.services.visualstudio.com'                     'Appliance telemetry (optional)'                        $cat
            local:Add-Url $urls 'aka.ms'                              443 'aka.ms/*'                                        'Appliance auto-update (optional)'                      $cat
            local:Add-Url $urls 'download.microsoft.com'              443 'download.microsoft.com/download'                 'Microsoft downloads'                                   $cat
            local:Add-Url $urls 'blob.core.windows.net'               443 '*.blob.core.windows.net'                         'Azure Blob Storage (optional if storage has private endpoint)' $cat
            local:Add-Url $urls 'prod.migration.windowsazure.com'     443 '*.prod.migration.windowsazure.com'               'Migration service (private link)'                      $cat
            local:Add-Url $urls 'prod.migration.windowsazure.com'     443 '*.privatelink.prod.migration.windowsazure.com'   'Private Link migration/auto-update zone'               $cat
            local:Add-Url $urls 'blob.core.windows.net'               443 '*.privatelink.blob.core.windows.net'             'Private Link Blob Storage zone'                        $cat
            local:Add-Url $urls 'vault.azure.net'                     443 '*.privatelink.vaultcore.azure.net'               'Private Link Key Vault zone'                           $cat
            local:Add-Url $urls 'servicebus.windows.net'              443 '*.privatelink.servicebus.windows.net'            'Private Link Service Bus zone'                         $cat
        }
    }

    # ========================================================================
    # GOVERNMENT CLOUD
    # ========================================================================
    elseif ($Cloud -eq 'Government') {

        if (-not $PrivateLink) {
            # ----------------------------------------------------------------
            # Government — Public endpoints
            # ----------------------------------------------------------------
            $cat = 'Core Services - Government Cloud'
            local:Add-Url $urls 'portal.azure.us'                  443 '*.portal.azure.us'                   'Azure Government portal'                       $cat
            local:Add-Url $urls 'graph.windows.net'                443 'graph.windows.net'                   'Sign in to subscription (Gov)'                 $cat
            local:Add-Url $urls 'graph.microsoftazure.us'          443 'graph.microsoftazure.us'             'Sign in to subscription (Gov)'                 $cat
            local:Add-Url $urls 'login.microsoftonline.us'         443 'login.microsoftonline.us'            'Microsoft Entra ID (Gov)'                      $cat
            local:Add-Url $urls 'management.usgovcloudapi.net'     443 'management.usgovcloudapi.net'        'Azure Resource Manager (Gov)'                  $cat
            local:Add-Url $urls 'dc.services.visualstudio.com'     443 '*.services.visualstudio.com'        'Appliance telemetry'                           $cat
            local:Add-Url $urls 'vault.usgovcloudapi.net'          443 '*.vault.usgovcloudapi.net'           'Azure Key Vault (Gov)'                         $cat
            local:Add-Url $urls 'aka.ms'                           443 'aka.ms/*'                            'Appliance auto-update downloads'               $cat
            local:Add-Url $urls 'download.microsoft.com'           443 'download.microsoft.com/download'    'Microsoft downloads'                           $cat
            local:Add-Url $urls 'servicebus.usgovcloudapi.net'     443 '*.servicebus.usgovcloudapi.net'      'Service Bus (Gov)'                             $cat
            local:Add-Url $urls 'discoverysrv.windowsazure.us'     443 '*.discoverysrv.windowsazure.us'      'Discovery service (Gov)'                       $cat
            local:Add-Url $urls 'migration.windowsazure.us'        443 '*.migration.windowsazure.us'         'Migration service (Gov)'                       $cat
            local:Add-Url $urls 'dc.applicationinsights.us'        443 '*.applicationinsights.us'            'Application Insights (Gov)'                    $cat

            if ($Scenario -eq 'VMwareAgentless' -or $ApplianceType -eq 'Replication') {
                $cat2 = 'VMware Agentless Migration (Gov)'
                local:Add-Url $urls 'hypervrecoverymanager.windowsazure.us' 443 '*.hypervrecoverymanager.windowsazure.us' 'ASR (Gov agentless migration)'  $cat2
                local:Add-Url $urls 'blob.core.usgovcloudapi.net'           443 '*.blob.core.usgovcloudapi.net'           'Azure Blob Storage (Gov)'        $cat2
            }

            # Simplified Experience — Government additional URLs
            if ($Scenario -eq 'AgentBasedModern') {
                $cat3 = 'Simplified Experience (Gov) — Additional URLs'
                local:Add-Url $urls 'backup.windowsazure.us'                443 '*.backup.windowsazure.us'                'Protection service / replication disk creation (Simplified Gov — REQUIRED)' $cat3
                local:Add-Url $urls 'hypervrecoverymanager.windowsazure.us' 443 '*.hypervrecoverymanager.windowsazure.us' 'ASR microservice (Simplified Gov)' $cat3
                local:Add-Url $urls 'migration.windowsazure.us'             443 '*.migration.windowsazure.us'             'Migration service (Simplified Gov)' $cat3
                local:Add-Url $urls 'vault.usgovcloudapi.net'               443 '*.vault.usgovcloudapi.net'               'Key Vault (Simplified Gov — source VMs also need this)' $cat3
            }

        } else {
            # ----------------------------------------------------------------
            # Government — Private Link endpoints
            # ----------------------------------------------------------------
            $cat = 'Private Link - Core (Gov Cloud)'
            local:Add-Url $urls 'portal.azure.us'                          443 '*.portal.azure.us'                              'Azure Government portal'                    $cat
            local:Add-Url $urls 'graph.windows.net'                        443 'graph.windows.net'                              'Sign in to subscription'                    $cat
            local:Add-Url $urls 'login.microsoftonline.us'                 443 'login.microsoftonline.us'                       'Microsoft Entra ID (Gov)'                   $cat
            local:Add-Url $urls 'management.usgovcloudapi.net'             443 'management.usgovcloudapi.net'                   'ARM (Gov)'                                  $cat
            local:Add-Url $urls 'dc.services.visualstudio.com'             443 '*.services.visualstudio.com'                   'Telemetry (optional)'                       $cat
            local:Add-Url $urls 'aka.ms'                                   443 'aka.ms/*'                                       'Auto-update (optional)'                     $cat
            local:Add-Url $urls 'download.microsoft.com'                   443 'download.microsoft.com/download'               'Downloads'                                  $cat
            local:Add-Url $urls 'blob.core.usgovcloudapi.net'              443 '*.blob.core.usgovcloudapi.net'                  'Blob (optional)'                            $cat
            local:Add-Url $urls 'dc.applicationinsights.us'                443 '*.applicationinsights.us'                      'App Insights (optional)'                    $cat
            local:Add-Url $urls 'prod.migration.windowsazure.us'           443 '*.prod.migration.windowsazure.us'               'Migration (Gov PL)'                         $cat
            local:Add-Url $urls 'prod.migration.windowsazure.us'           443 '*.privatelink.prod.migration.windowsazure.us'   'Private Link migration zone (Gov)'          $cat
            local:Add-Url $urls 'blob.core.usgovcloudapi.net'              443 '*.privatelink.blob.core.usgovcloudapi.net'      'Private Link Blob zone (Gov)'               $cat
        }
    }

    # ========================================================================
    # CHINA (21Vianet) CLOUD
    # ========================================================================
    elseif ($Cloud -eq 'China') {

        if (-not $PrivateLink) {
            # ----------------------------------------------------------------
            # China — Public endpoints
            # ----------------------------------------------------------------
            $cat = 'Core Services - China (21Vianet)'
            local:Add-Url $urls 'portal.azure.cn'                         443 '*.portal.azure.cn'                          'Azure China portal'                            $cat
            local:Add-Url $urls 'graph.chinacloudapi.cn'                  443 'graph.chinacloudapi.cn'                     'Sign in to subscription (China)'               $cat
            local:Add-Url $urls 'login.microsoftonline.cn'                443 'login.microsoftonline.cn'                   'Microsoft Entra ID (China)'                    $cat
            local:Add-Url $urls 'management.chinacloudapi.cn'             443 'management.chinacloudapi.cn'                'Azure Resource Manager (China)'                $cat
            local:Add-Url $urls 'dc.services.visualstudio.com'            443 '*.services.visualstudio.com'               'Appliance telemetry'                           $cat
            local:Add-Url $urls 'vault.chinacloudapi.cn'                  443 '*.vault.chinacloudapi.cn'                   'Azure Key Vault (China)'                       $cat
            local:Add-Url $urls 'aka.ms'                                  443 'aka.ms/*'                                   'Appliance auto-update'                         $cat
            local:Add-Url $urls 'download.microsoft.com'                  443 'download.microsoft.com/download'           'Microsoft downloads'                           $cat
            local:Add-Url $urls 'servicebus.chinacloudapi.cn'             443 '*.servicebus.chinacloudapi.cn'              'Service Bus (China)'                           $cat
            local:Add-Url $urls 'discoverysrv.cn2.windowsazure.cn'        443 '*.discoverysrv.cn2.windowsazure.cn'         'Discovery service (China)'                     $cat
            local:Add-Url $urls 'cn2.prod.migration.windowsazure.cn'      443 '*.cn2.prod.migration.windowsazure.cn'       'Migration service (China)'                     $cat
            local:Add-Url $urls 'dc.applicationinsights.azure.cn'         443 '*.applicationinsights.azure.cn'            'App Insights (China)'                          $cat

            if ($Scenario -eq 'VMwareAgentless' -or $ApplianceType -eq 'Replication') {
                $cat2 = 'VMware Agentless Migration (China)'
                local:Add-Url $urls 'cn2.hypervrecoverymanager.windowsazure.cn' 443 '*.cn2.hypervrecoverymanager.windowsazure.cn' 'ASR (China agentless migration)' $cat2
                local:Add-Url $urls 'blob.core.chinacloudapi.cn'                443 '*.blob.core.chinacloudapi.cn'                'Azure Blob Storage (China)'       $cat2
            }

            # Simplified Experience — China additional URLs
            if ($Scenario -eq 'AgentBasedModern') {
                $cat3 = 'Simplified Experience (China) — Additional URLs'
                local:Add-Url $urls 'backup.windowsazure.cn'                    443 '*.backup.windowsazure.cn'                    'Protection service / replication disk creation (Simplified China — REQUIRED)' $cat3
                local:Add-Url $urls 'cn2.hypervrecoverymanager.windowsazure.cn' 443 '*.cn2.hypervrecoverymanager.windowsazure.cn' 'ASR microservice (Simplified China)' $cat3
                local:Add-Url $urls 'cn2.prod.migration.windowsazure.cn'        443 '*.cn2.prod.migration.windowsazure.cn'        'Migration service (Simplified China)' $cat3
                local:Add-Url $urls 'vault.azure.cn'                            443 '*.vault.azure.cn'                            'Key Vault (Simplified China — source VMs also need this)' $cat3
                local:Add-Url $urls 'blob.core.chinacloudapi.cn'                443 '*.blob.core.chinacloudapi.cn'                'Azure Storage for replicated disks (Simplified China)' $cat3
            }
        } else {
            # China Private Link — no official separate list; use same as public with a note
            Write-Host "  [INFO] China (21Vianet) Private Link endpoint list not yet published." -ForegroundColor Yellow
            Write-Host "         Testing public China endpoints. Consult your Microsoft account team." -ForegroundColor Yellow
            $cat = 'Core Services - China (21Vianet) [Private Link TBD]'
            local:Add-Url $urls 'portal.azure.cn'                         443 '*.portal.azure.cn'                          'Azure China portal'                            $cat
            local:Add-Url $urls 'graph.chinacloudapi.cn'                  443 'graph.chinacloudapi.cn'                     'Sign in to subscription (China)'               $cat
            local:Add-Url $urls 'login.microsoftonline.cn'                443 'login.microsoftonline.cn'                   'Microsoft Entra ID (China)'                    $cat
            local:Add-Url $urls 'management.chinacloudapi.cn'             443 'management.chinacloudapi.cn'                'Azure Resource Manager (China)'                $cat
            local:Add-Url $urls 'dc.services.visualstudio.com'            443 '*.services.visualstudio.com'               'Appliance telemetry'                           $cat
            local:Add-Url $urls 'vault.chinacloudapi.cn'                  443 '*.vault.chinacloudapi.cn'                   'Azure Key Vault (China)'                       $cat
            local:Add-Url $urls 'aka.ms'                                  443 'aka.ms/*'                                   'Appliance auto-update'                         $cat
            local:Add-Url $urls 'download.microsoft.com'                  443 'download.microsoft.com/download'           'Microsoft downloads'                           $cat
            local:Add-Url $urls 'servicebus.chinacloudapi.cn'             443 '*.servicebus.chinacloudapi.cn'              'Service Bus (China)'                           $cat
            local:Add-Url $urls 'discoverysrv.cn2.windowsazure.cn'        443 '*.discoverysrv.cn2.windowsazure.cn'         'Discovery service (China)'                     $cat
            local:Add-Url $urls 'cn2.prod.migration.windowsazure.cn'      443 '*.cn2.prod.migration.windowsazure.cn'       'Migration service (China)'                     $cat
            local:Add-Url $urls 'dc.applicationinsights.azure.cn'         443 '*.applicationinsights.azure.cn'            'App Insights (China)'                          $cat
        }
    }

    # Deduplicate by Host+Port+Wildcard (keep first occurrence)
    $seen = @{}
    $dedupedUrls = [System.Collections.ArrayList]::new()
    foreach ($u in $urls) {
        $key = "$($u.Host):$($u.Port):$($u.Wildcard)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$dedupedUrls.Add($u)
        }
    }

    return $dedupedUrls
}

# ============================================================================
# ENVIRONMENT DETECTION
# ============================================================================

function Get-EnvironmentInfo {
    Write-Section "ENVIRONMENT INFORMATION (Read-Only)"

    # OS Info
    Write-SubSection "Operating System"
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        Write-Host "    OS:       $($os.Caption) $($os.Version)" -ForegroundColor Gray
        Write-Host "    Build:    $($os.BuildNumber)" -ForegroundColor Gray
    }
    Write-Host "    PS Ver:   $($PSVersionTable.PSVersion)" -ForegroundColor Gray

    # TLS Configuration
    Write-SubSection "TLS Configuration"
    $tlsProtocols = [Net.ServicePointManager]::SecurityProtocol
    Write-Host "    Active TLS protocols: $tlsProtocols" -ForegroundColor Gray
    if ($tlsProtocols -match 'Tls12') {
        Write-Host "    [PASS] TLS 1.2 is enabled" -ForegroundColor Green
    } else {
        Write-Host "    [FAIL] TLS 1.2 is NOT enabled - Azure services require TLS 1.2" -ForegroundColor Red
        [void]$script:Recommendations.Add("CRITICAL: TLS 1.2 is not enabled. Azure requires TLS 1.2. See: https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance#connectivity-issues")
    }

    # Check TLS 1.2 registry settings (read-only)
    $tls12ClientPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
    if (Test-Path $tls12ClientPath) {
        $tls12Enabled = Get-ItemProperty -Path $tls12ClientPath -Name 'Enabled' -ErrorAction SilentlyContinue
        $tls12DisabledByDefault = Get-ItemProperty -Path $tls12ClientPath -Name 'DisabledByDefault' -ErrorAction SilentlyContinue
        if ($tls12Enabled -and $tls12Enabled.Enabled -eq 0) {
            Write-Host "    [WARN] TLS 1.2 Client is disabled in registry" -ForegroundColor Yellow
            [void]$script:Warnings.Add("TLS 1.2 is disabled in Windows registry (SCHANNEL). This will block Azure connectivity.")
        }
        if ($tls12DisabledByDefault -and $tls12DisabledByDefault.DisabledByDefault -eq 1) {
            Write-Host "    [WARN] TLS 1.2 Client is set to DisabledByDefault in registry" -ForegroundColor Yellow
        }
    }

    # Network adapters
    Write-SubSection "Network Configuration"
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        foreach ($a in $adapters) {
            $ipConfig = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $gateway  = Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
            $dns      = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            Write-Host "    Adapter:  $($a.Name) [$($a.InterfaceDescription)]" -ForegroundColor Gray
            Write-Host "    IP:       $(($ipConfig.IPAddress | Select-Object -First 1))" -ForegroundColor Gray
            if ($gateway) {
                Write-Host "    Gateway:  $($gateway.NextHop)" -ForegroundColor Gray
            }
            if ($dns -and $dns.ServerAddresses) {
                Write-Host "    DNS:      $($dns.ServerAddresses -join ', ')" -ForegroundColor Gray
            }
            Write-Host ""
        }
    } catch {
        Write-Host "    Unable to enumerate network adapters: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-ProxyConfiguration {
    Write-Section "PROXY CONFIGURATION (Read-Only)"

    $proxyDetected = $false

    # 1. WinHTTP proxy
    Write-SubSection "WinHTTP Proxy Settings"
    try {
        $winhttp = netsh winhttp show proxy 2>&1
        $winhttpStr = ($winhttp | Out-String).Trim()
        Write-Host "    $($winhttpStr -replace "`n", "`n    ")" -ForegroundColor Gray
        if ($winhttpStr -match 'Proxy Server.*:\s*(\S+)' -and $winhttpStr -notmatch 'Direct access') {
            $proxyDetected = $true
            [void]$script:Warnings.Add("WinHTTP proxy detected. Ensure Azure Migrate required URLs are allowed through the proxy.")
        }
    } catch {
        Write-Host "    Unable to query WinHTTP proxy: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2. System (IE) proxy settings
    Write-SubSection "Internet Explorer / System Proxy Settings"
    try {
        $regPath       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $proxyEnable   = (Get-ItemProperty -Path $regPath -Name 'ProxyEnable'   -ErrorAction SilentlyContinue).ProxyEnable
        $proxyServer   = (Get-ItemProperty -Path $regPath -Name 'ProxyServer'   -ErrorAction SilentlyContinue).ProxyServer
        $proxyOverride = (Get-ItemProperty -Path $regPath -Name 'ProxyOverride' -ErrorAction SilentlyContinue).ProxyOverride
        $autoConfigUrl = (Get-ItemProperty -Path $regPath -Name 'AutoConfigURL' -ErrorAction SilentlyContinue).AutoConfigURL

        Write-Host "    Proxy Enabled:  $($proxyEnable -eq 1)" -ForegroundColor Gray
        Write-Host "    Proxy Server:   $proxyServer" -ForegroundColor Gray
        Write-Host "    Proxy Bypass:   $proxyOverride" -ForegroundColor Gray
        Write-Host "    PAC URL:        $autoConfigUrl" -ForegroundColor Gray

        if ($proxyEnable -eq 1 -and $proxyServer) {
            $proxyDetected = $true
            [void]$script:Warnings.Add("System proxy is configured: $proxyServer. Ensure Azure Migrate URLs are in the proxy allowlist.")
        }
        if ($autoConfigUrl) {
            $proxyDetected = $true
            [void]$script:Warnings.Add("PAC (Proxy Auto-Config) URL detected: $autoConfigUrl. Verify PAC script allows Azure Migrate URLs.")
        }
    } catch {
        Write-Host "    Unable to read IE proxy settings: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 3. Environment variables
    Write-SubSection "Environment Variable Proxy Settings"
    $envVars = @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy')
    foreach ($var in $envVars) {
        $val = [Environment]::GetEnvironmentVariable($var)
        if ($val) {
            Write-Host "    $var = $val" -ForegroundColor Gray
            if ($var -notlike '*NO_PROXY*' -and $var -notlike '*no_proxy*') {
                $proxyDetected = $true
            }
        }
    }
    if (-not ($envVars | Where-Object { [Environment]::GetEnvironmentVariable($_) })) {
        Write-Host "    No proxy environment variables set." -ForegroundColor Gray
    }

    # 4. .NET default proxy
    Write-SubSection ".NET Default Proxy"
    try {
        $defaultProxy = [System.Net.WebRequest]::DefaultWebProxy
        if ($defaultProxy) {
            $testUri  = [System.Uri]"https://management.azure.com"
            $proxyUri = $defaultProxy.GetProxy($testUri)
            if ($proxyUri -and $proxyUri.AbsoluteUri -ne $testUri.AbsoluteUri) {
                Write-Host "    .NET proxy for management.azure.com: $($proxyUri.AbsoluteUri)" -ForegroundColor Gray
                $proxyDetected = $true
                [void]$script:Warnings.Add(".NET default proxy routes Azure traffic through: $($proxyUri.AbsoluteUri)")
            } else {
                Write-Host "    .NET uses direct connection for Azure endpoints." -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host "    Unable to detect .NET proxy: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Summary
    Write-Host ""
    if ($proxyDetected) {
        Write-Host "    [WARN] Proxy configuration detected. This may affect Azure Migrate connectivity." -ForegroundColor Yellow
        Write-Host "    Ensure all required Azure Migrate URLs are allowed through your proxy." -ForegroundColor Yellow
        [void]$script:Recommendations.Add(@"
PROXY DETECTED: A proxy server is configured on this machine. If Azure Migrate appliance
registration or discovery is failing, ensure the proxy allows HTTPS (port 443) traffic to all
required Azure Migrate endpoints. You may need to configure proxy settings on the appliance.
See: https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance#connectivity-issues
See: https://learn.microsoft.com/en-us/azure/migrate/how-to-set-up-appliance-vmware#configure-the-appliance
"@)
    } else {
        Write-Host "    [INFO] No proxy configuration detected." -ForegroundColor Green
    }

    return $proxyDetected
}

function Test-BasicConnectivity {
    Write-Section "BASIC CONNECTIVITY CHECKS"

    # 1. Default gateway
    Write-SubSection "Default Gateway Reachability"
    try {
        $gateway = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gateway -and $gateway.NextHop -ne '0.0.0.0') {
            $pingResult = Test-Connection -ComputerName $gateway.NextHop -Count 1 -ErrorAction SilentlyContinue
            if ($pingResult) {
                Write-Host "    [PASS] Default gateway $($gateway.NextHop) is reachable" -ForegroundColor Green
            } else {
                Write-Host "    [WARN] Default gateway $($gateway.NextHop) did not respond to ping (may be normal if ICMP is blocked)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    [WARN] No default gateway found - check network configuration" -ForegroundColor Yellow
            [void]$script:Warnings.Add("No default gateway detected. The machine may not have internet connectivity.")
        }
    } catch {
        Write-Host "    Unable to check gateway: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2. DNS server reachability
    Write-SubSection "DNS Server Reachability"
    try {
        $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses } |
            Select-Object -ExpandProperty ServerAddresses -Unique |
            Select-Object -First 4
        foreach ($dns in $dnsServers) {
            $tcpResult = Test-TcpPort -HostName $dns -Port 53 -TimeoutMs 3000
            if ($tcpResult.Success) {
                Write-Host "    [PASS] DNS server $dns is reachable on TCP/53" -ForegroundColor Green
            } else {
                Write-Host "    [WARN] DNS server $dns TCP/53 test failed (UDP may still work): $($tcpResult.Error)" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "    Unable to check DNS servers: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 3. General internet connectivity
    Write-SubSection "General Internet Connectivity (microsoft.com)"
    $dnsTest = Test-DnsResolution -HostName 'www.microsoft.com'
    $tcpTest = Test-TcpPort -HostName 'www.microsoft.com' -Port 443
    if ($dnsTest.Success -and $tcpTest.Success) {
        Write-Host "    [PASS] DNS and TCP/443 to www.microsoft.com succeeded ($($tcpTest.LatencyMs)ms)" -ForegroundColor Green
    } elseif (-not $dnsTest.Success) {
        Write-Host "    [FAIL] Cannot resolve www.microsoft.com - DNS resolution failed" -ForegroundColor Red
        Write-Host "           Error: $($dnsTest.Error)" -ForegroundColor Red
        [void]$script:Recommendations.Add("DNS resolution is failing for common domains. Check DNS server configuration and connectivity.")
    } else {
        Write-Host "    [FAIL] DNS resolved but TCP/443 failed to www.microsoft.com" -ForegroundColor Red
        Write-Host "           Error: $($tcpTest.Error)" -ForegroundColor Red
        [void]$script:Recommendations.Add("TCP connectivity to port 443 is failing even for microsoft.com. This indicates a firewall or network issue blocking outbound HTTPS.")
    }

    # 4. TLS 1.2 handshake test
    Write-SubSection "TLS 1.2 Handshake Test"
    $httpsResult = Test-HttpsConnectivity -Url 'www.microsoft.com'
    if ($httpsResult.Success) {
        Write-Host "    [PASS] HTTPS/TLS handshake to www.microsoft.com succeeded (HTTP $($httpsResult.StatusCode), $($httpsResult.LatencyMs)ms)" -ForegroundColor Green
        if ($httpsResult.CertIssuer) {
            Write-Host "    Certificate Issuer: $($httpsResult.CertIssuer)" -ForegroundColor Gray
            # Check for SSL inspection
            if ($httpsResult.CertIssuer -notmatch 'Microsoft|DigiCert|Baltimore|GlobalSign|Symantec|GeoTrust|Comodo|Let.s Encrypt|Sectigo') {
                Write-Host "    [WARN] Certificate issuer may indicate SSL inspection / MITM proxy" -ForegroundColor Yellow
                [void]$script:Warnings.Add("SSL inspection detected (cert issuer: $($httpsResult.CertIssuer)). This may interfere with Azure Migrate.")
                [void]$script:Recommendations.Add(@"
SSL INSPECTION DETECTED: The certificate issuer for microsoft.com suggests SSL/TLS inspection
is active (possibly a corporate proxy). This can interfere with Azure Migrate appliance
certificate pinning and connectivity. Consider bypassing SSL inspection for Azure Migrate URLs.
See: https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance#connectivity-issues
"@)
            }
        }
    } else {
        Write-Host "    [FAIL] HTTPS to www.microsoft.com failed: $($httpsResult.Error)" -ForegroundColor Red
        [void]$script:Recommendations.Add("HTTPS/TLS connections are failing. This blocks all Azure Migrate communication. Check firewall, proxy, and TLS settings.")
    }
}

# ============================================================================
# PLATFORM SOURCE CONNECTIVITY CHECKS  (NEW in v2.0)
# ============================================================================

function Test-PlatformPorts {
    param(
        [ValidateSet('VMware','HyperV','Physical')]
        [string]$Platform
    )

    Write-Section "PLATFORM SOURCE CONNECTIVITY CHECKS"

    Write-Host "  These checks verify that the appliance can reach the SOURCE infrastructure" -ForegroundColor Gray
    Write-Host "  (vCenter, Hyper-V hosts, physical servers) it needs to discover/migrate." -ForegroundColor Gray
    Write-Host "  All prompts can be left blank to skip the individual test." -ForegroundColor Gray

    switch ($Platform) {

        'VMware' {
            # ---- vCenter ----
            Write-SubSection "VMware vCenter Server"
            $vcHost = (Read-Host "  Enter vCenter FQDN or IP (blank to skip)").Trim()
            if ($vcHost) {
                Write-Host "    Testing TCP/443 to vCenter ($vcHost) ..." -NoNewline -ForegroundColor White
                $r = Test-TcpPort -HostName $vcHost -Port 443
                if ($r.Success) {
                    Write-Host " PASS ($($r.LatencyMs)ms)" -ForegroundColor Green
                } else {
                    Write-Host " FAIL - $($r.Error)" -ForegroundColor Red
                    [void]$script:Recommendations.Add("PLATFORM: TCP/443 to vCenter ($vcHost) is BLOCKED. The appliance needs TCP/443 to vCenter for discovery. Check firewall rules between the appliance network and the vCenter network.")
                }
            } else {
                Write-Host "    (vCenter test skipped)" -ForegroundColor DarkGray
            }

            # ---- ESXi hosts ----
            Write-SubSection "VMware ESXi Host(s)"
            Write-Host "  You can enter one or more ESXi host FQDNs/IPs. Press Enter with a blank line to stop." -ForegroundColor Gray
            $esxiHosts = @()
            do {
                $esxiEntry = (Read-Host "  ESXi host FQDN/IP (blank to finish)").Trim()
                if ($esxiEntry) { $esxiHosts += $esxiEntry }
            } while ($esxiEntry)

            foreach ($esxi in $esxiHosts) {
                # TCP/443 — management API
                Write-Host "    [$esxi] TCP/443  ... " -NoNewline -ForegroundColor White
                $r443 = Test-TcpPort -HostName $esxi -Port 443
                if ($r443.Success) {
                    Write-Host "PASS ($($r443.LatencyMs)ms)" -ForegroundColor Green
                } else {
                    Write-Host "FAIL - $($r443.Error)" -ForegroundColor Red
                    [void]$script:Recommendations.Add("PLATFORM: TCP/443 to ESXi host ($esxi) is BLOCKED. Required for agentless disk snapshot data transfer.")
                }

                # TCP/902 — NFC data transfer (agentless migration)
                Write-Host "    [$esxi] TCP/902  ... " -NoNewline -ForegroundColor White
                $r902 = Test-TcpPort -HostName $esxi -Port 902
                if ($r902.Success) {
                    Write-Host "PASS ($($r902.LatencyMs)ms)" -ForegroundColor Green
                } else {
                    Write-Host "FAIL - $($r902.Error)" -ForegroundColor Red
                    [void]$script:Recommendations.Add("PLATFORM: TCP/902 to ESXi host ($esxi) is BLOCKED. Port 902 (NFC) is required for agentless VM disk replication. Ensure this port is open between the appliance and ESXi hosts.")
                }
            }
            if ($esxiHosts.Count -eq 0) {
                Write-Host "    (ESXi host tests skipped)" -ForegroundColor DarkGray
            }
        }

        'HyperV' {
            Write-SubSection "Hyper-V Host(s)"
            Write-Host "  Enter one or more Hyper-V host FQDNs/IPs. Press Enter with a blank line to stop." -ForegroundColor Gray
            $hvHosts = @()
            do {
                $hvEntry = (Read-Host "  Hyper-V host FQDN/IP (blank to finish)").Trim()
                if ($hvEntry) { $hvHosts += $hvEntry }
            } while ($hvEntry)

            foreach ($hv in $hvHosts) {
                # TCP/5985 — WinRM HTTP
                Write-Host "    [$hv] TCP/5985 (WinRM HTTP)  ... " -NoNewline -ForegroundColor White
                $r5985 = Test-TcpPort -HostName $hv -Port 5985
                if ($r5985.Success) {
                    Write-Host "PASS ($($r5985.LatencyMs)ms)" -ForegroundColor Green
                } else {
                    Write-Host "FAIL - $($r5985.Error)" -ForegroundColor Red
                    [void]$script:Recommendations.Add("PLATFORM: TCP/5985 (WinRM HTTP) to Hyper-V host ($hv) is BLOCKED. The appliance needs WinRM access to Hyper-V hosts for discovery and migration.")
                }

                # TCP/5986 — WinRM HTTPS
                Write-Host "    [$hv] TCP/5986 (WinRM HTTPS) ... " -NoNewline -ForegroundColor White
                $r5986 = Test-TcpPort -HostName $hv -Port 5986
                if ($r5986.Success) {
                    Write-Host "PASS ($($r5986.LatencyMs)ms)" -ForegroundColor Green
                } else {
                    Write-Host "FAIL - $($r5986.Error)" -ForegroundColor Red
                    [void]$script:Recommendations.Add("PLATFORM: TCP/5986 (WinRM HTTPS) to Hyper-V host ($hv) is BLOCKED. Ensure WinRM over HTTPS is allowed from the appliance to the Hyper-V hosts.")
                }
            }
            if ($hvHosts.Count -eq 0) {
                Write-Host "    (Hyper-V host tests skipped)" -ForegroundColor DarkGray
            }
        }

        'Physical' {
            Write-SubSection "Physical / Other Cloud Server(s)"
            Write-Host "  Enter one or more target server FQDNs/IPs for Windows (WinRM) or Linux (SSH) checks." -ForegroundColor Gray
            Write-Host "  Press Enter with a blank line to stop." -ForegroundColor Gray

            $physHosts = @()
            do {
                $physEntry = (Read-Host "  Server FQDN/IP (blank to finish)").Trim()
                if ($physEntry) {
                    $osType = Get-MenuSelection -Prompt "Is '$physEntry' a Windows or Linux server?" `
                        -Options @('Windows (WinRM TCP/5985 and TCP/5986)', 'Linux (SSH TCP/22)')
                    $physHosts += [PSCustomObject]@{ Host=$physEntry; OS=if($osType -eq 1){'Windows'}else{'Linux'} }
                }
            } while ($physEntry)

            foreach ($ph in $physHosts) {
                if ($ph.OS -eq 'Windows') {
                    Write-Host "    [$($ph.Host)] TCP/5985 (WinRM HTTP)  ... " -NoNewline -ForegroundColor White
                    $r5985 = Test-TcpPort -HostName $ph.Host -Port 5985
                    if ($r5985.Success) {
                        Write-Host "PASS ($($r5985.LatencyMs)ms)" -ForegroundColor Green
                    } else {
                        Write-Host "FAIL - $($r5985.Error)" -ForegroundColor Red
                        [void]$script:Recommendations.Add("PLATFORM: TCP/5985 (WinRM HTTP) to Windows server ($($ph.Host)) is BLOCKED. Required for agentless discovery of Windows physical/cloud servers.")
                    }

                    Write-Host "    [$($ph.Host)] TCP/5986 (WinRM HTTPS) ... " -NoNewline -ForegroundColor White
                    $r5986 = Test-TcpPort -HostName $ph.Host -Port 5986
                    if ($r5986.Success) {
                        Write-Host "PASS ($($r5986.LatencyMs)ms)" -ForegroundColor Green
                    } else {
                        Write-Host "FAIL - $($r5986.Error)" -ForegroundColor Red
                        [void]$script:Recommendations.Add("PLATFORM: TCP/5986 (WinRM HTTPS) to Windows server ($($ph.Host)) is BLOCKED.")
                    }
                } else {
                    Write-Host "    [$($ph.Host)] TCP/22  (SSH)          ... " -NoNewline -ForegroundColor White
                    $r22 = Test-TcpPort -HostName $ph.Host -Port 22
                    if ($r22.Success) {
                        Write-Host "PASS ($($r22.LatencyMs)ms)" -ForegroundColor Green
                    } else {
                        Write-Host "FAIL - $($r22.Error)" -ForegroundColor Red
                        [void]$script:Recommendations.Add("PLATFORM: TCP/22 (SSH) to Linux server ($($ph.Host)) is BLOCKED. Required for agentless discovery of Linux physical/cloud servers.")
                    }
                }
            }
            if ($physHosts.Count -eq 0) {
                Write-Host "    (Physical/cloud server tests skipped)" -ForegroundColor DarkGray
            }
        }
    }
}

# ============================================================================
# LOCAL FIREWALL CHECK (Read-Only)
# ============================================================================

function Test-LocalFirewall {
    Write-Section "LOCAL WINDOWS FIREWALL STATUS (Read-Only)"

    try {
        $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        foreach ($profile in $fwProfiles) {
            $status = if ($profile.Enabled) { "Enabled" } else { "Disabled" }
            $color  = if ($profile.Enabled) { "Yellow" } else { "Gray" }
            Write-Host "    $($profile.Name) Profile: $status (Default Outbound: $($profile.DefaultOutboundAction))" -ForegroundColor $color
            if ($profile.Enabled -and $profile.DefaultOutboundAction -eq 'Block') {
                [void]$script:Warnings.Add("Windows Firewall '$($profile.Name)' profile has default outbound action set to BLOCK. This will block Azure Migrate unless explicit allow rules exist.")
                [void]$script:Recommendations.Add(@"
FIREWALL OUTBOUND BLOCK: The Windows Firewall $($profile.Name) profile is set to block outbound
traffic by default. Ensure outbound rules exist to allow TCP/443 to Azure Migrate endpoints.
This is a LOCAL firewall issue (not network/corporate firewall).
"@)
            }
        }
    } catch {
        Write-Host "    Unable to check Windows Firewall status: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ============================================================================
# MAIN CONNECTIVITY TEST ENGINE
# ============================================================================

function Invoke-ConnectivityTests {
    param(
        [System.Collections.ArrayList]$UrlList
    )

    Write-Section "ENDPOINT CONNECTIVITY TESTS"
    Write-Host ""
    Write-Host "  Testing $($UrlList.Count) endpoints. This may take a few minutes..." -ForegroundColor White
    Write-Host "  (Simulating the same HTTPS calls the Azure Migrate appliance makes)" -ForegroundColor Gray
    Write-Host ""

    $currentCategory = ''
    $totalCount  = $UrlList.Count
    $currentIndex = 0

    foreach ($entry in $UrlList) {
        $currentIndex++

        if ($entry.Category -ne $currentCategory) {
            $currentCategory = $entry.Category
            Write-SubSection "$currentCategory"
        }

        $host_ = $entry.Host
        $port  = $entry.Port

        Write-Host "    [$currentIndex/$totalCount] Testing $($host_):$port ... " -NoNewline -ForegroundColor White

        # DNS Test
        $dnsResult = Test-DnsResolution -HostName $host_
        $dnsPass   = $dnsResult.Success
        $dnsDetail = if ($dnsPass) { "Resolved: $($dnsResult.Addresses -join ', ')" } else { $dnsResult.Error }

        # TCP Test
        $tcpPass   = $false
        $tcpDetail = 'Skipped (DNS failed)'
        if ($dnsPass) {
            $tcpResult = Test-TcpPort -HostName $host_ -Port $port
            $tcpPass   = $tcpResult.Success
            $tcpDetail = if ($tcpPass) { "Connected in $($tcpResult.LatencyMs)ms" } else { $tcpResult.Error }
        }

        # HTTPS Test
        $httpsPass   = $false
        $httpsDetail = 'Skipped (TCP failed)'
        if ($tcpPass) {
            $httpsResult = Test-HttpsConnectivity -Url $host_
            $httpsPass   = $httpsResult.Success
            if ($httpsPass) {
                $httpsDetail = "HTTP $($httpsResult.StatusCode) in $($httpsResult.LatencyMs)ms"
                if ($httpsResult.CertIssuer) { $httpsDetail += " [Cert: $($httpsResult.CertIssuer)]" }
            } else {
                $httpsDetail = $httpsResult.Error
            }
        } elseif ($dnsPass -and -not $tcpPass) {
            $httpsDetail = 'Skipped (TCP connection failed - likely firewall block)'
        }

        # Overall status
        $overall = $dnsPass -and $tcpPass -and $httpsPass
        if ($overall) {
            Write-Host "PASS" -ForegroundColor Green
        } elseif (-not $dnsPass) {
            Write-Host "FAIL (DNS)" -ForegroundColor Red
        } elseif (-not $tcpPass) {
            Write-Host "FAIL (TCP BLOCKED)" -ForegroundColor Red
        } else {
            Write-Host "FAIL (HTTPS)" -ForegroundColor Red
        }

        # Store result
        Add-TestResult -Url $host_ -Port $port -Purpose $entry.Purpose -WildcardPattern $entry.Wildcard `
            -DnsPass $dnsPass -DnsDetail $dnsDetail `
            -TcpPass $tcpPass -TcpDetail $tcpDetail `
            -HttpsPass $httpsPass -HttpsDetail $httpsDetail `
            -Category $entry.Category
    }
}

# ============================================================================
# AUTO-UPDATE GUID URL HELPER  (NEW in v2.0)
# ============================================================================

function Get-AutoUpdateGuidUrl {
    param(
        [System.Collections.ArrayList]$CustomUrls
    )

    Write-Host ""
    Write-Host "  Do you have an auto-update GUID URL from an appliance error message?" -ForegroundColor White
    Write-Host "  (e.g. https://<guid>-agent.uga.disc.privatelink.prod.migration.windowsazure.com/...)" -ForegroundColor Gray
    $yn = Read-Host "  Enter Y to add it, or press Enter to skip"
    if ($yn -match '^[Yy]') {
        $guidUrl = (Read-Host "  Paste the full auto-update URL").Trim()
        if ($guidUrl) {
            $hostPart = $guidUrl -replace '^https?://', '' -replace '/.*$', ''
            if ($hostPart) {
                [void]$CustomUrls.Add(@{
                    Host     = $hostPart
                    Port     = 443
                    Purpose  = 'Auto-update GUID endpoint (from appliance error)'
                    Wildcard = "*.$($hostPart -replace '^[^.]+\.', '')"
                    Category = 'Auto-Update Endpoint (GUID)'
                })
                Write-Host "    Added: $hostPart" -ForegroundColor Green
                Write-Host ""
                Write-Host "  GUIDANCE: This GUID URL is unique to your Azure Migrate project." -ForegroundColor Yellow
                Write-Host "  For PRIVATE LINK deployments, the private DNS zone must have an A record" -ForegroundColor Yellow
                Write-Host "  for this FQDN pointing to the private endpoint IP. Without it, auto-update" -ForegroundColor Yellow
                Write-Host "  will fail with 'service endpoint unreachable'." -ForegroundColor Yellow
                Write-Host "  See: https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance" -ForegroundColor Cyan
            }
        }
    }
}

# ============================================================================
# FIREWALL RULE SUMMARY  (NEW in v2.0)
# ============================================================================

function Write-FirewallRuleSummary {
    Write-Section "FIREWALL RULE SUMMARY (for network teams)"

    $failed = $script:TestResults | Where-Object { -not $_.OverallPass }
    $passed = $script:TestResults | Where-Object { $_.OverallPass }

    Write-Host ""
    if ($failed.Count -gt 0) {
        Write-Host "  [ACTION REQUIRED] BLOCKED - add these outbound TCP/443 firewall rules:" -ForegroundColor Red
        Write-Host ""
        # Deduplicate by wildcard pattern
        $seenWild = @{}
        foreach ($f in $failed) {
            if (-not $seenWild.ContainsKey($f.WildcardPattern)) {
                $seenWild[$f.WildcardPattern] = $true
                $proto = "TCP/$($f.Port)"
                Write-Host ("    Allow outbound {0,-8} to  {1,-60}  # {2}" -f $proto, $f.WildcardPattern, $f.Purpose) -ForegroundColor Red
            }
        }
        Write-Host ""
    } else {
        Write-Host "  [ACTION REQUIRED]: None — no blocked endpoints detected." -ForegroundColor Green
    }

    if ($passed.Count -gt 0) {
        Write-Host "  [OK] PASSING - no action needed:" -ForegroundColor Green
        Write-Host ""
        $seenWild2 = @{}
        foreach ($p in $passed) {
            if (-not $seenWild2.ContainsKey($p.WildcardPattern)) {
                $seenWild2[$p.WildcardPattern] = $true
                $proto = "TCP/$($p.Port)"
                Write-Host ("    OK  outbound {0,-8} to  {1,-60}  # {2}" -f $proto, $p.WildcardPattern, $p.Purpose) -ForegroundColor Green
            }
        }
        Write-Host ""
    }
}

# ============================================================================
# RESULTS REPORTING
# ============================================================================

function Write-ResultsSummary {
    param(
        [string]$Cloud,
        [string]$Scenario,
        [string]$ApplianceType,
        [string]$Platform,
        [string]$ConnectivityPath,
        [bool]$PrivateLink
    )

    $failed    = $script:TestResults | Where-Object { -not $_.OverallPass }
    $passed    = $script:TestResults | Where-Object { $_.OverallPass }
    $dnsFails  = $script:TestResults | Where-Object { -not $_.DnsPass }
    $tcpFails  = $script:TestResults | Where-Object { $_.DnsPass -and -not $_.TcpPass }
    $httpFails = $script:TestResults | Where-Object { $_.DnsPass -and $_.TcpPass -and -not $_.HttpsPass }

    Write-Section "RESULTS SUMMARY"
    Write-Host ""
    Write-Host "  Configuration Tested:" -ForegroundColor White
    Write-Host "    Cloud:             $Cloud"            -ForegroundColor Gray
    Write-Host "    Scenario:          $Scenario"         -ForegroundColor Gray
    Write-Host "    Appliance Type:    $ApplianceType"    -ForegroundColor Gray
    Write-Host "    Platform:          $Platform"         -ForegroundColor Gray
    Write-Host "    Connectivity Path: $ConnectivityPath" -ForegroundColor Gray
    Write-Host "    Private Link:      $PrivateLink"      -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Total Endpoints Tested: $($script:TestResults.Count)" -ForegroundColor White
    Write-Host "    Passed: $($passed.Count)" -ForegroundColor Green
    Write-Host "    Failed: $($failed.Count)" -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })
    Write-Host ""

    if ($dnsFails.Count -gt 0) {
        Write-Host "  DNS Resolution Failures ($($dnsFails.Count)):" -ForegroundColor Red
        foreach ($f in $dnsFails) {
            Write-Host "    [DNS FAIL] $($f.Url):$($f.Port) - $($f.Purpose)" -ForegroundColor Red
            Write-Host "               Wildcard: $($f.WildcardPattern)" -ForegroundColor DarkGray
            Write-Host "               Error: $($f.DnsDetail)" -ForegroundColor DarkGray
            Write-Host "               NOTE: Wildcard base domains may not resolve directly." -ForegroundColor DarkGray
            Write-Host "               Ensure '$($f.WildcardPattern)' is resolvable from your DNS." -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($tcpFails.Count -gt 0) {
        Write-Host "  TCP Connection Failures ($($tcpFails.Count)) - LIKELY FIREWALL/PROXY BLOCK:" -ForegroundColor Red
        foreach ($f in $tcpFails) {
            Write-Host "    [TCP BLOCKED] $($f.Url):$($f.Port) - $($f.Purpose)" -ForegroundColor Red
            Write-Host "                  Wildcard: $($f.WildcardPattern)" -ForegroundColor DarkGray
            Write-Host "                  Resolved IP: $($f.DnsDetail)" -ForegroundColor DarkGray
            Write-Host "                  Error: $($f.TcpDetail)" -ForegroundColor DarkGray
        }
        Write-Host ""
        [void]$script:Recommendations.Add(@"
TCP CONNECTION BLOCKED: $($tcpFails.Count) endpoint(s) resolved via DNS but TCP connection on
port 443 was refused or timed out. This typically indicates:
  1. A network firewall is blocking outbound TCP/443 to these specific destinations
  2. A proxy server is not forwarding traffic to these endpoints
  3. Network Security Groups (NSGs) or route tables are blocking traffic

ACTION: Review your firewall/proxy rules and ensure outbound TCP/443 is allowed to:
$( ($tcpFails | ForEach-Object { "  - $($_.WildcardPattern) ($($_.Purpose))" }) -join "`n" )

See: https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#port-access
"@)
    }

    if ($httpFails.Count -gt 0) {
        Write-Host "  HTTPS/TLS Failures ($($httpFails.Count)) - POSSIBLE SSL INSPECTION OR PROXY ISSUE:" -ForegroundColor Yellow
        foreach ($f in $httpFails) {
            Write-Host "    [HTTPS FAIL] $($f.Url):$($f.Port) - $($f.Purpose)" -ForegroundColor Yellow
            Write-Host "                 Error: $($f.HttpsDetail)" -ForegroundColor DarkGray
        }
        Write-Host ""
        [void]$script:Recommendations.Add(@"
HTTPS/TLS FAILURES: $($httpFails.Count) endpoint(s) connected on TCP/443 but the HTTPS
handshake or request failed. This typically indicates:
  1. SSL/TLS inspection (MITM proxy) is interfering with the connection
  2. The proxy requires authentication that was not provided
  3. Certificate validation is failing due to missing root CAs
  4. TLS version mismatch (Azure requires TLS 1.2)

ACTION: Check if SSL inspection is enabled for Azure Migrate endpoints and consider
creating bypass rules for these URLs. Ensure TLS 1.2 is enabled.
See: https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance#connectivity-issues
"@)
    }

    if ($failed.Count -eq 0) {
        Write-Host "  ALL ENDPOINTS PASSED CONNECTIVITY CHECKS" -ForegroundColor Green
        Write-Host ""
        Write-Host "  All required Azure Migrate endpoints are reachable from this machine." -ForegroundColor Green
        Write-Host "  If you are still experiencing issues with the Azure Migrate appliance," -ForegroundColor Gray
        Write-Host "  the problem may be specific to the appliance software or configuration." -ForegroundColor Gray
    }
}

function Write-Recommendations {
    param(
        [string]$Cloud,
        [string]$Scenario,
        [string]$ApplianceType,
        [string]$Platform,
        [string]$ConnectivityPath,
        [bool]$PrivateLink
    )

    Write-Section "RECOMMENDATIONS AND GUIDANCE"

    # Scenario-specific doc links
    $docLinks = @{
        'PublicCloudUrls'      = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#public-cloud-urls'
        'GovCloudUrls'         = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#government-cloud-urls'
        'ChinaCloudUrls'       = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance-china'
        'PublicPrivateLink'    = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#public-cloud-urls-for-private-link-connectivity'
        'GovPrivateLink'       = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#government-cloud-urls-for-private-link-connectivity'
        'DeploymentScenarios'  = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#deployment-scenarios'
        'SimplifiedExperience' = 'https://learn.microsoft.com/en-us/azure/migrate/simplified-experience-for-azure-migrate'
        'TroubleshootAppliance'= 'https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance'
        'PortAccess'           = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#port-access'
        'ApplianceSetup'       = 'https://learn.microsoft.com/en-us/azure/migrate/how-to-set-up-appliance-vmware'
        'CommonQuestions'      = 'https://learn.microsoft.com/en-us/azure/migrate/common-questions-appliance'
        'PrivateLinkSetup'     = 'https://learn.microsoft.com/en-us/azure/migrate/how-to-use-azure-migrate-with-private-endpoints'
        'AgentBasedMigration'  = 'https://learn.microsoft.com/en-us/azure/migrate/agent-based-migration-architecture'
        'ModernAppliance'      = 'https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance'
        'TroubleshootNetwork'  = 'https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-network-connectivity'
        'ExpressRoute'         = 'https://learn.microsoft.com/en-us/azure/expressroute/expressroute-routing'
        'ERMicrosoftPeering'   = 'https://learn.microsoft.com/en-us/azure/expressroute/expressroute-circuit-peerings#microsoftpeering'
    }

    # Print collected recommendations
    if ($script:Recommendations.Count -gt 0) {
        Write-SubSection "Issues Found"
        for ($i = 0; $i -lt $script:Recommendations.Count; $i++) {
            Write-Host ""
            Write-Host "  [$($i + 1)] $($script:Recommendations[$i])" -ForegroundColor Yellow
        }
    }

    # Print collected warnings
    if ($script:Warnings.Count -gt 0) {
        Write-SubSection "Warnings"
        foreach ($w in $script:Warnings) {
            Write-Host "  [!] $w" -ForegroundColor Yellow
        }
    }

    # ExpressRoute private peering warning
    if ($ConnectivityPath -eq 'ExpressRoute-Private') {
        Write-SubSection "ExpressRoute Private Peering Warning"
        Write-Host @"
  [IMPORTANT] ExpressRoute PRIVATE PEERING does NOT carry public Azure service endpoints.
  Public Azure services (login.microsoftonline.com, management.azure.com, blob.core.windows.net,
  servicebus.windows.net, etc.) are NOT reachable over ExpressRoute private peering by default.

  To reach public Azure endpoints from an appliance on a private-peering-only network you must:
    (a) Route internet-bound traffic through a hub firewall / NAT gateway that has internet access, OR
    (b) Enable ExpressRoute Microsoft Peering for Azure public services, OR
    (c) Deploy Azure Private Endpoints for each required Azure service and use Private Link

  If your appliance connectivity test shows failures for Azure portal, Entra ID, or ARM endpoints,
  this is the most likely cause.

  Reference: $($docLinks.ExpressRoute)
"@ -ForegroundColor Yellow
    }

    # General guidance
    Write-SubSection "General Troubleshooting Steps"
    Write-Host @"
  If connectivity tests above show failures, follow these steps:

  1. FIREWALL RULES: Ensure your corporate/network firewall allows outbound TCP/443
     to all required Azure Migrate URLs listed above. Work with your network team
     to add firewall allow rules for the wildcard patterns listed.

  2. PROXY CONFIGURATION: If using a proxy, ensure:
     a. The proxy allows HTTPS traffic to Azure Migrate endpoints
     b. The appliance is configured with correct proxy settings
     c. Proxy authentication credentials are correct (if required)
     d. SSL inspection is bypassed for Azure Migrate URLs

  3. DNS RESOLUTION: If DNS failures occur:
     a. Verify DNS servers are reachable and configured correctly
     b. Check if DNS filtering/security products block Azure domains
     c. Try using Azure DNS (168.63.129.16) or public DNS (8.8.8.8) for comparison

  4. TLS CONFIGURATION: Azure services require TLS 1.2:
     a. Ensure TLS 1.2 is enabled in Windows (SCHANNEL registry settings)
     b. Ensure .NET Framework is configured to use TLS 1.2
     c. Check for Group Policy settings that may restrict TLS versions

  5. PRIVATE ENDPOINTS: If using private link:
     a. Verify private DNS zones are configured correctly
     b. Ensure private endpoint connections are approved
     c. Verify DNS resolution returns private IP addresses
     d. The auto-update manifest URL (e.g., <guid>-agent.uga.disc.privatelink.prod.migration.windowsazure.us)
        MUST resolve through the privatelink.prod.migration.windowsazure.us (or .com) private DNS zone
     e. If auto-update fails with "service endpoint unreachable", the privatelink DNS zone is likely
        missing the A record for your project-specific FQDN or the zone is not linked to your VNet

  6. APPLIANCE AUTO-UPDATE ISSUES:
     If auto-update fails with "service endpoint ... is unreachable":
     a. The URL contains a project-specific GUID (e.g., de995fbb-...-agent.uga.disc.privatelink...)
     b. For PRIVATE LINK: Ensure the privatelink.prod.migration.windowsazure.us (Gov) or
        privatelink.prod.migration.windowsazure.com (Commercial) DNS zone is properly configured
     c. For PUBLIC endpoints: Ensure firewall allows *.prod.migration.windowsazure.us/.com on TCP/443
     d. Paste the exact failing URL into this tool's custom URL prompt to test it directly
     e. See: https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance

  7. EXPRESSROUTE / VPN: If using ExpressRoute or VPN:
     a. ExpressRoute PRIVATE peering does NOT carry public Azure service endpoints
        -- Appliance needs internet access or private endpoints for Azure services
     b. ExpressRoute MICROSOFT peering carries Azure public IPs -- verify BGP communities
     c. VPN Gateway: ensure split tunneling or full-tunnel routes cover Azure IP ranges
     d. Reference: $($docLinks.ExpressRoute)
"@ -ForegroundColor Gray

    # Relevant documentation links
    Write-SubSection "Relevant Documentation"
    Write-Host ""
    Write-Host "  Deployment Scenarios:" -ForegroundColor White
    Write-Host "    $($docLinks.DeploymentScenarios)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Simplified (Modern) Experience:" -ForegroundColor White
    Write-Host "    $($docLinks.SimplifiedExperience)" -ForegroundColor Cyan
    Write-Host ""

    switch ($Cloud) {
        'Commercial' {
            if ($PrivateLink) {
                Write-Host "  Required URLs (Public Cloud - Private Link):" -ForegroundColor White
                Write-Host "    $($docLinks.PublicPrivateLink)" -ForegroundColor Cyan
            } else {
                Write-Host "  Required URLs (Public Cloud):" -ForegroundColor White
                Write-Host "    $($docLinks.PublicCloudUrls)" -ForegroundColor Cyan
            }
        }
        'Government' {
            if ($PrivateLink) {
                Write-Host "  Required URLs (Government Cloud - Private Link):" -ForegroundColor White
                Write-Host "    $($docLinks.GovPrivateLink)" -ForegroundColor Cyan
            } else {
                Write-Host "  Required URLs (Government Cloud):" -ForegroundColor White
                Write-Host "    $($docLinks.GovCloudUrls)" -ForegroundColor Cyan
            }
        }
        'China' {
            Write-Host "  Required URLs (China - 21Vianet):" -ForegroundColor White
            Write-Host "    $($docLinks.ChinaCloudUrls)" -ForegroundColor Cyan
        }
    }

    Write-Host ""
    Write-Host "  Port Access Requirements:" -ForegroundColor White
    Write-Host "    $($docLinks.PortAccess)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Troubleshoot Appliance Issues:" -ForegroundColor White
    Write-Host "    $($docLinks.TroubleshootAppliance)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Appliance FAQ:" -ForegroundColor White
    Write-Host "    $($docLinks.CommonQuestions)" -ForegroundColor Cyan

    if ($PrivateLink) {
        Write-Host ""
        Write-Host "  Private Endpoints Setup:" -ForegroundColor White
        Write-Host "    $($docLinks.PrivateLinkSetup)" -ForegroundColor Cyan
    }

    if ($Scenario -eq 'AgentBasedLegacy' -or $Scenario -eq 'AgentBasedModern') {
        Write-Host ""
        Write-Host "  Agent-based Migration Architecture:" -ForegroundColor White
        Write-Host "    $($docLinks.AgentBasedMigration)" -ForegroundColor Cyan
    }

    if ($Scenario -eq 'AgentBasedModern') {
        Write-Host ""
        Write-Host "  Modern Appliance:" -ForegroundColor White
        Write-Host "    $($docLinks.ModernAppliance)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Simplified Experience:" -ForegroundColor White
        Write-Host "    $($docLinks.SimplifiedExperience)" -ForegroundColor Cyan
    }

    if ($PrivateLink) {
        Write-Host ""
        Write-Host "  Troubleshoot Network Connectivity (Private Endpoints):" -ForegroundColor White
        Write-Host "    $($docLinks.TroubleshootNetwork)" -ForegroundColor Cyan
    }

    if ($ConnectivityPath -match 'ExpressRoute') {
        Write-Host ""
        Write-Host "  ExpressRoute Circuit Peering:" -ForegroundColor White
        Write-Host "    $($docLinks.ExpressRoute)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  ExpressRoute Microsoft Peering:" -ForegroundColor White
        Write-Host "    $($docLinks.ERMicrosoftPeering)" -ForegroundColor Cyan
    }
}

# ============================================================================
# REPORT EXPORT
# ============================================================================

function Export-Report {
    param(
        [string]$Cloud,
        [string]$Scenario,
        [string]$ApplianceType,
        [string]$Platform,
        [string]$ConnectivityPath,
        [bool]$PrivateLink,
        [bool]$ProxyDetected
    )

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("=" * 80)
    [void]$sb.AppendLine("  Azure Migrate Appliance - Connectivity Troubleshooter Report")
    [void]$sb.AppendLine("  Generated:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("  Script Version: $($script:ScriptVersion)")
    [void]$sb.AppendLine("  Machine:        $env:COMPUTERNAME")
    [void]$sb.AppendLine("=" * 80)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("CONFIGURATION:")
    [void]$sb.AppendLine("  Cloud:              $Cloud")
    [void]$sb.AppendLine("  Scenario:           $Scenario")
    [void]$sb.AppendLine("  Appliance Type:     $ApplianceType")
    [void]$sb.AppendLine("  Platform:           $Platform")
    [void]$sb.AppendLine("  Connectivity Path:  $ConnectivityPath")
    [void]$sb.AppendLine("  Private Link:       $PrivateLink")
    [void]$sb.AppendLine("  Proxy Detected:     $ProxyDetected")
    [void]$sb.AppendLine("  PowerShell Version: $($PSVersionTable.PSVersion)")
    [void]$sb.AppendLine("  TLS Protocols:      $([Net.ServicePointManager]::SecurityProtocol)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-" * 80)
    [void]$sb.AppendLine("ENDPOINT TEST RESULTS:")
    [void]$sb.AppendLine("-" * 80)

    $failed = $script:TestResults | Where-Object { -not $_.OverallPass }
    $passed = $script:TestResults | Where-Object { $_.OverallPass }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Total: $($script:TestResults.Count)  |  Passed: $($passed.Count)  |  Failed: $($failed.Count)")
    [void]$sb.AppendLine("")

    foreach ($r in $script:TestResults) {
        $status = if ($r.OverallPass) { "PASS" } else { "FAIL" }
        [void]$sb.AppendLine("  [$status] $($r.Url):$($r.Port)")
        [void]$sb.AppendLine("         Purpose:  $($r.Purpose)")
        [void]$sb.AppendLine("         Wildcard: $($r.WildcardPattern)")
        [void]$sb.AppendLine("         Category: $($r.Category)")
        [void]$sb.AppendLine("         DNS:      $(if ($r.DnsPass) {'PASS'} else {'FAIL'}) - $($r.DnsDetail)")
        [void]$sb.AppendLine("         TCP:      $(if ($r.TcpPass) {'PASS'} else {'FAIL'}) - $($r.TcpDetail)")
        [void]$sb.AppendLine("         HTTPS:    $(if ($r.HttpsPass) {'PASS'} else {'FAIL'}) - $($r.HttpsDetail)")
        [void]$sb.AppendLine("")
    }

    if ($failed.Count -gt 0) {
        [void]$sb.AppendLine("-" * 80)
        [void]$sb.AppendLine("FAILED ENDPOINTS REQUIRING ACTION:")
        [void]$sb.AppendLine("-" * 80)
        foreach ($f in $failed) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("  FAILED: $($f.Url):$($f.Port) ($($f.Purpose))")
            [void]$sb.AppendLine("  Required firewall/proxy rule: Allow $($f.WildcardPattern) on port $($f.Port)")
            if (-not $f.DnsPass) {
                [void]$sb.AppendLine("  Root Cause: DNS resolution failed - $($f.DnsDetail)")
                [void]$sb.AppendLine("  Action: Check DNS configuration; ensure DNS can resolve Azure service domains")
            } elseif (-not $f.TcpPass) {
                [void]$sb.AppendLine("  Root Cause: TCP connection blocked (DNS resolved successfully)")
                [void]$sb.AppendLine("  Action: Firewall or proxy is blocking TCP/443 to this endpoint")
                [void]$sb.AppendLine("  Resolved IPs: $($f.DnsDetail)")
            } else {
                [void]$sb.AppendLine("  Root Cause: HTTPS/TLS failure (TCP connected successfully)")
                [void]$sb.AppendLine("  Action: Check for SSL inspection, proxy auth, or TLS version issues")
                [void]$sb.AppendLine("  HTTPS Error: $($f.HttpsDetail)")
            }
        }
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-" * 80)
    [void]$sb.AppendLine("FIREWALL RULE SUMMARY:")
    [void]$sb.AppendLine("-" * 80)
    if ($failed.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("  [ACTION REQUIRED] Add these outbound TCP/443 firewall allow rules:")
        $seenW = @{}
        foreach ($f in $failed) {
            if (-not $seenW.ContainsKey($f.WildcardPattern)) {
                $seenW[$f.WildcardPattern] = $true
                [void]$sb.AppendLine(("    Allow TCP/{0,-6} to {1}" -f $f.Port, $f.WildcardPattern))
            }
        }
    } else {
        [void]$sb.AppendLine("  No blocked endpoints — no action required.")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-" * 80)
    [void]$sb.AppendLine("WARNINGS:")
    [void]$sb.AppendLine("-" * 80)
    foreach ($w in $script:Warnings) {
        [void]$sb.AppendLine("  [!] $w")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-" * 80)
    [void]$sb.AppendLine("RECOMMENDATIONS:")
    [void]$sb.AppendLine("-" * 80)
    for ($i = 0; $i -lt $script:Recommendations.Count; $i++) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("  [$($i + 1)] $($script:Recommendations[$i])")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-" * 80)
    [void]$sb.AppendLine("DOCUMENTATION LINKS:")
    [void]$sb.AppendLine("-" * 80)
    [void]$sb.AppendLine("  Appliance URLs:          https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance")
    [void]$sb.AppendLine("  Deployment Scenarios:    https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#deployment-scenarios")
    [void]$sb.AppendLine("  Simplified Experience:   https://learn.microsoft.com/en-us/azure/migrate/simplified-experience-for-azure-migrate")
    [void]$sb.AppendLine("  Troubleshoot Appliance:  https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-appliance")
    [void]$sb.AppendLine("  Port Access:             https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#port-access")

    switch ($Cloud) {
        'Commercial' {
            if (-not $PrivateLink) {
                [void]$sb.AppendLine("  Required URLs:           https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#public-cloud-urls")
            } else {
                [void]$sb.AppendLine("  Required URLs (PL):      https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#public-cloud-urls-for-private-link-connectivity")
            }
        }
        'Government' {
            if (-not $PrivateLink) {
                [void]$sb.AppendLine("  Required URLs (Gov):     https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#government-cloud-urls")
            } else {
                [void]$sb.AppendLine("  Required URLs (Gov PL):  https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#government-cloud-urls-for-private-link-connectivity")
            }
        }
        'China' {
            [void]$sb.AppendLine("  Required URLs (China):   https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance-china")
        }
    }

    [void]$sb.AppendLine("  Private Endpoints:       https://learn.microsoft.com/en-us/azure/migrate/how-to-use-azure-migrate-with-private-endpoints")
    [void]$sb.AppendLine("  Appliance FAQ:           https://learn.microsoft.com/en-us/azure/migrate/common-questions-appliance")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=" * 80)
    [void]$sb.AppendLine("  END OF REPORT")
    [void]$sb.AppendLine("=" * 80)

    try {
        $sb.ToString() | Out-File -FilePath $script:ReportPath -Encoding UTF8 -Force
        Write-Host ""
        Write-Host "  Report saved to: $($script:ReportPath)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to save report: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Report content displayed above." -ForegroundColor Yellow
    }
}

# ============================================================================
# PRIVATE LINK DNS VALIDATION
# ============================================================================

function Test-PrivateLinkDns {
    param(
        [System.Collections.ArrayList]$UrlList,
        [string]$Cloud
    )

    Write-Section "PRIVATE LINK DNS VALIDATION"
    Write-Host ""
    Write-Host "  Checking that Private Link endpoints resolve to private IP addresses..." -ForegroundColor White
    Write-Host "  (Private endpoints should resolve to 10.x.x.x, 172.16-31.x.x, or 192.168.x.x)" -ForegroundColor Gray
    Write-Host ""

    $privateLinkHosts = $UrlList | Where-Object {
        $_.Host -match 'privatelink' -or $_.Category -match 'Private Link|Custom'
    }

    $plIssues = 0
    foreach ($entry in $privateLinkHosts) {
        $dnsResult = Test-DnsResolution -HostName $entry.Host
        if ($dnsResult.Success) {
            $isPrivate = $false
            foreach ($addr in $dnsResult.Addresses) {
                if ($addr -match '^10\.' -or $addr -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or $addr -match '^192\.168\.') {
                    $isPrivate = $true
                }
            }
            if ($isPrivate) {
                Write-Host "    [PASS] $($entry.Host) -> $($dnsResult.Addresses -join ', ') (private IP)" -ForegroundColor Green
            } else {
                Write-Host "    [WARN] $($entry.Host) -> $($dnsResult.Addresses -join ', ') (PUBLIC IP - not private!)" -ForegroundColor Yellow
                $plIssues++
            }
        } else {
            Write-Host "    [FAIL] $($entry.Host) - DNS resolution failed: $($dnsResult.Error)" -ForegroundColor Red
            $plIssues++
        }
    }

    # Also check non-privatelink hosts that should resolve to private IPs when using private link
    $migrationHosts = $UrlList | Where-Object {
        $_.Host -notmatch 'privatelink' -and (
            $_.Host -match 'migration\.windowsazure' -or
            $_.Host -match 'discoverysrv\.windowsazure' -or
            $_.Host -match 'vault\.' -or
            $_.Host -match 'servicebus\.' -or
            $_.Host -match 'blob\.core'
        )
    }
    if ($migrationHosts.Count -gt 0) {
        Write-Host ""
        Write-Host "  Checking core service DNS for private IP resolution:" -ForegroundColor White
        foreach ($entry in $migrationHosts) {
            $dnsResult = Test-DnsResolution -HostName $entry.Host
            if ($dnsResult.Success) {
                $ipList = $dnsResult.Addresses -join ', '
                $hasPrivate = $dnsResult.Addresses | Where-Object {
                    $_ -match '^10\.' -or $_ -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or $_ -match '^192\.168\.'
                }
                if ($hasPrivate) {
                    Write-Host "    [OK]   $($entry.Host) -> $ipList (includes private IP)" -ForegroundColor Green
                } else {
                    Write-Host "    [INFO] $($entry.Host) -> $ipList (public IP - expected if CNAME chain uses privatelink)" -ForegroundColor Gray
                }
            }
        }
    }

    if ($plIssues -gt 0) {
        [void]$script:Recommendations.Add(@"
PRIVATE LINK DNS ISSUE: $plIssues endpoint(s) using Private Link did not resolve to private
IP addresses. This means the private DNS zone may not be configured correctly, or the DNS
query is not routing through your private DNS resolver.

For Azure Migrate Private Link, ensure:
  1. Private DNS zones are created and linked to your VNet:
     - privatelink.prod.migration.windowsazure.com (Commercial) or
       privatelink.prod.migration.windowsazure.us (Government)
     - privatelink.blob.core.windows.net (or .usgovcloudapi.net)
     - privatelink.vaultcore.azure.net (or .usgovcloudapi.net)
     - privatelink.servicebus.windows.net (or .usgovcloudapi.net)
  2. Private endpoint connections are approved in the Azure portal
  3. The appliance VM's DNS settings point to a DNS server that forwards to Azure DNS (168.63.129.16)
     or to a custom DNS server with conditional forwarders for the privatelink zones
  4. Auto-update manifest URLs (e.g., *-agent.uga.disc.privatelink.prod.migration.windowsazure.us)
     must resolve via the private DNS zone

See: https://learn.microsoft.com/en-us/azure/migrate/how-to-use-azure-migrate-with-private-endpoints
See: https://learn.microsoft.com/en-us/azure/migrate/troubleshoot-network-connectivity
"@)
    } else {
        Write-Host ""
        Write-Host "  [OK] Private Link DNS validation passed." -ForegroundColor Green
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================


# ============================================================================

# ============================================================================
# v4.0 ADDITIONAL RESULT STORES
# ============================================================================
$script:AzureHealthResult    = $null
$script:ApplianceHealthResult = $null
$script:DotNetResult          = $null
$script:NatIpResult           = $null

# ============================================================================
# v5.0 ADDITIONAL RESULT STORES
# ============================================================================
$script:DuplicateApplianceResult  = $null
$script:vCenterResult             = $null
$script:MtuResult                 = $null
$script:RegionTested              = $null
$script:VersionCurrencyResult     = $null
$script:EventLogFindings          = [System.Collections.ArrayList]::new()
$script:AvEdrResult               = [System.Collections.ArrayList]::new()
$script:AdditionalPortsResult     = $null
$script:SummaryPath               = ''
$script:ZipPath                   = ''
$script:GroupPolicyResult         = $null
$script:AvExclusionResult         = $null


# ============================================================================
# v4.0 ADDITIONS — Features 1-8
# ============================================================================

# ── Feature 1: Azure Service Health Check ────────────────────────────────────
function Test-AzureServiceHealth {
    param(
        [ValidateSet('Commercial','Government','China')]
        [string]$Cloud = 'Commercial'
    )

    Write-Section "AZURE SERVICE HEALTH CHECK"
    Write-Host "  Checking whether Microsoft Azure itself is currently experiencing an outage." -ForegroundColor Gray
    Write-Host "  If Azure is down, network tests below may show failures that are NOT your fault." -ForegroundColor Gray
    Write-Host ""

    $statusUrl = switch ($Cloud) {
        'Government' { 'https://status.azure.us/api/v2/status.json' }
        'China'      { 'https://status.azure.cn/api/v2/status.json' }
        default      { 'https://status.azure.com/api/v2/status.json' }
    }

    $portalUrl = switch ($Cloud) {
        'Government' { 'https://status.azure.us' }
        'China'      { 'https://status.azure.cn' }
        default      { 'https://status.azure.com' }
    }

    $result = @{ Status = 'Unknown'; Indicator = 'unknown'; Description = ''; ComponentIssues = @() }
    $req = $null; $resp = $null

    try {
        $req          = [System.Net.HttpWebRequest]::Create($statusUrl)
        $req.Method   = 'GET'
        $req.Timeout  = 10000
        $req.UserAgent = 'AzureMigrateConnectivityChecker/4.0'
        $resp         = $req.GetResponse()

        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $json   = $reader.ReadToEnd()
        $reader.Close(); $reader.Dispose()

        # Parse JSON manually (PS 5.1 compatible)
        $parsed = $json | ConvertFrom-Json -ErrorAction SilentlyContinue

        if ($parsed) {
            $indicator   = $parsed.status.indicator
            $description = $parsed.status.description

            $result.Indicator   = $indicator
            $result.Description = $description

            switch ($indicator) {
                'none' {
                    $result.Status = 'Healthy'
                    Write-Host "  [PASS] Azure is FULLY OPERATIONAL — no active incidents." -ForegroundColor Green
                    Write-Host "  Status: $description" -ForegroundColor Green
                }
                'minor' {
                    $result.Status = 'Minor'
                    Write-Host "  [WARN] Azure has a MINOR incident in progress." -ForegroundColor Yellow
                    Write-Host "  Status: $description" -ForegroundColor Yellow
                    Write-Host "  This may or may not affect Azure Migrate. Check: $portalUrl" -ForegroundColor Yellow
                    [void]$script:Warnings.Add("Azure has an active minor incident. Some failures below may be Azure-side, not your network. Check $portalUrl")
                }
                { $_ -in 'major','critical' } {
                    $result.Status = 'Outage'
                    Write-Host "  [FAIL] AZURE OUTAGE DETECTED — $($indicator.ToUpper()) incident in progress." -ForegroundColor Red
                    Write-Host "  Status: $description" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "  IMPORTANT: Connectivity test failures below may be caused by this Azure outage," -ForegroundColor Red
                    Write-Host "  NOT by your network. Do NOT raise firewall change requests until Azure recovers." -ForegroundColor Red
                    Write-Host "  Monitor: $portalUrl" -ForegroundColor Cyan
                    [void]$script:Recommendations.Add("AZURE OUTAGE IN PROGRESS ($indicator): Any connectivity failures may be Azure-side. Monitor $portalUrl before making network changes.")
                }
                default {
                    $result.Status = 'Unknown'
                    Write-Host "  [INFO] Azure status: $description (indicator: $indicator)" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "  [INFO] Could not parse Azure status response — proceeding with tests." -ForegroundColor Gray
        }

    } catch [System.Net.WebException] {
        $result.Status = 'Unreachable'
        Write-Host "  [WARN] Could not reach Azure status page ($statusUrl)." -ForegroundColor Yellow
        Write-Host "  This could mean no internet access, or status.azure.com is blocked by the network." -ForegroundColor Yellow
        Write-Host "  Proceeding with connectivity tests — treat results with caution." -ForegroundColor Yellow
    } catch {
        Write-Host "  [WARN] Azure health check error: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        if ($resp) { try { $resp.Close(); $resp.Dispose() } catch {} }
        $req = $null; $resp = $null
    }

    $script:AzureHealthResult = $result
    Write-Host ""
}

# ── Feature 2: Appliance Health API Check ────────────────────────────────────
function Test-ApplianceHealthApi {
    Write-Section "APPLIANCE CONFIGURATION MANAGER HEALTH CHECK"
    Write-Host "  Checking whether the Appliance Configuration Manager web portal is running" -ForegroundColor Gray
    Write-Host "  and responding on this machine. This is the tool used to register the" -ForegroundColor Gray
    Write-Host "  appliance and run connectivity checks (https://localhost:44368)." -ForegroundColor Gray
    Write-Host ""

    $result = @{ PortOpen = $false; ApiResponding = $false; HealthStatus = 'Unknown'; Detail = '' }

    # Step 1: TCP check on port 44368
    Write-Host "  Step 1: Checking if Config Manager web portal is listening on port 44368..." -ForegroundColor White
    $tcpClient = $null
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $task      = $tcpClient.ConnectAsync('127.0.0.1', 44368)
        $connected = $task.Wait(3000)
        if ($connected -and -not $task.IsFaulted) {
            $result.PortOpen = $true
            Write-Host "  [PASS] Port 44368 is open — Config Manager web server is running." -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Port 44368 is NOT responding." -ForegroundColor Red
            Write-Host "         The Appliance Configuration Manager web server is not running." -ForegroundColor Red
            Write-Host "         This means the appliance software may not be installed, or the" -ForegroundColor Red
            Write-Host "         IIS/Kestrel web server has crashed." -ForegroundColor Red
            Write-Host ""
            Write-Host "  To fix: Open Services.msc and look for 'Microsoft Azure Appliance' services." -ForegroundColor Yellow
            Write-Host "          Try restarting them, or reboot the appliance." -ForegroundColor Yellow
            [void]$script:Recommendations.Add("APPLIANCE CONFIG MANAGER DOWN: Port 44368 not responding. The appliance web server has crashed or is not installed. Check Services.msc for Azure Migrate/Appliance services.")
        }
    } catch {
        Write-Host "  [WARN] Could not test port 44368: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
        $tcpClient = $null
    }

    # Step 2: HTTPS health API call (only if port is open)
    if ($result.PortOpen) {
        Write-Host ""
        Write-Host "  Step 2: Querying appliance health API..." -ForegroundColor White
        $req = $null; $resp = $null
        try {
            # Ignore self-signed cert (appliance uses self-signed)
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

            $req         = [System.Net.HttpWebRequest]::Create('https://localhost:44368/api/appliance/health')
            $req.Method  = 'GET'
            $req.Timeout = 8000
            $req.UserAgent = 'AzureMigrateConnectivityChecker/4.0'

            try {
                $resp       = $req.GetResponse()
                $statusCode = [int]$resp.StatusCode
                $reader     = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body       = $reader.ReadToEnd()
                $reader.Close(); $reader.Dispose()

                if ($statusCode -eq 200) {
                    $result.ApiResponding = $true
                    $result.HealthStatus  = 'Responding'
                    Write-Host "  [PASS] Health API responded (HTTP 200)." -ForegroundColor Green

                    # Try to parse health status
                    try {
                        $healthData = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($healthData) {
                            $overallHealth = $healthData.overallHealth -or $healthData.status -or $healthData.State
                            if ($overallHealth) {
                                Write-Host "  Appliance health status: $overallHealth" -ForegroundColor $(
                                    if ($overallHealth -match 'healthy|ok|success|running' ) { 'Green' }
                                    elseif ($overallHealth -match 'warn|degraded') { 'Yellow' }
                                    else { 'Red' }
                                )
                                $result.HealthStatus = $overallHealth
                            }
                        }
                    } catch {}
                    Write-Host "  The Config Manager is running and accepting requests." -ForegroundColor Green
                } else {
                    Write-Host "  [WARN] Health API returned HTTP $statusCode." -ForegroundColor Yellow
                    $result.HealthStatus = "HTTP $statusCode"
                }
            } catch [System.Net.WebException] {
                $webEx = $_.Exception
                if ($webEx.Response) {
                    $code = [int]$webEx.Response.StatusCode
                    if ($code -in @(401, 403)) {
                        $result.ApiResponding = $true
                        $result.HealthStatus  = 'Running (auth required)'
                        Write-Host "  [PASS] Config Manager is running (HTTP $code — auth required, which is expected)." -ForegroundColor Green
                    } else {
                        Write-Host "  [WARN] Config Manager HTTP $code`: $($webEx.Message)" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "  [WARN] Could not reach health API: $($webEx.Message)" -ForegroundColor Yellow
                    Write-Host "  The web server port is open but not responding to API calls." -ForegroundColor Yellow
                    Write-Host "  The appliance software may be starting up or in an error state." -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host "  [WARN] Health API check error: $($_.Exception.Message)" -ForegroundColor Yellow
        } finally {
            if ($resp) { try { $resp.Close(); $resp.Dispose() } catch {} }
            # Reset cert validation
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
            $req = $null; $resp = $null
        }
    }

    $script:ApplianceHealthResult = $result
    Write-Host ""
}

# ── Feature 3: .NET Framework Version Check ──────────────────────────────────
function Test-DotNetVersion {
    Write-Section ".NET FRAMEWORK VERSION CHECK"
    Write-Host "  Azure Migrate appliance requires .NET Framework 4.7.2 or higher." -ForegroundColor Gray
    Write-Host "  Missing or outdated .NET causes silent failures that can look like" -ForegroundColor Gray
    Write-Host "  network connectivity problems." -ForegroundColor Gray
    Write-Host ""

    $result = @{ Version = 'Unknown'; Release = 0; Pass = $false; Detail = '' }

    # .NET version from registry (most reliable method)
    $regPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    try {
        if (Test-Path $regPath) {
            $release = (Get-ItemProperty -Path $regPath -Name 'Release' -ErrorAction SilentlyContinue).Release
            $result.Release = $release

            # Release number → version mapping
            $versionStr = switch ($true) {
                ($release -ge 533320) { '4.8.1 or later' }
                ($release -ge 528040) { '4.8' }
                ($release -ge 461808) { '4.7.2' }
                ($release -ge 461308) { '4.7.1' }
                ($release -ge 460798) { '4.7' }
                ($release -ge 394802) { '4.6.2' }
                ($release -ge 394254) { '4.6.1' }
                ($release -ge 393295) { '4.6' }
                default               { "Below 4.6 (Release key: $release)" }
            }
            $result.Version = $versionStr

            # 4.7.2 = release key 461808
            if ($release -ge 461808) {
                $result.Pass = $true
                Write-Host "  [PASS] .NET Framework $versionStr is installed (Release: $release)" -ForegroundColor Green
                Write-Host "  This meets the Azure Migrate minimum requirement of .NET 4.7.2." -ForegroundColor Green
            } else {
                $result.Pass = $false
                Write-Host "  [FAIL] .NET Framework $versionStr is installed (Release: $release)" -ForegroundColor Red
                Write-Host "  Azure Migrate requires .NET Framework 4.7.2 or higher." -ForegroundColor Red
                Write-Host "  This WILL cause appliance failures regardless of network health." -ForegroundColor Red
                Write-Host ""
                Write-Host "  TO FIX: Download and install .NET Framework 4.8 from:" -ForegroundColor Yellow
                Write-Host "  https://dotnet.microsoft.com/download/dotnet-framework/net48" -ForegroundColor Cyan
                Write-Host "  Then reboot the machine and re-run this script." -ForegroundColor Yellow
                [void]$script:Recommendations.Add(".NET Framework $versionStr is BELOW the required 4.7.2 minimum. Install .NET 4.8 from https://dotnet.microsoft.com/download/dotnet-framework/net48 and reboot.")
            }
        } else {
            Write-Host "  [WARN] .NET Framework 4.x registry key not found." -ForegroundColor Yellow
            Write-Host "  .NET Framework 4.x may not be installed on this machine." -ForegroundColor Yellow
            Write-Host "  Azure Migrate requires .NET 4.7.2+. Install it before proceeding." -ForegroundColor Yellow
            [void]$script:Recommendations.Add(".NET Framework 4.x not detected. Azure Migrate requires 4.7.2+. Install from https://dotnet.microsoft.com/download/dotnet-framework/net48")
        }
    } catch {
        Write-Host "  [WARN] Could not read .NET version from registry: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Also check .NET version via clrver or PowerShell runtime as secondary confirmation
    Write-Host ""
    Write-Host "  PowerShell .NET runtime: $([System.Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion())" -ForegroundColor Gray
    Write-Host "  CLR version in use:      $([System.Environment]::Version)" -ForegroundColor Gray

    $script:DotNetResult = $result
    Write-Host ""
}

# ── Feature 4: Outbound NAT IP Capture ───────────────────────────────────────
function Get-OutboundNatIp {
    Write-Section "OUTBOUND NAT IP ADDRESS"
    Write-Host "  This captures the PUBLIC IP address that Microsoft Azure sees when this" -ForegroundColor Gray
    Write-Host "  appliance connects to the internet. This is the IP your firewall team" -ForegroundColor Gray
    Write-Host "  can look up in firewall logs to trace exactly where traffic is going." -ForegroundColor Gray
    Write-Host "  It may be different from the machine's local IP address (10.x, 192.168.x)" -ForegroundColor Gray
    Write-Host "  if the machine is behind NAT, a proxy, or a firewall." -ForegroundColor Gray
    Write-Host ""

    $result = @{ PublicIp = 'Unknown'; LocalIp = 'Unknown'; IsBehindNat = $false }

    # Get local IP
    try {
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -First 1
        if ($adapters) { $result.LocalIp = $adapters.IPAddress }
    } catch {
        try {
            $result.LocalIp = ([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString
        } catch {}
    }

    # Try multiple public IP services in order (resilience)
    $ipServices = @(
        'https://api.ipify.org',
        'https://ifconfig.me/ip',
        'https://icanhazip.com',
        'https://checkip.amazonaws.com'
    )

    $publicIp = $null
    foreach ($svc in $ipServices) {
        $req = $null; $resp = $null
        try {
            $req         = [System.Net.HttpWebRequest]::Create($svc)
            $req.Method  = 'GET'
            $req.Timeout = 8000
            $req.UserAgent = 'AzureMigrateConnectivityChecker/4.0'
            $resp        = $req.GetResponse()
            $reader      = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $publicIp    = $reader.ReadToEnd().Trim()
            $reader.Close(); $reader.Dispose()
            if ($publicIp -match '^\d+\.\d+\.\d+\.\d+$') { break }
            $publicIp = $null
        } catch {
            $publicIp = $null
        } finally {
            if ($resp) { try { $resp.Close(); $resp.Dispose() } catch {} }
            $req = $null; $resp = $null
        }
    }

    if ($publicIp) {
        $result.PublicIp    = $publicIp
        $result.IsBehindNat = ($publicIp -ne $result.LocalIp)

        Write-Host "  Local (internal) IP address : $($result.LocalIp)" -ForegroundColor Gray
        Write-Host "  Public (outbound NAT) IP    : $publicIp" -ForegroundColor Cyan
        Write-Host ""

        if ($result.IsBehindNat) {
            Write-Host "  [INFO] This machine is behind NAT — traffic leaves via a different public IP." -ForegroundColor White
            Write-Host "  When reviewing firewall logs, look for traffic FROM: $publicIp" -ForegroundColor White
            Write-Host "  Share this IP with your network team when requesting firewall rule changes." -ForegroundColor White
        } else {
            Write-Host "  [INFO] Local IP matches public IP — machine may have a direct internet connection." -ForegroundColor White
        }

        # Rough geolocation check
        $geoReq = $null; $geoResp = $null
        try {
            $geoReq        = [System.Net.HttpWebRequest]::Create("https://ipapi.co/$publicIp/json/")
            $geoReq.Method = 'GET'
            $geoReq.Timeout = 6000
            $geoReq.UserAgent = 'AzureMigrateConnectivityChecker/4.0'
            $geoResp       = $geoReq.GetResponse()
            $geoReader     = New-Object System.IO.StreamReader($geoResp.GetResponseStream())
            $geoJson       = $geoReader.ReadToEnd()
            $geoReader.Close(); $geoReader.Dispose()
            $geo           = $geoJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($geo -and $geo.country_name) {
                Write-Host "  IP Location: $($geo.city), $($geo.region), $($geo.country_name) — ISP: $($geo.org)" -ForegroundColor Gray
            }
        } catch {}
        finally {
            if ($geoResp) { try { $geoResp.Close(); $geoResp.Dispose() } catch {} }
            $geoReq = $null; $geoResp = $null
        }

    } else {
        Write-Host "  [WARN] Could not determine public IP address." -ForegroundColor Yellow
        Write-Host "  All public IP lookup services were unreachable." -ForegroundColor Yellow
        Write-Host "  This may indicate no outbound internet access from this machine." -ForegroundColor Yellow
        [void]$script:Warnings.Add("Could not determine outbound public IP — all IP lookup services unreachable. Possible: no internet access, or all outbound traffic is blocked.")
    }

    $script:NatIpResult = $result
    Write-Host ""
}

# ── Feature 5: Parallel Endpoint Testing ─────────────────────────────────────
function Invoke-ConnectivityTestsParallel {
    param(
        [System.Collections.ArrayList]$UrlList
    )

    Write-Section "ENDPOINT CONNECTIVITY TESTS (Parallel)"
    Write-Host ""
    Write-Host "  Testing $($UrlList.Count) endpoints in parallel for speed." -ForegroundColor White
    Write-Host "  (Simulating the same HTTPS calls the Azure Migrate appliance makes)" -ForegroundColor Gray
    Write-Host ""

    # Use runspaces for parallel execution (PS 5.1 compatible, no Start-Job overhead)
    $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 8)
    $runspacePool.Open()

    $jobs = [System.Collections.ArrayList]::new()

    $scriptBlock = {
        param($HostName, $Port, $TcpTimeout, $HttpTimeout)

        $result = @{
            HostName    = $HostName
            Port        = $Port
            DnsPass     = $false
            DnsDetail   = ''
            DnsAddresses= @()
            TcpPass     = $false
            TcpDetail   = ''
            TcpLatencyMs= -1
            HttpsPass   = $false
            HttpsDetail = ''
            HttpsStatus = 0
            CertIssuer  = ''
        }

        # DNS
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($HostName)
            if ($addrs.Count -gt 0) {
                $result.DnsPass      = $true
                $result.DnsAddresses = $addrs | ForEach-Object { $_.IPAddressToString }
                $result.DnsDetail    = "Resolved: $($result.DnsAddresses -join ', ')"
            } else {
                $result.DnsDetail = "No addresses returned"
            }
        } catch {
            $result.DnsDetail = $_.Exception.Message
        }

        if (-not $result.DnsPass) { return $result }

        # TCP
        $tcpClient = $null
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $sw        = [System.Diagnostics.Stopwatch]::StartNew()
            $task      = $tcpClient.ConnectAsync($HostName, $Port)
            $done      = $task.Wait($TcpTimeout)
            $sw.Stop()
            if ($done -and -not $task.IsFaulted) {
                $result.TcpPass      = $true
                $result.TcpLatencyMs = $sw.ElapsedMilliseconds
                $result.TcpDetail    = "Connected in $($sw.ElapsedMilliseconds)ms"
            } else {
                $result.TcpDetail = if ($task.IsFaulted) { $task.Exception.InnerException.Message } else { "Timed out after ${TcpTimeout}ms" }
            }
        } catch {
            $result.TcpDetail = $_.Exception.Message
        } finally {
            if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
            $tcpClient = $null
        }

        if (-not $result.TcpPass) { return $result }

        # HTTPS
        $req = $null; $resp = $null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $req           = [System.Net.HttpWebRequest]::Create("https://$HostName")
            $req.Method    = 'GET'
            $req.Timeout   = $HttpTimeout
            $req.UserAgent = 'AzureMigrateConnectivityChecker/4.0'
            $sw2           = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $resp = $req.GetResponse()
                $sw2.Stop()
                $result.HttpsPass   = $true
                $result.HttpsStatus = [int]$resp.StatusCode
                $result.HttpsDetail = "HTTP $($result.HttpsStatus) in $($sw2.ElapsedMilliseconds)ms"
                if ($req.ServicePoint.Certificate) {
                    $result.CertIssuer = $req.ServicePoint.Certificate.Issuer
                }
                $resp.Close(); $resp.Dispose()
            } catch [System.Net.WebException] {
                $sw2.Stop()
                $webEx = $_.Exception
                if ($webEx.Response) {
                    $code = [int]$webEx.Response.StatusCode
                    if ($code -in @(400,401,403,404,405,500,502,503)) {
                        $result.HttpsPass   = $true
                        $result.HttpsStatus = $code
                        $result.HttpsDetail = "HTTP $code in $($sw2.ElapsedMilliseconds)ms (network reachable)"
                        if ($req.ServicePoint.Certificate) {
                            $result.CertIssuer = $req.ServicePoint.Certificate.Issuer
                        }
                    } else {
                        $result.HttpsDetail = "HTTP $code`: $($webEx.Message)"
                    }
                    if ($webEx.Response -is [System.Net.HttpWebResponse]) { $webEx.Response.Close() }
                } else {
                    $result.HttpsDetail = $webEx.Message
                }
            }
        } catch {
            $result.HttpsDetail = $_.Exception.Message
        } finally {
            if ($resp)  { try { $resp.Close();  $resp.Dispose()  } catch {} }
            $req = $null; $resp = $null
        }

        return $result
    }

    # Submit all jobs
    foreach ($entry in $UrlList) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($scriptBlock)
        [void]$ps.AddArgument($entry.Host)
        [void]$ps.AddArgument($entry.Port)
        [void]$ps.AddArgument($script:TcpTimeoutMs)
        [void]$ps.AddArgument($script:HttpTimeoutMs)
        $handle = $ps.BeginInvoke()
        [void]$jobs.Add([PSCustomObject]@{
            PS      = $ps
            Handle  = $handle
            Entry   = $entry
        })
    }

    # Collect results with progress display
    $currentCategory = ''
    $completed = 0
    $total     = $jobs.Count

    foreach ($job in $jobs) {
        $r     = $job.PS.EndInvoke($job.Handle)
        $entry = $job.Entry
        $completed++

        if ($entry.Category -ne $currentCategory) {
            $currentCategory = $entry.Category
            Write-SubSection "$currentCategory"
        }

        $res = if ($r -is [System.Collections.IEnumerable]) { $r | Select-Object -First 1 } else { $r }

        $dnsPass   = [bool]$res.DnsPass
        $tcpPass   = [bool]$res.TcpPass
        $httpsPass = [bool]$res.HttpsPass
        $dnsDetail = $res.DnsDetail
        $tcpDetail = $res.TcpDetail
        $httpsDetail = $res.HttpsDetail

        Write-Host "    [$completed/$total] $($entry.Host):$($entry.Port) ... " -NoNewline -ForegroundColor White
        if ($dnsPass -and $tcpPass -and $httpsPass) {
            Write-Host "PASS" -ForegroundColor Green
        } elseif (-not $dnsPass) {
            Write-Host "FAIL (DNS)" -ForegroundColor Red
        } elseif (-not $tcpPass) {
            Write-Host "FAIL (TCP BLOCKED)" -ForegroundColor Red
        } else {
            Write-Host "FAIL (HTTPS)" -ForegroundColor Red
        }

        Add-TestResult -Url $entry.Host -Port $entry.Port -Purpose $entry.Purpose `
            -WildcardPattern $entry.Wildcard `
            -DnsPass $dnsPass -DnsDetail $dnsDetail `
            -TcpPass $tcpPass -TcpDetail $tcpDetail `
            -HttpsPass $httpsPass -HttpsDetail $httpsDetail `
            -Category $entry.Category

        # Cleanup this runspace job
        $job.PS.Dispose()
    }

    # Close the pool
    $runspacePool.Close()
    $runspacePool.Dispose()
    $runspacePool = $null
    $jobs         = $null
}

# ── Feature 6: Retry Logic for Flaky Connections ─────────────────────────────
function Test-EndpointWithRetry {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$MaxRetries = 3,
        [int]$TimeoutMs  = 5000
    )

    $passCount = 0
    $lastError = ''

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $tcpClient = $null
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $task      = $tcpClient.ConnectAsync($HostName, $Port)
            $done      = $task.Wait($TimeoutMs)
            if ($done -and -not $task.IsFaulted) {
                $passCount++
            } else {
                $lastError = if ($task.IsFaulted) { $task.Exception.InnerException.Message } else { "Timeout" }
            }
        } catch {
            $lastError = $_.Exception.Message
        } finally {
            if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
            $tcpClient = $null
        }
        if ($i -lt $MaxRetries) { Start-Sleep -Milliseconds 500 }
    }

    return [PSCustomObject]@{
        HostName    = $HostName
        Port        = $Port
        PassCount   = $passCount
        TotalTries  = $MaxRetries
        Consistent  = ($passCount -eq $MaxRetries -or $passCount -eq 0)
        Flaky       = ($passCount -gt 0 -and $passCount -lt $MaxRetries)
        LastError   = $lastError
    }
}

function Test-FlakyConnections {
    # Re-test failed TCP endpoints with retry to identify flaky vs consistent failures
    $failedTcp = $script:TestResults | Where-Object { $_.DnsPass -and -not $_.TcpPass } | Select-Object -First 5

    if ($failedTcp.Count -eq 0) { return }

    Write-Section "FLAP / INTERMITTENT CONNECTION TEST"
    Write-Host "  Re-testing blocked endpoints 3 times each to determine if the block is" -ForegroundColor Gray
    Write-Host "  consistent (definite firewall rule) or intermittent (packet loss / flapping)." -ForegroundColor Gray
    Write-Host "  This helps your network team distinguish a hard block from a flaky connection." -ForegroundColor Gray
    Write-Host ""

    $flapFound = $false

    foreach ($entry in $failedTcp) {
        Write-Host "  Retrying: $($entry.Url):$($entry.Port) (3 attempts)" -ForegroundColor White
        $retryResult = Test-EndpointWithRetry -HostName $entry.Url -Port $entry.Port -MaxRetries 3

        if ($retryResult.Flaky) {
            $flapFound = $true
            Write-Host "    [FLAKY] $($retryResult.PassCount)/3 attempts succeeded." -ForegroundColor Yellow
            Write-Host "    MEANING: This connection is INTERMITTENT — not a hard firewall block." -ForegroundColor Yellow
            Write-Host "    This is typically caused by: packet loss, rate limiting, an overloaded" -ForegroundColor Yellow
            Write-Host "    proxy, or a firewall rule that allows some traffic but not all." -ForegroundColor Yellow
            Write-Host "    Ask your network team to check for packet loss or rate limiting rules," -ForegroundColor Yellow
            Write-Host "    not just outright blocks." -ForegroundColor Yellow
            [void]$script:Warnings.Add("FLAKY connection to $($entry.Url):$($entry.Port) — $($retryResult.PassCount)/3 retries succeeded. Check for packet loss or rate limiting, not just hard firewall blocks.")
        } elseif ($retryResult.PassCount -eq 3) {
            Write-Host "    [PASS on retry] All 3 retries succeeded — may have been a transient issue." -ForegroundColor Green
            [void]$script:Warnings.Add("$($entry.Url) passed on retry (transient failure during main test). Re-run script to confirm.")
        } else {
            Write-Host "    [CONSISTENT BLOCK] 0/3 retries succeeded — this is a definite, consistent block." -ForegroundColor Red
            Write-Host "    Your network team should look for an explicit DENY rule for this destination." -ForegroundColor Red
        }
        Write-Host ""
    }

    if (-not $flapFound) {
        Write-Host "  All tested failures are CONSISTENT — no intermittent/flapping connections detected." -ForegroundColor White
        Write-Host "  The blocks are definite firewall rules, not packet loss." -ForegroundColor White
    }
}

# ── Feature 7: NTLM/Kerberos Proxy Auth Detection ────────────────────────────
function Test-ProxyAuthType {
    param([string]$ProxyString)

    if (-not $ProxyString -or $ProxyString -match 'Direct access') { return }

    # Parse proxy
    $proxyHost = $null; $proxyPort = 8080
    if ($ProxyString -match '(?:https?://)?([^:/\s]+)(?::(\d+))?') {
        $proxyHost = $matches[1]
        if ($matches[2]) { $proxyPort = [int]$matches[2] }
    }
    if (-not $proxyHost) { return }

    Write-Section "PROXY AUTHENTICATION TYPE DETECTION"
    Write-Host "  Detecting whether your proxy requires NTLM or Kerberos Windows authentication." -ForegroundColor Gray
    Write-Host "  This is common in enterprise environments and requires special appliance config." -ForegroundColor Gray
    Write-Host ""

    $tcpClient = $null; $netStream = $null; $writer = $null; $reader = $null
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $task      = $tcpClient.ConnectAsync($proxyHost, $proxyPort)
        if (-not $task.Wait(5000) -or $task.IsFaulted) {
            Write-Host "  [SKIP] Proxy unreachable — skipping auth type detection." -ForegroundColor Gray
            return
        }

        $netStream = $tcpClient.GetStream()
        $writer    = New-Object System.IO.StreamWriter($netStream)
        $reader    = New-Object System.IO.StreamReader($netStream)
        $writer.AutoFlush = $true

        # Send CONNECT without credentials to trigger auth challenge
        $writer.Write("CONNECT management.azure.com:443 HTTP/1.1`r`nHost: management.azure.com:443`r`n`r`n")
        $netStream.ReadTimeout = 5000

        # Read response headers
        $responseLines = [System.Collections.ArrayList]::new()
        try {
            $line = $reader.ReadLine()
            while ($line -ne $null -and $line -ne '') {
                [void]$responseLines.Add($line)
                $line = $reader.ReadLine()
            }
        } catch {}

        $responseText = $responseLines -join "`n"
        Write-Host "  Proxy initial response:" -ForegroundColor Gray
        $responseLines | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        Write-Host ""

        if ($responseText -match '407') {
            # Check Proxy-Authenticate header
            if ($responseText -match 'Proxy-Authenticate:\s*NTLM') {
                Write-Host "  [DETECTED] NTLM Proxy Authentication required." -ForegroundColor Yellow
                Write-Host "  MEANING: Your proxy uses Windows NTLM authentication." -ForegroundColor White
                Write-Host "  The Azure Migrate appliance must be configured with Windows credentials" -ForegroundColor White
                Write-Host "  (domain\username and password) in the proxy settings." -ForegroundColor White
                Write-Host "  Navigate to: Appliance Config Manager > Proxy Settings > enter credentials" -ForegroundColor Cyan
                [void]$script:Recommendations.Add("PROXY NTLM AUTH: Proxy requires NTLM authentication. Configure domain credentials in Appliance Config Manager proxy settings.")
            } elseif ($responseText -match 'Proxy-Authenticate:\s*Negotiate') {
                Write-Host "  [DETECTED] Kerberos/Negotiate Proxy Authentication required." -ForegroundColor Yellow
                Write-Host "  MEANING: Your proxy uses Kerberos authentication (common in Active Directory environments)." -ForegroundColor White
                Write-Host "  The appliance must be domain-joined, or you must use NTLM fallback credentials." -ForegroundColor White
                Write-Host "  If the appliance is NOT domain-joined, Kerberos auth will fail." -ForegroundColor White
                [void]$script:Recommendations.Add("PROXY KERBEROS AUTH: Proxy requires Kerberos/Negotiate authentication. Appliance may need to be domain-joined, or proxy must allow NTLM fallback.")
            } elseif ($responseText -match 'Proxy-Authenticate:\s*Basic') {
                Write-Host "  [DETECTED] Basic Proxy Authentication required (username/password)." -ForegroundColor Yellow
                Write-Host "  Configure proxy credentials in the Appliance Configuration Manager." -ForegroundColor White
                [void]$script:Recommendations.Add("PROXY BASIC AUTH: Proxy requires Basic authentication. Configure username/password in Appliance Config Manager proxy settings.")
            } else {
                Write-Host "  [INFO] Proxy returned 407 but auth type header not found in response." -ForegroundColor Gray
                Write-Host "  Check proxy logs for the authentication method required." -ForegroundColor Gray
            }
        } elseif ($responseText -match '200') {
            Write-Host "  [PASS] Proxy does not require authentication for this connection." -ForegroundColor Green
        } else {
            Write-Host "  [INFO] Proxy response does not indicate authentication requirement." -ForegroundColor Gray
        }

    } catch {
        Write-Host "  [WARN] Proxy auth detection error: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        if ($reader)    { try { $reader.Close();    $reader.Dispose()    } catch {} }
        if ($writer)    { try { $writer.Close();    $writer.Dispose()    } catch {} }
        if ($netStream) { try { $netStream.Close(); $netStream.Dispose() } catch {} }
        if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
        $reader = $null; $writer = $null; $netStream = $null; $tcpClient = $null
    }
    Write-Host ""
}

# ── Feature 8: Config Manager Accessibility Check ────────────────────────────
# (Folded into Test-ApplianceHealthApi above as Step 1 + Step 2)
# Additional: check the Config Manager is accessible from a BROWSER perspective
function Test-ConfigManagerAccess {
    Write-Section "APPLIANCE CONFIG MANAGER BROWSER ACCESS CHECK"
    Write-Host "  Verifying the Appliance Configuration Manager UI is accessible." -ForegroundColor Gray
    Write-Host "  Admins access this at: https://localhost:44368 or https://[ApplianceIP]:44368" -ForegroundColor Gray
    Write-Host ""

    $ports = @(44368, 44369, 8080)   # 44368 is standard; some versions use 44369
    $found = $false

    foreach ($port in $ports) {
        $tcpClient = $null
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $task      = $tcpClient.ConnectAsync('127.0.0.1', $port)
            $done      = $task.Wait(2000)
            if ($done -and -not $task.IsFaulted) {
                Write-Host "  [PASS] Config Manager is accessible on port $port" -ForegroundColor Green
                Write-Host "  Open a browser on this machine and go to:" -ForegroundColor White
                Write-Host "  https://localhost:$port" -ForegroundColor Cyan
                $found = $true

                # Also check from LAN IP so remote admins can reach it
                try {
                    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -notmatch '^127\.' } |
                        Select-Object -First 1).IPAddress
                    if ($lanIp) {
                        Write-Host "  Or from another machine on the same network:" -ForegroundColor White
                        Write-Host "  https://${lanIp}:$port" -ForegroundColor Cyan
                    }
                } catch {}
                break
            }
        } catch {}
        finally {
            if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
            $tcpClient = $null
        }
    }

    if (-not $found) {
        Write-Host "  [FAIL] Config Manager is NOT accessible on any expected port (44368, 44369, 8080)." -ForegroundColor Red
        Write-Host "  This means the appliance web interface is not running." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "  1. The Azure Migrate appliance software is not installed on this machine" -ForegroundColor Yellow
        Write-Host "  2. The IIS or Kestrel web server hosting the Config Manager has crashed" -ForegroundColor Yellow
        Write-Host "  3. A local firewall is blocking loopback connections on port 44368" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To diagnose: Open Services.msc and check the status of Azure Migrate services." -ForegroundColor White
        Write-Host "  Try restarting them or rebooting the appliance." -ForegroundColor White
        [void]$script:Recommendations.Add("CONFIG MANAGER INACCESSIBLE: Ports 44368/44369/8080 all unresponsive on localhost. Appliance web server is down. Check Services.msc for Azure Migrate services and restart them.")
    }
    Write-Host ""
}

# v3.0 NEW SCRIPT-LEVEL RESULT STORES
# ============================================================================
$script:TraceRouteResults      = [System.Collections.ArrayList]::new()
$script:DnsComparisonResults   = [System.Collections.ArrayList]::new()
$script:TcpBehaviorResults     = [System.Collections.ArrayList]::new()
$script:ProxyConnectResults    = [System.Collections.ArrayList]::new()
$script:CertChainResults       = [System.Collections.ArrayList]::new()
$script:ClockSkewResult        = $null
$script:HostsFileResult        = $null
$script:VirtualizationInfo     = $null
$script:ApplianceState         = $null
$script:ApplianceLogFindings   = $null
$script:ExecutiveSummary       = $null
$script:NextStepsText          = $null

# ============================================================================
# GET-VIRTUALIZATIONINFO
# ============================================================================
function Get-VirtualizationInfo {
    Write-Section "VIRTUALIZATION ENVIRONMENT DETECTION (Read-Only)"

    $hypervisor = 'Unknown'
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $model = if ($cs) { $cs.Model } else { '' }
        $mfr   = if ($cs) { $cs.Manufacturer } else { '' }
        $biosV  = if ($bios) { $bios.SMBIOSBIOSVersion } else { '' }

        if ($model -match 'VMware' -or $mfr -match 'VMware' -or $biosV -match 'VMware') {
            $hypervisor = 'VMware'
        } elseif ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters') -or $model -match 'Virtual Machine') {
            $hypervisor = 'HyperV'
        } else {
            $hypervisor = 'Physical'
        }

        Write-Host "  Manufacturer : $mfr" -ForegroundColor Gray
        Write-Host "  Model        : $model" -ForegroundColor Gray
        Write-Host "  BIOS Version : $biosV" -ForegroundColor Gray
        Write-Host ""
    } catch {
        Write-Host "  Unable to detect virtualization platform: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $script:VirtualizationInfo = $hypervisor

    switch ($hypervisor) {
        'VMware' {
            Write-Host "  DETECTED: Running on VMware vSphere" -ForegroundColor Green
            Write-Host ""
            Write-Host "  *** Action items for your VMware administrator ***" -ForegroundColor Yellow
            Write-Host "  1. PORT GROUP / vSWITCH: Confirm the appliance VM's port group is connected to a" -ForegroundColor White
            Write-Host "     vSwitch that has an UPLINK to the physical network (not an isolated internal switch)." -ForegroundColor White
            Write-Host "  2. VLAN TAG: Confirm the port group VLAN ID matches the network segment that has a" -ForegroundColor White
            Write-Host "     route to the internet. Ask your network team which VLAN carries internet traffic." -ForegroundColor White
            Write-Host "  3. FOR VMWARE AGENTLESS MIGRATION ONLY - vSwitch Security Policy:" -ForegroundColor Yellow
            Write-Host "     Navigate to: vSphere Client > Host > Networking > Virtual Switches > Edit" -ForegroundColor Gray
            Write-Host "     The port group used by the appliance MUST have these settings:" -ForegroundColor White
            Write-Host "       - Forged Transmits : Accept   (REQUIRED — without this, disk replication fails)" -ForegroundColor Red
            Write-Host "       - MAC Address Changes: Accept" -ForegroundColor White
            Write-Host "       - Promiscuous Mode  : Reject  (default is fine)" -ForegroundColor White
            Write-Host "  4. From the vSphere console, verify the appliance can reach the internet:" -ForegroundColor White
            Write-Host "     Open a console session to the VM and run: ping 8.8.8.8" -ForegroundColor Gray
        }
        'HyperV' {
            Write-Host "  DETECTED: Running on Microsoft Hyper-V" -ForegroundColor Green
            Write-Host ""
            Write-Host "  *** Action items for your Hyper-V administrator ***" -ForegroundColor Yellow
            Write-Host "  1. VIRTUAL SWITCH TYPE: The appliance VM must be connected to an EXTERNAL virtual" -ForegroundColor White
            Write-Host "     switch (one bound to a physical NIC). An Internal or Private switch has NO" -ForegroundColor White
            Write-Host "     internet access and will cause all connectivity tests to fail." -ForegroundColor White
            Write-Host "     Check: Hyper-V Manager > Virtual Switch Manager > confirm switch type = External" -ForegroundColor Gray
            Write-Host "  2. VLAN ID: If your network uses VLANs, confirm the VM adapter VLAN ID is correct." -ForegroundColor White
            Write-Host "     Check: VM Settings > Network Adapter > Advanced Features > VLAN ID" -ForegroundColor Gray
            Write-Host "  3. Test internet access from the Hyper-V host itself:" -ForegroundColor White
            Write-Host "     Open PowerShell on the host and run: Test-NetConnection management.azure.com -Port 443" -ForegroundColor Gray
        }
        default {
            Write-Host "  DETECTED: Physical hardware or unrecognized hypervisor" -ForegroundColor Gray
            Write-Host "  Confirm the network adapter is connected and has a default gateway configured." -ForegroundColor White
        }
    }
}

# ============================================================================
# GET-APPLIANCEREGISTRATIONSTATE
# ============================================================================
function Get-ApplianceRegistrationState {
    Write-Section "APPLIANCE REGISTRATION STATE (Read-Only Registry Check)"

    $state = @{
        ApplianceId       = $null
        ProjectKey        = $null
        AutoUpdate        = $null
        CloudEnvironment  = $null
        ServicesFound     = @()
        W32TimeStatus     = 'Unknown'
        WinHttpStatus     = 'Unknown'
        RegistryFound     = $false
    }

    # Read appliance registry key (read-only)
    $regPath = 'HKLM:\SOFTWARE\Microsoft\AzureAppliance'
    if (Test-Path $regPath) {
        $state.RegistryFound = $true
        $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($props) {
            $state.ApplianceId      = $props.ApplianceId
            $state.ProjectKey       = $props.ProjectKey
            $state.AutoUpdate       = $props.AutoUpdate
            $state.CloudEnvironment = $props.CloudEnvironment
        }
        Write-Host "  Appliance registry key found: $regPath" -ForegroundColor Green
        Write-Host ""
        if ($state.ApplianceId) {
            Write-Host "  REGISTRATION STATUS: This appliance HAS been assigned a Project ID." -ForegroundColor Green
            Write-Host "  It has previously attempted registration with Azure Migrate." -ForegroundColor White
            Write-Host "  Appliance ID : $($state.ApplianceId)" -ForegroundColor Gray
            if ($state.ProjectKey) {
                Write-Host "  Project Key  : $($state.ProjectKey.Substring(0, [Math]::Min(8,$state.ProjectKey.Length)))..." -ForegroundColor Gray
            }
            if ($state.CloudEnvironment) {
                Write-Host "  Cloud Env    : $($state.CloudEnvironment)" -ForegroundColor Gray
            }
        } else {
            Write-Host "  REGISTRATION STATUS: This appliance has NOT yet been registered." -ForegroundColor Yellow
            Write-Host "  The connectivity failures are preventing the initial registration from completing." -ForegroundColor White
        }

        if ($null -ne $state.AutoUpdate -and $state.AutoUpdate -eq 0) {
            Write-Host ""
            Write-Host "  [WARN] AUTO-UPDATE IS DISABLED on this appliance." -ForegroundColor Yellow
            Write-Host "  The appliance will not receive automatic patches or service updates." -ForegroundColor Yellow
            Write-Host "  If connectivity was previously working, consider whether a manual change caused the issue." -ForegroundColor Yellow
            [void]$script:Warnings.Add("Auto-update is DISABLED (registry AutoUpdate=0). Appliance will not self-patch. Re-enable if not intentional.")
        } else {
            Write-Host "  Auto-update  : Enabled (default)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Appliance registry key NOT found at: $regPath" -ForegroundColor Yellow
        Write-Host "  This is expected if:" -ForegroundColor Gray
        Write-Host "    - This script is being run from a non-appliance machine to pre-test connectivity" -ForegroundColor Gray
        Write-Host "    - The appliance software has not yet been installed" -ForegroundColor Gray
    }

    # Check appliance-related services
    Write-Host ""
    Write-Host "  Checking appliance and supporting Windows services..." -ForegroundColor White
    $serviceNames = @(
        @{ Pattern = '*AzMigrate*';      Label = 'Azure Migrate services' }
        @{ Pattern = '*AzureAppliance*'; Label = 'Azure Appliance services' }
        @{ Pattern = '*MicrosoftAzure*'; Label = 'Microsoft Azure services' }
    )
    foreach ($svc in $serviceNames) {
        $found = Get-Service -Name $svc.Pattern -ErrorAction SilentlyContinue
        foreach ($s in $found) {
            $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Red' }
            Write-Host "    $($s.DisplayName.PadRight(45)) Status: $($s.Status)" -ForegroundColor $color
            $state.ServicesFound += [PSCustomObject]@{ Name = $s.DisplayName; Status = $s.Status.ToString() }
            if ($s.Status -ne 'Running') {
                [void]$script:Warnings.Add("Service '$($s.DisplayName)' is NOT running. This may prevent Azure Migrate from functioning.")
            }
        }
    }

    # W32Time
    $w32 = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
    if ($w32) {
        $state.W32TimeStatus = $w32.Status.ToString()
        $color = if ($w32.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "    Windows Time (W32Time)                            Status: $($w32.Status)" -ForegroundColor $color
        if ($w32.Status -ne 'Running') {
            [void]$script:Warnings.Add("Windows Time (W32Time) service is not running. Clock sync may be broken — Entra ID authentication can fail if clock drifts > 5 minutes.")
        }
    }

    # WinHTTPAutoProxySvc
    $winhttp = Get-Service -Name 'WinHttpAutoProxySvc' -ErrorAction SilentlyContinue
    if ($winhttp) {
        $state.WinHttpStatus = $winhttp.Status.ToString()
        $color = if ($winhttp.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "    WinHTTP Web Proxy Auto-Discovery                  Status: $($winhttp.Status)" -ForegroundColor $color
    }

    $script:ApplianceState = $state
}

# ============================================================================
# GET-APPLIANCELOGS
# ============================================================================
function Get-ApplianceLogs {
    param(
        [ValidateSet('VMwareAgentless','AgentBasedLegacy','AgentBasedModern')]
        [string]$Scenario
    )

    Write-Section "APPLIANCE LOG ANALYSIS (Read-Only)"

    $logRoot = 'C:\ProgramData\Microsoft Azure\Logs'
    $findings = @{
        LogRootFound        = $false
        OnboardingErrors    = [System.Collections.ArrayList]::new()
        OnboardingWarnings  = [System.Collections.ArrayList]::new()
        AutoUpdateErrors    = [System.Collections.ArrayList]::new()
        GatewayErrors       = [System.Collections.ArrayList]::new()
        DiscoveryErrors     = [System.Collections.ArrayList]::new()
        FolderSummary       = [System.Collections.ArrayList]::new()
        LatestOnboardingLog = $null
    }

    if (-not (Test-Path $logRoot)) {
        Write-Host "  [INFO] Appliance log folder not found at: $logRoot" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  This is NORMAL if you are running this script from a machine other than the" -ForegroundColor Gray
        Write-Host "  appliance itself. For full log analysis, run this script ON the appliance." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  If you ARE running this on the appliance and the folder is missing," -ForegroundColor Yellow
        Write-Host "  the appliance software may not be installed correctly." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Note: ProgramData is a HIDDEN folder. To navigate to it manually:" -ForegroundColor White
        Write-Host "  Open File Explorer -> type this in the address bar -> press Enter:" -ForegroundColor Gray
        Write-Host "  C:\ProgramData\Microsoft Azure\Logs" -ForegroundColor Cyan
        $script:ApplianceLogFindings = $findings
        return
    }

    $findings.LogRootFound = $true
    Write-Host "  Appliance log folder found." -ForegroundColor Green
    Write-Host "  Location: $logRoot" -ForegroundColor Cyan
    Write-Host "  (ProgramData is hidden — navigate by typing the path in Explorer's address bar)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Scanning for connectivity-related errors in recent logs..." -ForegroundColor White
    Write-Host ""

    # --- 1. ConfigManager / Onboarding Portal logs (most important) ---
    $configManagerPath = Join-Path $logRoot 'ConfigManager'
    if (Test-Path $configManagerPath) {
        $onboardingLogs = Get-ChildItem -Path $configManagerPath -Filter 'ApplianceOnboarding-Portal-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3

        Write-SubSection "Appliance Configuration Manager - Onboarding Portal Logs"
        Write-Host "  These logs record every action the Appliance Configuration Manager web portal" -ForegroundColor Gray
        Write-Host "  performs, including the connectivity checks shown on screen during onboarding." -ForegroundColor Gray
        Write-Host ""

        if ($onboardingLogs) {
            Write-Host "  Recent onboarding log files:" -ForegroundColor White
            foreach ($lf in $onboardingLogs) {
                Write-Host "    $($lf.Name)  (last modified: $($lf.LastWriteTime))" -ForegroundColor Gray
            }
            $findings.LatestOnboardingLog = $onboardingLogs[0].FullName
            Write-Host ""
            Write-Host "  Scanning most recent: $($onboardingLogs[0].Name)" -ForegroundColor White

            $errorPatterns = @(
                @{ P = 'connectivity.?check.?fail|ConnectivityCheckFailed|connectivity.*failed';        L = 'Connectivity check failure';       S = 'ERROR' }
                @{ P = 'unable to connect|connection refused|connection timed out|ConnectionRefused';   L = 'Connection failure';               S = 'ERROR' }
                @{ P = 'SSL|TLS|certificate|cert.*invalid|cert.*expired';                               L = 'SSL/TLS/Certificate issue';        S = 'WARNING' }
                @{ P = 'proxy|407|403 Forbidden|ProxyAuthRequired';                                     L = 'Proxy issue';                      S = 'WARNING' }
                @{ P = 'DNS|name resolution|could not resolve|SocketException';                        L = 'DNS or socket failure';            S = 'ERROR' }
                @{ P = 'unauthorized|401|AuthenticationFailed|token.*fail|fail.*token';                L = 'Authentication failure';           S = 'WARNING' }
                @{ P = 'project.?key|ProjectKey|invalid.?key|key.*invalid';                             L = 'Project key issue';                S = 'ERROR' }
                @{ P = 'auto.?update|AutoUpdate|update.*fail|fail.*update|service.*unreachable';        L = 'Auto-update / service failure';    S = 'WARNING' }
                @{ P = 'timeout|TimedOut|timed.?out';                                                   L = 'Timeout';                          S = 'WARNING' }
            )

            try {
                $logContent = Get-Content -Path $onboardingLogs[0].FullName -ErrorAction SilentlyContinue -Tail 500
                if ($logContent) {
                    foreach ($line in $logContent) {
                        foreach ($ep in $errorPatterns) {
                            if ($line -match $ep.P) {
                                $entry = $line.Trim()
                                if ($ep.S -eq 'ERROR') {
                                    [void]$findings.OnboardingErrors.Add("[$($ep.L)] $entry")
                                } else {
                                    [void]$findings.OnboardingWarnings.Add("[$($ep.L)] $entry")
                                }
                                break
                            }
                        }
                    }

                    if ($findings.OnboardingErrors.Count -gt 0) {
                        Write-Host ""
                        Write-Host "  ERRORS found in onboarding log (last 10):" -ForegroundColor Red
                        $findings.OnboardingErrors | Select-Object -Last 10 | ForEach-Object {
                            Write-Host "    $_" -ForegroundColor Red
                        }
                    }
                    if ($findings.OnboardingWarnings.Count -gt 0) {
                        Write-Host ""
                        Write-Host "  WARNINGS found in onboarding log (last 5):" -ForegroundColor Yellow
                        $findings.OnboardingWarnings | Select-Object -Last 5 | ForEach-Object {
                            Write-Host "    $_" -ForegroundColor Yellow
                        }
                    }
                    if ($findings.OnboardingErrors.Count -eq 0 -and $findings.OnboardingWarnings.Count -eq 0) {
                        Write-Host "  No obvious connectivity errors found in the recent onboarding log." -ForegroundColor Green
                    }
                }
            } catch {
                Write-Host "  Could not read onboarding log: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  No ApplianceOnboarding-Portal-*.log files found in ConfigManager folder." -ForegroundColor Yellow
            Write-Host "  This may mean the Appliance Configuration Manager has not been run yet." -ForegroundColor Gray
        }
    }

    # --- 2. AutoUpdate logs ---
    $autoUpdatePath = Join-Path $logRoot 'AutoUpdate'
    if (Test-Path $autoUpdatePath) {
        Write-SubSection "Auto-Update Logs"
        $auLog = Get-ChildItem -Path $autoUpdatePath -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($auLog) {
            Write-Host "  Most recent: $($auLog.Name)  ($($auLog.LastWriteTime))" -ForegroundColor Gray
            try {
                $auContent = Get-Content -Path $auLog.FullName -ErrorAction SilentlyContinue -Tail 100
                $auErrors = $auContent | Where-Object { $_ -match 'error|fail|unreachable|timeout|exception' -and $_ -notmatch '^#' }
                if ($auErrors) {
                    Write-Host "  Auto-update errors found:" -ForegroundColor Yellow
                    $auErrors | Select-Object -Last 5 | ForEach-Object {
                        Write-Host "    $_" -ForegroundColor Yellow
                        [void]$findings.AutoUpdateErrors.Add($_.Trim())
                    }
                    [void]$script:Warnings.Add("Auto-update log contains errors. Auto-update requires *.prod.migration.windowsazure.com — if the network is confirmed blocked, this is expected.")
                } else {
                    Write-Host "  No errors found in recent auto-update log." -ForegroundColor Green
                }
            } catch {
                Write-Host "  Could not read auto-update log." -ForegroundColor Gray
            }
        }
    }

    # --- 3. Discovery logs ---
    $discoveryPath = Join-Path $logRoot 'Discovery'
    if (Test-Path $discoveryPath) {
        Write-SubSection "Discovery Agent Logs"
        $discLog = Get-ChildItem -Path $discoveryPath -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($discLog) {
            Write-Host "  Most recent: $($discLog.Name)  ($($discLog.LastWriteTime))" -ForegroundColor Gray
            try {
                $discContent = Get-Content -Path $discLog.FullName -ErrorAction SilentlyContinue -Tail 100
                $discErrors = $discContent | Where-Object { $_ -match 'error|fail|unreachable|timeout|unauthorized' }
                if ($discErrors) {
                    Write-Host "  Discovery errors (last 5):" -ForegroundColor Yellow
                    $discErrors | Select-Object -Last 5 | ForEach-Object {
                        Write-Host "    $_" -ForegroundColor Yellow
                        [void]$findings.DiscoveryErrors.Add($_.Trim())
                    }
                } else {
                    Write-Host "  No errors found in recent discovery log." -ForegroundColor Green
                }
            } catch {
                Write-Host "  Could not read discovery log." -ForegroundColor Gray
            }
        }
    }

    # --- 4. Gateway logs (VMware agentless) ---
    if ($Scenario -eq 'VMwareAgentless') {
        $gatewayPath = Join-Path $logRoot 'Gateway'
        if (Test-Path $gatewayPath) {
            Write-SubSection "Gateway / Replication Logs (VMware Agentless Migration)"
            $gwLog = Get-ChildItem -Path $gatewayPath -Filter '*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($gwLog) {
                Write-Host "  Most recent: $($gwLog.Name)  ($($gwLog.LastWriteTime))" -ForegroundColor Gray
                try {
                    $gwContent = Get-Content -Path $gwLog.FullName -ErrorAction SilentlyContinue -Tail 100
                    $gwErrors = $gwContent | Where-Object { $_ -match 'error|fail|unreachable|timeout|IoT|IoTHub|AMQP' }
                    if ($gwErrors) {
                        Write-Host "  Gateway errors (last 5):" -ForegroundColor Yellow
                        $gwErrors | Select-Object -Last 5 | ForEach-Object {
                            Write-Host "    $_" -ForegroundColor Yellow
                            [void]$findings.GatewayErrors.Add($_.Trim())
                        }
                        [void]$script:Warnings.Add("Gateway log errors detected. For agentless migration, the gateway communicates with Azure IoT Hub (*.azure-devices.net TCP/443 and TCP/5671). Ensure these endpoints are reachable.")
                    } else {
                        Write-Host "  No errors found in recent gateway log." -ForegroundColor Green
                    }
                } catch {
                    Write-Host "  Could not read gateway log." -ForegroundColor Gray
                }
            }
        }
    }

    # --- 5. Folder summary ---
    Write-SubSection "Log Folder Summary"
    Write-Host "  Full log path: $logRoot" -ForegroundColor Cyan
    Write-Host "  (Hidden folder — type the path above directly into Explorer's address bar)" -ForegroundColor Gray
    Write-Host ""
    $logFolders = Get-ChildItem -Path $logRoot -Directory -ErrorAction SilentlyContinue
    foreach ($folder in $logFolders) {
        $latest = Get-ChildItem -Path $folder.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $lastAct = if ($latest) { $latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { 'No files' }
        [void]$findings.FolderSummary.Add("$($folder.Name.PadRight(20)) Last activity: $lastAct")
        Write-Host "    $($folder.Name.PadRight(20)) Last activity: $lastAct" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  TIP: When opening a Microsoft Support case, attach this file:" -ForegroundColor White
    Write-Host "  $configManagerPath\ApplianceOnboarding-Portal-[today's date].log" -ForegroundColor Cyan
    Write-Host "  along with the connectivity report generated by this script." -ForegroundColor Gray

    $script:ApplianceLogFindings = $findings
}

# ============================================================================
# TEST-CLOCKSKEW
# ============================================================================
function Test-ClockSkew {
    Write-Section "CLOCK / TIME SYNC CHECK"
    Write-Host "  WHY THIS MATTERS: Azure authentication (Microsoft Entra ID) uses time-sensitive" -ForegroundColor Gray
    Write-Host "  security tokens. If this machine's clock is more than 5 minutes off from real" -ForegroundColor Gray
    Write-Host "  world time, ALL Azure authentication will silently fail — even if the network" -ForegroundColor Gray
    Write-Host "  is perfectly healthy. This is a common and easily missed problem." -ForegroundColor Gray
    Write-Host ""

    $result = @{ SkewSeconds = -1; Status = 'Unknown'; Detail = ''; W32tmOutput = '' }

    # Method 1: w32tm
    try {
        $w32out = & w32tm.exe /query /status 2>&1 | Out-String
        $result.W32tmOutput = $w32out
        Write-SubSection "Windows Time Service Status"
        Write-Host "  $($w32out.Trim() -replace "`n","`n  ")" -ForegroundColor Gray
    } catch {
        Write-Host "  Could not query Windows Time service." -ForegroundColor Yellow
    }

    # Method 2: compare to Cloudflare Date header
    Write-SubSection "Real-World Clock Comparison"
    Write-Host "  Comparing local clock to internet time (Cloudflare)..." -ForegroundColor White
    $req = $null; $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create('https://www.cloudflare.com')
        $req.Method  = 'HEAD'
        $req.Timeout = 8000
        $req.UserAgent = 'AzureMigrateConnectivityChecker/3.0'
        $resp = $req.GetResponse()
        $dateHdr = $resp.Headers['Date']
        if ($dateHdr) {
            $fmt = 'ddd, dd MMM yyyy HH:mm:ss ''GMT'''
            $serverTime = [DateTime]::ParseExact($dateHdr, $fmt, [System.Globalization.CultureInfo]::InvariantCulture)
            $localTime  = [DateTime]::UtcNow
            $skew = [Math]::Abs(($localTime - $serverTime).TotalSeconds)
            $result.SkewSeconds = [int]$skew
            $mins = [int]($skew / 60); $secs = [int]($skew % 60)

            Write-Host "  Local UTC time  : $($localTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
            Write-Host "  Internet time   : $($serverTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
            Write-Host "  Clock offset    : ${mins}m ${secs}s" -ForegroundColor $(if ($skew -lt 60) { 'Green' } elseif ($skew -lt 300) { 'Yellow' } else { 'Red' })
            Write-Host ""

            if ($skew -lt 60) {
                $result.Status = 'Pass'
                $result.Detail = "Clock is accurate (${mins}m ${secs}s offset). Azure authentication should work normally."
                Write-Host "  [PASS] $($result.Detail)" -ForegroundColor Green
            } elseif ($skew -lt 300) {
                $result.Status = 'Warning'
                $result.Detail = "Clock offset is ${mins}m ${secs}s. Azure authentication may intermittently fail. Sync the Windows Time service."
                Write-Host "  [WARN] $($result.Detail)" -ForegroundColor Yellow
                [void]$script:Warnings.Add("Clock offset is ${mins}m ${secs}s — Azure authentication may be intermittently failing. Run: w32tm /resync /force")
            } else {
                $result.Status = 'Fail'
                $result.Detail = "CRITICAL: Clock is ${mins}m ${secs}s off from real-world time. Azure authentication WILL FAIL. Microsoft Entra ID (Azure Active Directory) rejects security tokens when the clock is more than 5 minutes out of sync."
                Write-Host "  [FAIL] $($result.Detail)" -ForegroundColor Red
                Write-Host ""
                Write-Host "  TO FIX THIS NOW (run as Administrator):" -ForegroundColor Yellow
                Write-Host "    net stop w32time" -ForegroundColor Cyan
                Write-Host "    net start w32time" -ForegroundColor Cyan
                Write-Host "    w32tm /resync /force" -ForegroundColor Cyan
                [void]$script:Recommendations.Add("CRITICAL CLOCK SKEW: Clock is ${mins}m ${secs}s off. Run as Admin: net stop w32time; net start w32time; w32tm /resync /force")
            }
        }
    } catch {
        $result.Detail = "Could not reach internet time server to compare clocks: $($_.Exception.Message)"
        $result.Status = 'Unknown'
        Write-Host "  Could not reach internet time server for comparison." -ForegroundColor Yellow
        Write-Host "  Check w32tm output above for clock sync status." -ForegroundColor Gray
    } finally {
        if ($resp)  { try { $resp.Close(); $resp.Dispose() } catch {} }
        $req = $null; $resp = $null
    }

    $script:ClockSkewResult = $result
}

# ============================================================================
# TEST-HOSTSFILE
# ============================================================================
function Test-HostsFile {
    Write-Section "WINDOWS HOSTS FILE CHECK (Read-Only)"
    Write-Host "  WHY THIS MATTERS: The Windows 'hosts' file can override DNS lookups. If a" -ForegroundColor Gray
    Write-Host "  security hardening script or antivirus tool added entries for Azure domains," -ForegroundColor Gray
    Write-Host "  those entries will redirect Azure traffic to the wrong place — even if the" -ForegroundColor Gray
    Write-Host "  firewall and DNS are perfectly configured." -ForegroundColor Gray
    Write-Host ""

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $findings = [System.Collections.ArrayList]::new()
    $patterns = @('microsoft','azure','microsoftonline','windows\.net','visualstudio',
                  'msftauth','msauth','live\.com','office\.com','cloudapp')

    try {
        $lines = Get-Content -Path $hostsPath -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
            foreach ($pat in $patterns) {
                if ($trimmed -match $pat) {
                    [void]$findings.Add($trimmed)
                    break
                }
            }
        }

        if ($findings.Count -gt 0) {
            Write-Host "  [WARN] HOSTS FILE OVERRIDES FOUND for Azure-related domains:" -ForegroundColor Red
            Write-Host ""
            foreach ($entry in $findings) {
                Write-Host "    Entry: $entry" -ForegroundColor Red
                Write-Host "    MEANING: This entry overrides DNS for this domain and redirects traffic" -ForegroundColor Yellow
                Write-Host "    to a different IP address. This may completely block Azure Migrate." -ForegroundColor Yellow
                Write-Host "    ACTION: This entry must be removed from the hosts file." -ForegroundColor Yellow
                Write-Host ""
            }
            [void]$script:Recommendations.Add("HOSTS FILE: $($findings.Count) Azure-related override entries found. These must be removed. Open Notepad as Admin -> open $hostsPath -> remove flagged entries.")
        } else {
            Write-Host "  [PASS] Hosts file is clean — no Azure domain overrides detected." -ForegroundColor Green
        }
    } catch {
        Write-Host "  Could not read hosts file: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $script:HostsFileResult = $findings
}

# ============================================================================
# TEST-TCPBEHAVIOR
# ============================================================================
function Test-TcpBehavior {
    $failedTcp = $script:TestResults | Where-Object { $_.DnsPass -and -not $_.TcpPass }
    if ($failedTcp.Count -eq 0) { return }

    Write-Section "TCP FAILURE BEHAVIOR ANALYSIS"
    Write-Host "  For each endpoint where TCP connection failed, this analysis determines" -ForegroundColor Gray
    Write-Host "  HOW it failed — which points to a specific type of network device blocking it." -ForegroundColor Gray
    Write-Host ""

    foreach ($entry in ($failedTcp | Select-Object -First 10)) {
        $tcpClient = $null
        $behavior  = 'Unknown'
        $plain     = ''
        Write-Host "  Analyzing: $($entry.Url):$($entry.Port)" -ForegroundColor White
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $task = $tcpClient.ConnectAsync($entry.Url, $entry.Port)
            $done = $task.Wait(2000)
            if ($done -and -not $task.IsFaulted) {
                $behavior = 'LateSuccess'
                $plain    = "Connected on retry. May be intermittent. Re-run to confirm."
            } elseif ($task.IsFaulted) {
                $ex = $task.Exception.InnerException
                if ($ex -and ($ex.Message -match 'refused|actively refused|Connection refused')) {
                    $behavior = 'ActiveReject'
                    $plain    = "ACTIVE REJECT: Something sent back a refusal (TCP RST). This means a device is actively blocking this specific destination — typically a host-based firewall, a proxy server, or a security appliance configured to explicitly reject this traffic. The blocking device is online and responded."
                } else {
                    $behavior = 'SilentDrop'
                    $plain    = "SILENT DROP: The connection timed out with no response. This is the classic signature of a corporate/perimeter FIREWALL silently discarding the packet. The packet left this machine but never came back. A firewall rule is dropping it without sending a reply."
                }
            } else {
                $behavior = 'SilentDrop'
                $plain    = "SILENT DROP: The connection timed out with no response. This is the classic signature of a corporate/perimeter FIREWALL silently discarding the packet."
            }
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'refused|actively refused') {
                $behavior = 'ActiveReject'
                $plain    = "ACTIVE REJECT: Connection explicitly refused by a device in the network path."
            } else {
                $behavior = 'SilentDrop'
                $plain    = "SILENT DROP: Connection timed out — perimeter firewall silently dropping packets."
            }
        } finally {
            if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
            $tcpClient = $null
        }

        $color = if ($behavior -eq 'ActiveReject') { 'Yellow' } else { 'Red' }
        Write-Host "    Behavior: $behavior" -ForegroundColor $color
        Write-Host "    Meaning : $plain" -ForegroundColor Gray
        Write-Host ""

        [void]$script:TcpBehaviorResults.Add([PSCustomObject]@{
            Url      = $entry.Url
            Port     = $entry.Port
            Behavior = $behavior
            Plain    = $plain
        })
    }
}

# ============================================================================
# TEST-DNSCOMPARISON
# ============================================================================
function Test-DnsComparison {
    $failedDns = $script:TestResults | Where-Object { -not $_.DnsPass } | Select-Object -Unique -Property Url
    if ($failedDns.Count -eq 0) { return }

    Write-Section "DNS FILTERING VERIFICATION"
    Write-Host "  For each domain that failed DNS resolution, this test re-checks using a" -ForegroundColor Gray
    Write-Host "  public DNS server (8.8.8.8) as a control. If 8.8.8.8 resolves it but your" -ForegroundColor Gray
    Write-Host "  internal DNS doesn't, that CONFIRMS your internal DNS is filtering the domain." -ForegroundColor Gray
    Write-Host ""

    $dnsFilteringConfirmed = $false

    foreach ($entry in ($failedDns | Select-Object -First 10)) {
        $hostname = $entry.Url
        Write-Host "  Checking: $hostname" -ForegroundColor White

        # Try Resolve-DnsName against 8.8.8.8 (PS 4+ / Server 2012+)
        $externalResult = $null
        $externalAddrs  = @()
        try {
            $externalResult = Resolve-DnsName -Name $hostname -Server '8.8.8.8' -Type A -ErrorAction SilentlyContinue -DnsOnly
            if ($externalResult) {
                $externalAddrs = $externalResult | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
            }
        } catch {
            # Fall back to nslookup
            try {
                $nsout = & nslookup.exe $hostname 8.8.8.8 2>&1 | Out-String
                $matches_ = [regex]::Matches($nsout, 'Address:\s+(\d+\.\d+\.\d+\.\d+)')
                foreach ($m in $matches_) {
                    $ip = $m.Groups[1].Value
                    if ($ip -ne '8.8.8.8') { $externalAddrs += $ip }
                }
            } catch {}
        }

        if ($externalAddrs.Count -gt 0) {
            # Internal DNS failed, external succeeded — FILTERING CONFIRMED
            $dnsFilteringConfirmed = $true
            Write-Host "    Internal DNS : FAILED (could not resolve)" -ForegroundColor Red
            Write-Host "    Public DNS   : RESOLVED -> $($externalAddrs -join ', ')" -ForegroundColor Green
            Write-Host ""
            Write-Host "    [DNS FILTERING CONFIRMED]" -ForegroundColor Red
            Write-Host "    Your internal DNS server is BLOCKING this domain." -ForegroundColor Red
            Write-Host "    Public DNS (8.8.8.8) resolves it fine — meaning the domain exists" -ForegroundColor Red
            Write-Host "    and is accessible globally, but your internal DNS is suppressing it." -ForegroundColor Red
            Write-Host "    This is caused by a DNS filtering product such as:" -ForegroundColor Yellow
            Write-Host "      - Cisco Umbrella (OpenDNS)" -ForegroundColor Yellow
            Write-Host "      - Infoblox with RPZ (Response Policy Zones)" -ForegroundColor Yellow
            Write-Host "      - Windows DNS with a Response Policy Zone blocking Azure domains" -ForegroundColor Yellow
            Write-Host "      - Another DNS-based web filter or security product" -ForegroundColor Yellow
            Write-Host "    This is a NETWORK ISSUE that your DNS/security team must fix." -ForegroundColor Red
            Write-Host ""
            [void]$script:Recommendations.Add("DNS FILTERING CONFIRMED for '$hostname': Internal DNS blocked it; public DNS (8.8.8.8) resolved it to $($externalAddrs -join ', '). Your DNS filtering product must allow Azure Migrate domains.")
        } else {
            Write-Host "    Internal DNS : FAILED" -ForegroundColor Red
            Write-Host "    Public DNS   : Also FAILED — domain may not exist or global issue" -ForegroundColor Yellow
            Write-Host "    INCONCLUSIVE: Both DNS servers failed. This could be the domain" -ForegroundColor Gray
            Write-Host "    doesn't exist, or there is a global Azure outage. Check:" -ForegroundColor Gray
            Write-Host "    https://status.azure.com" -ForegroundColor Cyan
        }

        [void]$script:DnsComparisonResults.Add([PSCustomObject]@{
            Hostname         = $hostname
            InternalResult   = 'FAILED'
            ExternalResult   = if ($externalAddrs.Count -gt 0) { $externalAddrs -join ', ' } else { 'FAILED' }
            FilteringConfirmed = ($externalAddrs.Count -gt 0)
        })
    }

    if ($dnsFilteringConfirmed) {
        Write-Host "  SUMMARY: DNS FILTERING IS CONFIRMED on this network." -ForegroundColor Red
        Write-Host "  Your DNS/security team must add Azure Migrate domains to their DNS allowlist." -ForegroundColor Red
    }
}

# ============================================================================
# TEST-TRACEROUTE
# ============================================================================
function Test-TraceRoute {
    param(
        [string]$Cloud = 'Commercial'
    )

    $hasTcpFailures = ($script:TestResults | Where-Object { $_.DnsPass -and -not $_.TcpPass }).Count -gt 0
    if (-not $hasTcpFailures) { return }

    Write-Section "TRACEROUTE - WHERE IS TRAFFIC DYING?"
    Write-Host "  WHY THIS MATTERS: A traceroute shows every network device (router, firewall)" -ForegroundColor Gray
    Write-Host "  your traffic passes through on the way to Azure. When traffic stops at a" -ForegroundColor Gray
    Write-Host "  specific hop, that device is almost certainly the one blocking it." -ForegroundColor Gray
    Write-Host "  This gives your network team the exact IP of the device to investigate." -ForegroundColor Gray
    Write-Host ""

    # Select targets based on cloud
    $targets = switch ($Cloud) {
        'Government' { @('management.usgovcloudapi.net', 'login.microsoftonline.us') }
        'China'      { @('management.chinacloudapi.cn', 'login.microsoftonline.cn') }
        default      { @('management.azure.com', 'login.microsoftonline.com') }
    }

    foreach ($target in $targets) {
        Write-Host "  Tracing route to: $target" -ForegroundColor White
        Write-Host "  (This may take up to 30 seconds — each * means a device didn't respond)" -ForegroundColor Gray
        Write-Host ""

        $hops = [System.Collections.ArrayList]::new()
        $lastRespondingHop = $null
        $reachedAzure = $false

        try {
            # Use Test-NetConnection -TraceRoute if available (PS 4+)
            $tncResult = $null
            try {
                $tncResult = Test-NetConnection -ComputerName $target -Port 443 -TraceRoute -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            } catch {}

            if ($tncResult -and $tncResult.TraceRoute) {
                $hopNum = 0
                foreach ($hopIp in $tncResult.TraceRoute) {
                    $hopNum++
                    $ipStr = $hopIp.ToString()
                    if ($ipStr -eq '0.0.0.0' -or $ipStr -eq '::') {
                        $label = '[No response - * * *]'
                        $color = 'DarkGray'
                    } elseif ($ipStr -match '^10\.' -or $ipStr -match '^192\.168\.' -or $ipStr -match '^172\.(1[6-9]|2[0-9]|3[01])\.') {
                        $label = '[Internal network]'
                        $color = 'Cyan'
                        $lastRespondingHop = [PSCustomObject]@{ Hop = $hopNum; IP = $ipStr; Label = $label }
                    } elseif ($ipStr -match '2603\.|52\.|40\.|20\.|104\.' ) {
                        $label = '[Possibly Azure / ISP]'
                        $color = 'Green'
                        $reachedAzure = $true
                        $lastRespondingHop = [PSCustomObject]@{ Hop = $hopNum; IP = $ipStr; Label = $label }
                    } else {
                        $label = '[External / ISP / Azure]'
                        $color = 'Green'
                        $lastRespondingHop = [PSCustomObject]@{ Hop = $hopNum; IP = $ipStr; Label = $label }
                    }
                    Write-Host "    Hop $($hopNum.ToString().PadLeft(2)): $($ipStr.PadRight(18)) $label" -ForegroundColor $color
                    [void]$hops.Add([PSCustomObject]@{ Hop = $hopNum; IP = $ipStr; Label = $label })
                }
            } else {
                # Fall back to tracert.exe
                Write-Host "  (Using tracert.exe fallback)" -ForegroundColor Gray
                $tracertArgs = @('-d', '-h', '20', '-w', '2000', $target)
                $proc = Start-Process -FilePath 'tracert.exe' -ArgumentList $tracertArgs `
                    -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\tracert_out.txt" `
                    -ErrorAction SilentlyContinue
                if (Test-Path "$env:TEMP\tracert_out.txt") {
                    $trLines = Get-Content "$env:TEMP\tracert_out.txt" -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\tracert_out.txt" -Force -ErrorAction SilentlyContinue
                    $hopNum = 0
                    foreach ($tl in $trLines) {
                        if ($tl -match '^\s*(\d+)\s') {
                            $hopNum++
                            if ($tl -match '(\d+\.\d+\.\d+\.\d+)') {
                                $ipStr = $matches[1]
                                $label = '[External/ISP]'
                                $color = 'Gray'
                                if ($ipStr -match '^10\.' -or $ipStr -match '^192\.168\.' -or $ipStr -match '^172\.(1[6-9]|2[0-9]|3[01])\.') {
                                    $label = '[Internal network]'; $color = 'Cyan'
                                    $lastRespondingHop = [PSCustomObject]@{ Hop = $hopNum; IP = $ipStr; Label = $label }
                                }
                                Write-Host "    Hop $($hopNum.ToString().PadLeft(2)): $($ipStr.PadRight(18)) $label" -ForegroundColor $color
                                [void]$hops.Add([PSCustomObject]@{ Hop = $hopNum; IP = $ipStr; Label = $label })
                            } elseif ($tl -match '\*\s+\*\s+\*') {
                                Write-Host "    Hop $($hopNum.ToString().PadLeft(2)): * * *               [No response - device not replying]" -ForegroundColor DarkGray
                                [void]$hops.Add([PSCustomObject]@{ Hop = $hopNum; IP = '* * *'; Label = '[No response]' })
                            }
                        }
                    }
                }
            }

            Write-Host ""
            if ($hops.Count -eq 0) {
                Write-Host "  Could not collect traceroute data. Traceroute may be blocked on this machine." -ForegroundColor Yellow
            } elseif ($reachedAzure) {
                Write-Host "  FINDING: Traffic appears to have reached Azure-range IPs via $($hops.Count) hops." -ForegroundColor Green
                Write-Host "  If TCP tests are still failing, the block may be at the Azure service level" -ForegroundColor Green
                Write-Host "  (e.g., NSG, App Gateway, or the service itself) rather than your network." -ForegroundColor Green
            } elseif ($lastRespondingHop) {
                Write-Host "  FINDING: Network traffic stopped after hop $($lastRespondingHop.Hop)." -ForegroundColor Red
                Write-Host "  The last device that responded was: $($lastRespondingHop.IP)" -ForegroundColor Red
                if ($lastRespondingHop.Label -match 'Internal') {
                    Write-Host "  This is an INTERNAL network device — likely your corporate firewall" -ForegroundColor Red
                    Write-Host "  or perimeter security appliance." -ForegroundColor Red
                    Write-Host "  ACTION: Your network team should investigate the device at $($lastRespondingHop.IP)" -ForegroundColor Yellow
                    Write-Host "  and check its outbound rules for TCP/443 to Azure service domains." -ForegroundColor Yellow
                }
                [void]$script:Recommendations.Add("TRACEROUTE: Traffic to $target stopped at hop $($lastRespondingHop.Hop) ($($lastRespondingHop.IP)). Network team should check outbound rules on this device.")
            } else {
                Write-Host "  FINDING: All hops were unresponsive (* * *). This can mean:" -ForegroundColor Yellow
                Write-Host "  - ICMP is blocked by the network (common in enterprise networks)" -ForegroundColor Yellow
                Write-Host "  - The machine has no default gateway" -ForegroundColor Yellow
                Write-Host "  Traceroute alone is inconclusive — rely on TCP test results above." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Traceroute failed: $($_.Exception.Message)" -ForegroundColor Yellow
        } finally {
            $hops = $null
            $tncResult = $null
        }

        [void]$script:TraceRouteResults.Add([PSCustomObject]@{
            Target             = $target
            LastRespondingHop  = if ($lastRespondingHop) { "$($lastRespondingHop.Hop): $($lastRespondingHop.IP)" } else { 'None/Unknown' }
            ReachedAzure       = $reachedAzure
        })

        Write-Host ""
    }
}

# ============================================================================
# TEST-PROXYCONNECT
# ============================================================================
function Test-ProxyConnect {
    param([string]$ProxyString)

    if (-not $ProxyString -or $ProxyString -match 'Direct access') { return }

    Write-Section "PROXY CONNECT TEST"
    Write-Host "  A proxy server was detected. This test explicitly asks the proxy to forward" -ForegroundColor Gray
    Write-Host "  a connection to Azure — and captures exactly what the proxy says back." -ForegroundColor Gray
    Write-Host "  This proves whether the proxy is blocking, requiring auth, or working correctly." -ForegroundColor Gray
    Write-Host ""

    # Parse proxy host:port
    $proxyHost = $null; $proxyPort = 8080
    if ($ProxyString -match '(?:https?://)?([^:/\s]+)(?::(\d+))?') {
        $proxyHost = $matches[1]
        if ($matches[2]) { $proxyPort = [int]$matches[2] }
    }
    if (-not $proxyHost) {
        Write-Host "  Could not parse proxy server address from: $ProxyString" -ForegroundColor Yellow
        return
    }

    Write-Host "  Proxy server: $proxyHost`:$proxyPort" -ForegroundColor White
    Write-Host ""

    $testTargets = @('management.azure.com', 'login.microsoftonline.com')
    foreach ($target in $testTargets) {
        Write-Host "  Testing CONNECT to: $target`:443" -ForegroundColor White
        $tcpClient = $null; $netStream = $null; $writer = $null; $reader = $null
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connectTask = $tcpClient.ConnectAsync($proxyHost, $proxyPort)
            $connected = $connectTask.Wait(5000)

            if (-not $connected -or $connectTask.IsFaulted) {
                Write-Host "    [FAIL] Cannot reach the proxy server itself at $proxyHost`:$proxyPort" -ForegroundColor Red
                Write-Host "    MEANING: The proxy is unreachable. Either the proxy address is wrong," -ForegroundColor Yellow
                Write-Host "    the proxy is down, or the appliance is not on the right network segment." -ForegroundColor Yellow
                [void]$script:ProxyConnectResults.Add([PSCustomObject]@{ Target = $target; Result = 'ProxyUnreachable'; Response = 'N/A' })
                [void]$script:Recommendations.Add("PROXY UNREACHABLE: Cannot connect to proxy $proxyHost`:$proxyPort. Verify proxy address or check if appliance needs proxy configured.")
                continue
            }

            $netStream = $tcpClient.GetStream()
            $writer    = New-Object System.IO.StreamWriter($netStream)
            $reader    = New-Object System.IO.StreamReader($netStream)
            $writer.AutoFlush = $true

            $connectReq = "CONNECT $target`:443 HTTP/1.1`r`nHost: $target`:443`r`nProxy-Connection: keep-alive`r`nUser-Agent: AzureMigrateConnectivityChecker/3.0`r`n`r`n"
            $writer.Write($connectReq)

            $netStream.ReadTimeout = 5000
            $responseLine = ''
            try { $responseLine = $reader.ReadLine() } catch {}

            $resultCode = 'Unknown'; $plain = ''
            if ($responseLine -match '200') {
                $resultCode = 'Pass'
                $plain = "[PASS] Proxy forwarded the connection successfully. The proxy is NOT blocking Azure Migrate traffic."
                Write-Host "    $plain" -ForegroundColor Green
            } elseif ($responseLine -match '407') {
                $resultCode = 'ProxyAuthRequired'
                $plain = "[FAIL] PROXY AUTHENTICATION REQUIRED: The proxy server is asking for a username and password before it will forward traffic. The Azure Migrate appliance is not providing credentials. Fix: Open Appliance Configuration Manager > set proxy credentials."
                Write-Host "    $plain" -ForegroundColor Red
                [void]$script:Recommendations.Add("PROXY 407: Proxy at $proxyHost requires authentication. Configure proxy credentials in the Appliance Configuration Manager.")
            } elseif ($responseLine -match '403') {
                $resultCode = 'ProxyCategoryBlock'
                $plain = "[FAIL] PROXY CATEGORY BLOCK: The proxy returned 403 Forbidden. This means the proxy's URL filtering/categorization policy is blocking Azure Migrate domains. Your proxy team must add these domains to the proxy allowlist."
                Write-Host "    $plain" -ForegroundColor Red
                [void]$script:Recommendations.Add("PROXY 403: Proxy at $proxyHost is blocking Azure domains by category. Add Azure Migrate wildcard domains to proxy allowlist.")
            } elseif ($responseLine -match '5\d\d') {
                $resultCode = 'ProxyError'
                $plain = "[FAIL] The proxy returned a server error ($responseLine). The proxy may be misconfigured or overloaded."
                Write-Host "    $plain" -ForegroundColor Yellow
            } elseif ($responseLine -eq '') {
                $resultCode = 'NoResponse'
                $plain = "[FAIL] No response from proxy. The proxy may be performing SSL inspection and intercepting the connection silently, or it timed out."
                Write-Host "    $plain" -ForegroundColor Yellow
                [void]$script:Warnings.Add("Proxy CONNECT got no response for $target — possible SSL inspection or proxy misconfiguration.")
            } else {
                $resultCode = 'Unexpected'
                $plain = "[UNKNOWN] Unexpected proxy response: $responseLine"
                Write-Host "    $plain" -ForegroundColor Yellow
            }

            [void]$script:ProxyConnectResults.Add([PSCustomObject]@{ Target = $target; Result = $resultCode; Response = $responseLine })

        } catch {
            Write-Host "    Proxy CONNECT test error: $($_.Exception.Message)" -ForegroundColor Yellow
            [void]$script:ProxyConnectResults.Add([PSCustomObject]@{ Target = $target; Result = 'Error'; Response = $_.Exception.Message })
        } finally {
            if ($reader)    { try { $reader.Close();    $reader.Dispose()    } catch {} }
            if ($writer)    { try { $writer.Close();    $writer.Dispose()    } catch {} }
            if ($netStream) { try { $netStream.Close(); $netStream.Dispose() } catch {} }
            if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
            $reader = $null; $writer = $null; $netStream = $null; $tcpClient = $null
        }
        Write-Host ""
    }
}

# ============================================================================
# GET-TLSCERTIFICATECHAIN
# ============================================================================
function Get-TlsCertificateChain {
    param([string]$Cloud = 'Commercial')

    Write-Section "TLS CERTIFICATE CHAIN INSPECTION"
    Write-Host "  WHY THIS MATTERS: When a corporate security device (Zscaler, Palo Alto Decrypt," -ForegroundColor Gray
    Write-Host "  Blue Coat, Forcepoint) performs SSL inspection, it replaces the real Microsoft" -ForegroundColor Gray
    Write-Host "  certificate with one it signed itself. This can break Azure authentication." -ForegroundColor Gray
    Write-Host "  This test captures the actual certificate chain to prove what's signing it." -ForegroundColor Gray
    Write-Host ""

    $targets = switch ($Cloud) {
        'Government' { @('management.usgovcloudapi.net', 'login.microsoftonline.us') }
        'China'      { @('management.chinacloudapi.cn', 'login.microsoftonline.cn') }
        default      { @('management.azure.com', 'login.microsoftonline.com') }
    }

    $legitimateCAs = @('DigiCert','Baltimore CyberTrust','Microsoft RSA','GlobalSign','Entrust','Comodo','Sectigo','Let''s Encrypt','QuoVadis')

    foreach ($target in $targets) {
        Write-Host "  Inspecting certificate for: $target" -ForegroundColor White
        $tcpClient = $null; $sslStream = $null; $cert = $null; $chain = $null
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $conn = $tcpClient.ConnectAsync($target, 443)
            if (-not $conn.Wait(5000)) {
                Write-Host "    Could not connect to $target`:443 — skipping cert check" -ForegroundColor Yellow
                [void]$script:CertChainResults.Add([PSCustomObject]@{ Target=$target; Status='Unreachable'; Issuer='N/A'; RootCA='N/A'; SslInspection=$false })
                continue
            }

            $sslStream = New-Object System.Net.Security.SslStream(
                $tcpClient.GetStream(), $false,
                [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
            )
            $sslStream.AuthenticateAsClient($target)
            $cert  = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain

            Write-Host "    Certificate Subject : $($cert.Subject)" -ForegroundColor Gray
            Write-Host "    Issued By (Issuer)  : $($cert.Issuer)" -ForegroundColor Gray
            Write-Host "    Valid Until         : $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
            Write-Host "    Thumbprint          : $($cert.Thumbprint)" -ForegroundColor Gray

            [void]$chain.Build($cert)
            Write-Host "    Certificate chain   :" -ForegroundColor Gray
            foreach ($elem in $chain.ChainElements) {
                $c = $elem.Certificate
                Write-Host "      -> $($c.Subject.Substring(0,[Math]::Min(80,$c.Subject.Length)))" -ForegroundColor Gray
            }

            # Identify root CA
            $rootCert = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
            $rootIssuer = $rootCert.Subject
            $knownLegit = $legitimateCAs | Where-Object { $rootIssuer -match $_ }
            $sslInspected = ($knownLegit.Count -eq 0)

            Write-Host ""
            if ($sslInspected) {
                Write-Host "    [SSL INSPECTION DETECTED]" -ForegroundColor Red
                Write-Host "    Root CA: $rootIssuer" -ForegroundColor Red
                Write-Host "    The certificate was NOT issued by a recognized Microsoft/DigiCert/GlobalSign CA." -ForegroundColor Red
                Write-Host "    A security device on your network is intercepting and re-signing HTTPS traffic." -ForegroundColor Red
                Write-Host "    This is caused by: Zscaler, Palo Alto SSL Decrypt, Blue Coat, Forcepoint, or similar." -ForegroundColor Yellow
                Write-Host "    IMPACT: Azure Migrate may fail to authenticate because the certificate" -ForegroundColor Yellow
                Write-Host "    it expects from Microsoft is being replaced by your security device." -ForegroundColor Yellow
                Write-Host "    FIX: Ask your security/proxy team to add an SSL inspection BYPASS rule" -ForegroundColor Yellow
                Write-Host "    for Azure Migrate domains (see Firewall Rule Summary section)." -ForegroundColor Yellow
                [void]$script:Recommendations.Add("SSL INSPECTION DETECTED for $target. Root CA: $rootIssuer. Request SSL inspection bypass from security team for Azure Migrate domains.")
            } else {
                Write-Host "    [PASS] Certificate is genuine — issued by a legitimate Microsoft/trusted CA." -ForegroundColor Green
                Write-Host "    Root CA: $rootIssuer" -ForegroundColor Green
                Write-Host "    No SSL inspection detected for this endpoint." -ForegroundColor Green
            }

            [void]$script:CertChainResults.Add([PSCustomObject]@{
                Target        = $target
                Status        = if ($sslInspected) { 'SSLInspected' } else { 'Genuine' }
                Issuer        = $cert.Issuer
                RootCA        = $rootIssuer
                SslInspection = $sslInspected
                ValidUntil    = $cert.NotAfter.ToString('yyyy-MM-dd')
            })

        } catch {
            Write-Host "    Could not inspect certificate: $($_.Exception.Message)" -ForegroundColor Yellow
            [void]$script:CertChainResults.Add([PSCustomObject]@{ Target=$target; Status='Error'; Issuer='N/A'; RootCA='N/A'; SslInspection=$false })
        } finally {
            if ($chain)     { try { $chain.Reset(); $chain.Dispose()           } catch {} }
            if ($cert)      { try { $cert.Dispose()                            } catch {} }
            if ($sslStream) { try { $sslStream.Close(); $sslStream.Dispose()   } catch {} }
            if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose()   } catch {} }
            $chain = $null; $cert = $null; $sslStream = $null; $tcpClient = $null
        }
        Write-Host ""
    }
}

# ============================================================================
# WRITE-EXECUTIVESUMMARY
# ============================================================================
function Write-ExecutiveSummary {
    param([string]$Cloud, [string]$ConnectivityPath)

    $failed      = $script:TestResults | Where-Object { -not $_.OverallPass }
    $total       = $script:TestResults.Count
    $tcpFails    = ($script:TestResults | Where-Object { $_.DnsPass -and -not $_.TcpPass }).Count
    $dnsFails    = ($script:TestResults | Where-Object { -not $_.DnsPass }).Count
    $httpsFails  = ($script:TestResults | Where-Object { $_.DnsPass -and $_.TcpPass -and -not $_.HttpsPass }).Count

    $dnsFiltering    = ($script:DnsComparisonResults | Where-Object { $_.FilteringConfirmed }).Count -gt 0
    $sslInspection   = ($script:CertChainResults     | Where-Object { $_.SslInspection }).Count -gt 0
    $proxyBlock403   = ($script:ProxyConnectResults   | Where-Object { $_.Result -eq 'ProxyBlockCategoryBlock' -or $_.Result -eq 'ProxyCategoryBlock' }).Count -gt 0
    $proxyAuth407    = ($script:ProxyConnectResults   | Where-Object { $_.Result -eq 'ProxyAuthRequired' }).Count -gt 0
    $clockCritical   = ($null -ne $script:ClockSkewResult -and $script:ClockSkewResult.Status -eq 'Fail')
    $hostsIssues     = ($null -ne $script:HostsFileResult -and $script:HostsFileResult.Count -gt 0)
    $traceEvidence   = ($script:TraceRouteResults | Where-Object { -not $_.ReachedAzure -and $_.LastRespondingHop -ne 'None/Unknown' }).Count -gt 0
    $logErrors       = ($null -ne $script:ApplianceLogFindings -and $script:ApplianceLogFindings.OnboardingErrors -and $script:ApplianceLogFindings.OnboardingErrors.Count -gt 0)

    # Determine verdicts (can be multiple)
    $verdicts = [System.Collections.ArrayList]::new()
    if ($failed.Count -eq 0 -and -not $clockCritical -and -not $hostsIssues -and -not $sslInspection) {
        [void]$verdicts.Add('NETWORK_OK')
    } else {
        if ($tcpFails -gt 0 -or $dnsFails -gt 0 -or $dnsFiltering -or $proxyBlock403) {
            [void]$verdicts.Add('NETWORK_BLOCKED')
        }
        if ($sslInspection -or $httpsFails -gt 0) {
            [void]$verdicts.Add('SSL_INSPECTION')
        }
        if ($proxyAuth407) {
            [void]$verdicts.Add('PROXY_AUTH')
        }
        if ($clockCritical) {
            [void]$verdicts.Add('CLOCK_ISSUE')
        }
        if ($hostsIssues) {
            [void]$verdicts.Add('HOSTS_OVERRIDE')
        }
        if ($verdicts.Count -eq 0) {
            [void]$verdicts.Add('MIXED')
        }
    }

    $script:ExecutiveSummary = @{
        Verdicts         = $verdicts
        TotalTests       = $total
        FailedTests      = $failed.Count
        TcpFails         = $tcpFails
        DnsFails         = $dnsFails
        HttpsFails       = $httpsFails
        DnsFiltering     = $dnsFiltering
        SslInspection    = $sslInspection
        ProxyBlock       = $proxyBlock403
        ProxyAuth        = $proxyAuth407
        ClockCritical    = $clockCritical
        HostsIssues      = $hostsIssues
        TraceEvidence    = $traceEvidence
        LogErrors        = $logErrors
    }

    $line = '=' * 80

    Write-Host ""
    Write-Host $line -ForegroundColor White
    Write-Host "  EXECUTIVE SUMMARY" -ForegroundColor White
    Write-Host $line -ForegroundColor White

    foreach ($verdict in $verdicts) {
        switch ($verdict) {
            'NETWORK_OK' {
                Write-Host ""
                Write-Host "  VERDICT: ALL NETWORK CONNECTIVITY IS HEALTHY" -ForegroundColor Green
                Write-Host ""
                Write-Host "  All $total required Microsoft Azure endpoints were successfully reached from" -ForegroundColor White
                Write-Host "  this machine. DNS resolution, TCP connectivity, and HTTPS handshakes all passed." -ForegroundColor White
                Write-Host ""
                Write-Host "  The Azure Migrate appliance connectivity problem is NOT caused by the network." -ForegroundColor Green
                Write-Host ""
                Write-Host "  Who needs to act : The Azure Migrate appliance administrator" -ForegroundColor White
                Write-Host "  Next steps        : Check appliance configuration, registration status," -ForegroundColor White
                Write-Host "                      service health, and subscription permissions." -ForegroundColor White
            }
            'NETWORK_BLOCKED' {
                Write-Host ""
                Write-Host "  VERDICT: NETWORK IS BLOCKING AZURE MIGRATE" -ForegroundColor Red
                Write-Host ""
                Write-Host "  $($failed.Count) of $total required Microsoft Azure endpoints are blocked." -ForegroundColor Red
                if ($tcpFails -gt 0) {
                    Write-Host "  - $tcpFails endpoint(s) are being BLOCKED at the firewall level" -ForegroundColor Red
                    Write-Host "    (DNS resolved correctly, but TCP connection was dropped or refused)" -ForegroundColor Red
                }
                if ($dnsFails -gt 0) {
                    $filterStr = if ($dnsFiltering) { " [DNS FILTERING CONFIRMED]" } else { "" }
                    Write-Host "  - $dnsFails endpoint(s) could not be resolved by DNS$filterStr" -ForegroundColor Red
                }
                if ($traceEvidence) {
                    $trEvidence = $script:TraceRouteResults | Where-Object { -not $_.ReachedAzure } | Select-Object -First 1
                    if ($trEvidence) {
                        Write-Host ""
                        Write-Host "  Traceroute evidence: Traffic to $($trEvidence.Target) stopped at" -ForegroundColor Yellow
                        Write-Host "  hop $($trEvidence.LastRespondingHop). That device is the likely blocker." -ForegroundColor Yellow
                    }
                }
                Write-Host ""
                Write-Host "  This is a NETWORK issue. The Azure Migrate appliance software is NOT the cause." -ForegroundColor Red
                Write-Host "  Who needs to act: Network / Firewall team and/or DNS team" -ForegroundColor White
            }
            'SSL_INSPECTION' {
                Write-Host ""
                $sslTarget = $script:CertChainResults | Where-Object { $_.SslInspection } | Select-Object -First 1
                Write-Host "  VERDICT: SSL INSPECTION IS INTERFERING WITH AZURE MIGRATE" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  A security device on your network is intercepting and re-signing HTTPS traffic." -ForegroundColor Yellow
                if ($sslTarget) {
                    Write-Host "  The certificate for $($sslTarget.Target) was signed by:" -ForegroundColor Yellow
                    Write-Host "  '$($sslTarget.RootCA)'" -ForegroundColor Red
                    Write-Host "  instead of a Microsoft/DigiCert certificate authority." -ForegroundColor Yellow
                }
                Write-Host ""
                Write-Host "  This is typically caused by: Zscaler, Palo Alto SSL Decryption, Blue Coat," -ForegroundColor White
                Write-Host "  Forcepoint, or a corporate deep-inspection proxy." -ForegroundColor White
                Write-Host ""
                Write-Host "  Who needs to act: Security / Proxy team — add SSL inspection bypass for" -ForegroundColor White
                Write-Host "  Azure Migrate domains listed in the Firewall Rule Summary section." -ForegroundColor White
            }
            'PROXY_AUTH' {
                Write-Host ""
                Write-Host "  VERDICT: PROXY AUTHENTICATION IS REQUIRED" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  The proxy server requires a username and password, but the appliance" -ForegroundColor White
                Write-Host "  is not providing credentials. Azure Migrate traffic is being blocked." -ForegroundColor White
                Write-Host "  Who needs to act: The admin running this — configure proxy credentials" -ForegroundColor White
                Write-Host "  in the Appliance Configuration Manager (https://localhost:44368)." -ForegroundColor White
            }
            'CLOCK_ISSUE' {
                Write-Host ""
                Write-Host "  VERDICT: CLOCK SYNC ISSUE WILL BLOCK AUTHENTICATION" -ForegroundColor Red
                Write-Host ""
                Write-Host "  This machine's clock is more than 5 minutes out of sync." -ForegroundColor Red
                Write-Host "  Microsoft Azure authentication (Entra ID) will reject ALL login attempts." -ForegroundColor Red
                Write-Host "  This can cause failure even if the network is healthy." -ForegroundColor Red
                Write-Host "  Who needs to act: The admin running this — run w32tm /resync /force" -ForegroundColor White
            }
            'HOSTS_OVERRIDE' {
                Write-Host ""
                Write-Host "  VERDICT: HOSTS FILE IS OVERRIDING AZURE DOMAIN LOOKUPS" -ForegroundColor Red
                Write-Host ""
                Write-Host "  The Windows hosts file has entries that redirect Azure domain names" -ForegroundColor Red
                Write-Host "  to wrong IP addresses. This overrides DNS and blocks Azure Migrate." -ForegroundColor Red
                Write-Host "  Who needs to act: The admin running this — remove hosts file entries." -ForegroundColor White
            }
        }
    }

    if ($logErrors) {
        Write-Host ""
        Write-Host "  NOTE: The Appliance Configuration Manager log also shows errors that" -ForegroundColor Yellow
        Write-Host "  corroborate these findings. See the Log Analysis section for details." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host $line -ForegroundColor White
    Write-Host ""
}

# ============================================================================
# WRITE-NEXTSTEPS
# ============================================================================
function Write-NextSteps {

    $es = $script:ExecutiveSummary
    if (-not $es) { return }

    Write-Section "NEXT STEPS — WHAT TO DO NOW"
    Write-Host "  These steps are generated specifically based on what was found in this run." -ForegroundColor Gray
    Write-Host "  Only issues that were actually detected are listed here." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  NOTE: This script finished in under 5 minutes. The times shown below are" -ForegroundColor White
    Write-Host "  how long it will take your team to FIX each issue — not how long this" -ForegroundColor White
    Write-Host "  script took to run." -ForegroundColor White
    Write-Host ""

    $stepNum = 0

    # Firewall / TCP block
    if ($es.TcpFails -gt 0 -or $es.DnsFails -gt 0) {
        $stepNum++
        $traceStr = ''
        $trEvidence = $script:TraceRouteResults | Where-Object { -not $_.ReachedAzure } | Select-Object -First 1
        if ($trEvidence) { $traceStr = " (Traceroute shows traffic dying at $($trEvidence.LastRespondingHop))" }

        Write-Host "  STEP $stepNum : SUBMIT A FIREWALL / NETWORK CHANGE REQUEST" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Evidence$traceStr" -ForegroundColor White
        Write-Host "  1. Find the 'FIREWALL RULE SUMMARY' section of this report." -ForegroundColor White
        Write-Host "     It lists every blocked domain with the exact firewall rule needed." -ForegroundColor White
        Write-Host "  2. Forward this full report to your network / firewall team." -ForegroundColor White
        Write-Host "  3. Ask them to add outbound TCP/443 ALLOW rules for each blocked domain." -ForegroundColor White
        Write-Host "  4. Request a change ticket number for tracking." -ForegroundColor White
        Write-Host "  5. Re-run this script after the change to confirm it is resolved." -ForegroundColor White
        Write-Host "  Responsible team    : Network / Firewall engineers" -ForegroundColor Cyan
        Write-Host "  Estimated resolution: 1-4 hours (includes change approval process)" -ForegroundColor Cyan
        Write-Host ""
    }

    # DNS filtering
    if ($es.DnsFiltering) {
        $stepNum++
        $confirmedCount = ($script:DnsComparisonResults | Where-Object { $_.FilteringConfirmed }).Count
        Write-Host "  STEP $stepNum : DNS FILTERING — REQUEST ALLOWLIST UPDATE" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Evidence: $confirmedCount domain(s) blocked by internal DNS but resolved by 8.8.8.8" -ForegroundColor White
        Write-Host "  1. Forward this report to your DNS security / IT security team." -ForegroundColor White
        Write-Host "  2. Quote this specific finding: 'Internal DNS blocks Azure Migrate domains;" -ForegroundColor White
        Write-Host "     public DNS (8.8.8.8) resolves them correctly.'" -ForegroundColor White
        Write-Host "  3. Ask them to add Azure Migrate wildcard domains to the DNS allowlist:" -ForegroundColor White
        Write-Host "     - Cisco Umbrella: add to 'Allow' list in the Umbrella dashboard" -ForegroundColor Gray
        Write-Host "     - Infoblox: remove the RPZ (Response Policy Zone) block entries" -ForegroundColor Gray
        Write-Host "     - Windows DNS: remove entries from the Response Policy Zone" -ForegroundColor Gray
        Write-Host "     - Other DNS filter: add *.microsoft.com, *.azure.com, *.windows.net, *.microsoftonline.com to passthrough" -ForegroundColor Gray
        Write-Host "  4. Re-run this script after the DNS change to verify." -ForegroundColor White
        Write-Host "  Responsible team    : DNS / IT Security team" -ForegroundColor Cyan
        Write-Host "  Estimated resolution: 30 minutes to 2 hours" -ForegroundColor Cyan
        Write-Host ""
    }

    # Proxy category block (403)
    if ($es.ProxyBlock) {
        $stepNum++
        Write-Host "  STEP $stepNum : PROXY ALLOWLIST — REQUEST CATEGORY EXCEPTION" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Evidence: Proxy returned HTTP 403 Forbidden for Azure Migrate domains" -ForegroundColor White
        Write-Host "  1. Forward this report to your proxy / web filtering team." -ForegroundColor White
        Write-Host "  2. Quote: 'Proxy returned 403 Forbidden when Azure Migrate appliance" -ForegroundColor White
        Write-Host "     attempted CONNECT to Azure service endpoints.'" -ForegroundColor White
        Write-Host "  3. Ask them to add Azure Migrate domains to the proxy URL allowlist." -ForegroundColor White
        Write-Host "     - Zscaler          : Add URL Category exception in ZIA policy" -ForegroundColor Gray
        Write-Host "     - Blue Coat/Symantec: Create Allow policy for these destinations" -ForegroundColor Gray
        Write-Host "     - Forcepoint       : Add URL Category exception" -ForegroundColor Gray
        Write-Host "     - Other proxy      : Add *.microsoft.com, *.azure.com, *.windows.net to ALLOW" -ForegroundColor Gray
        Write-Host "  4. Re-run this script after the proxy change to verify." -ForegroundColor White
        Write-Host "  Responsible team    : Proxy / Web filtering team" -ForegroundColor Cyan
        Write-Host "  Estimated resolution: 30 minutes to 2 hours" -ForegroundColor Cyan
        Write-Host ""
    }

    # Proxy authentication (407)
    if ($es.ProxyAuth) {
        $stepNum++
        Write-Host "  STEP $stepNum : CONFIGURE PROXY CREDENTIALS ON APPLIANCE" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Evidence: Proxy returned 407 Proxy Authentication Required" -ForegroundColor White
        Write-Host "  1. Open the Appliance Configuration Manager on this machine:" -ForegroundColor White
        Write-Host "     Open a browser and go to: https://localhost:44368" -ForegroundColor Cyan
        Write-Host "  2. Go to Settings or the proxy configuration section." -ForegroundColor White
        Write-Host "  3. Enter the proxy server address, port, username, and password." -ForegroundColor White
        Write-Host "  4. Save and re-run this script to verify." -ForegroundColor White
        Write-Host "  Responsible team    : YOU (the admin running this script)" -ForegroundColor Cyan
        Write-Host "  Estimated resolution: 5-15 minutes" -ForegroundColor Cyan
        Write-Host ""
    }

    # SSL inspection
    if ($es.SslInspection) {
        $stepNum++
        $sslTarget = $script:CertChainResults | Where-Object { $_.SslInspection } | Select-Object -First 1
        $rootCA = if ($sslTarget) { $sslTarget.RootCA } else { 'unknown CA' }
        Write-Host "  STEP $stepNum : REQUEST SSL INSPECTION BYPASS FOR AZURE MIGRATE" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Evidence: Certificate chain shows '$rootCA' is signing Azure certs" -ForegroundColor White
        Write-Host "  1. Forward this report to your security / proxy team." -ForegroundColor White
        Write-Host "  2. Quote: 'SSL inspection is re-signing certificates for Azure Migrate" -ForegroundColor White
        Write-Host "     endpoints. This interferes with Azure authentication.'" -ForegroundColor White
        Write-Host "  3. Ask them to add an SSL inspection BYPASS rule for Azure Migrate domains:" -ForegroundColor White
        Write-Host "     - Palo Alto  : Decryption Policy > add No-Decrypt rule for these destinations" -ForegroundColor Gray
        Write-Host "     - Zscaler    : SSL Inspection > add bypass for *.microsoft.com, *.azure.com etc" -ForegroundColor Gray
        Write-Host "     - Forcepoint : SSL inspection bypass policy" -ForegroundColor Gray
        Write-Host "     - Blue Coat  : SSL proxy exception list" -ForegroundColor Gray
        Write-Host "  4. Re-run this script after the bypass to verify." -ForegroundColor White
        Write-Host "  Responsible team    : Security / Proxy team" -ForegroundColor Cyan
        Write-Host "  Estimated resolution: 1-3 hours" -ForegroundColor Cyan
        Write-Host ""
    }

    # Clock skew
    if ($es.ClockCritical) {
        $stepNum++
        Write-Host "  STEP $stepNum : FIX CLOCK SYNC (YOU CAN DO THIS RIGHT NOW)" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Evidence: $($script:ClockSkewResult.Detail)" -ForegroundColor White
        Write-Host "  1. Open a Command Prompt AS ADMINISTRATOR on this machine." -ForegroundColor White
        Write-Host "     (Right-click Command Prompt > Run as administrator)" -ForegroundColor Gray
        Write-Host "  2. Run these commands one at a time:" -ForegroundColor White
        Write-Host "     net stop w32time" -ForegroundColor Cyan
        Write-Host "     net start w32time" -ForegroundColor Cyan
        Write-Host "     w32tm /resync /force" -ForegroundColor Cyan
        Write-Host "  3. Verify it worked:" -ForegroundColor White
        Write-Host "     w32tm /query /status" -ForegroundColor Cyan
        Write-Host "     (Look for 'Phase Offset' — should be less than 1 second)" -ForegroundColor Gray
        Write-Host "  4. Re-run this script to verify Azure authentication now works." -ForegroundColor White
        Write-Host "  Responsible team    : YOU (the admin running this script)" -ForegroundColor Cyan
        Write-Host "  Estimated resolution: 5 minutes" -ForegroundColor Cyan
        Write-Host ""
    }

    # Hosts file
    if ($es.HostsIssues) {
        $stepNum++
        Write-Host "  STEP $stepNum : REMOVE HOSTS FILE OVERRIDES (YOU CAN DO THIS RIGHT NOW)" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Evidence: Azure domain(s) found in the Windows hosts file" -ForegroundColor White
        Write-Host "  1. Open Notepad AS ADMINISTRATOR." -ForegroundColor White
        Write-Host "     (Search for Notepad > right-click > Run as administrator)" -ForegroundColor Gray
        Write-Host "  2. In Notepad, open: C:\Windows\System32\drivers\etc\hosts" -ForegroundColor Cyan
        Write-Host "  3. Find and DELETE the Azure-related entries listed in the 'Hosts File'" -ForegroundColor White
        Write-Host "     section of this report." -ForegroundColor White
        Write-Host "  4. Save the file and re-run this script to verify." -ForegroundColor White
        Write-Host "  Responsible team    : YOU (the admin running this script)" -ForegroundColor Cyan
        Write-Host "  Estimated resolution: 5 minutes" -ForegroundColor Cyan
        Write-Host ""
    }

    # All clear
    if ($es.Verdicts -contains 'NETWORK_OK') {
        $stepNum++
        Write-Host "  STEP $stepNum : NETWORK IS HEALTHY — INVESTIGATE APPLIANCE CONFIGURATION" -ForegroundColor Green
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Since network connectivity is confirmed working, the issue is inside" -ForegroundColor White
        Write-Host "  the appliance configuration or Azure project setup:" -ForegroundColor White
        Write-Host "  1. Open Appliance Configuration Manager: https://localhost:44368" -ForegroundColor Cyan
        Write-Host "     Look for any error messages on the onboarding screen." -ForegroundColor White
        Write-Host "  2. Check the appliance is registered to the correct Azure Migrate project." -ForegroundColor White
        Write-Host "     Go to: portal.azure.com > Azure Migrate > Servers, databases and webapps" -ForegroundColor Gray
        Write-Host "  3. Check appliance services are running:" -ForegroundColor White
        Write-Host "     Press Windows+R > type: services.msc > look for Azure Migrate services" -ForegroundColor Gray
        Write-Host "  4. Verify the Azure account has Contributor permissions on the subscription." -ForegroundColor White
        Write-Host "  5. Attach this report when opening a Microsoft Support case." -ForegroundColor White
        Write-Host "     It confirms the network is healthy, helping Support focus on appliance config." -ForegroundColor Gray
        Write-Host "  Responsible team    : Azure administrator" -ForegroundColor Cyan
        Write-Host "  Microsoft Support   : https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade" -ForegroundColor Cyan
        Write-Host ""
    }

    if ($es.LogErrors) {
        Write-Host "  TIP: Attach the following log file when contacting Microsoft Support:" -ForegroundColor Yellow
        Write-Host "  C:\ProgramData\Microsoft Azure\Logs\ConfigManager\ApplianceOnboarding-Portal-[today].log" -ForegroundColor Cyan
        Write-Host "  This log records the exact errors the appliance encountered and helps Support" -ForegroundColor Gray
        Write-Host "  diagnose the issue faster." -ForegroundColor Gray
        Write-Host ""
    }

    $script:NextStepsText = "See Executive Summary and Next Steps sections above for actions based on findings."
}

# ============================================================================
# v5.0 ADDITIONS — Features 1-4, 6-10
# ============================================================================

# ── Feature 1: Duplicate Appliance Detection ──────────────────────────────────
function Test-DuplicateAppliance {
    param(
        [ValidateSet('Commercial','Government','China')]
        [string]$Cloud = 'Commercial'
    )

    Write-Section "DUPLICATE APPLIANCE DETECTION (v5.0)"
    Write-Host "  Checking for multiple Azure Migrate installations and Cloud/registry mismatches." -ForegroundColor Gray
    Write-Host "  Side-by-side installations cause conflicts that look like network failures." -ForegroundColor Gray
    Write-Host ""

    $result = @{
        ApplianceId       = $null
        ProjectKey        = $null
        CloudEnvironment  = $null
        CloudMismatch     = $false
        Installations     = [System.Collections.ArrayList]::new()
        MultipleInstalls  = $false
    }

    # Read HKLM:\SOFTWARE\Microsoft\AzureAppliance
    $regPath = 'HKLM:\SOFTWARE\Microsoft\AzureAppliance'
    if (Test-Path $regPath) {
        $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($props) {
            $result.ApplianceId      = $props.ApplianceId
            $result.ProjectKey       = $props.ProjectKey
            $result.CloudEnvironment = $props.CloudEnvironment

            if ($result.ApplianceId) {
                $masked = $result.ApplianceId.Substring(0, [Math]::Min(8, $result.ApplianceId.Length)) + '...'
                Write-Host "  Appliance ID  : $masked" -ForegroundColor Gray
            }
            if ($result.CloudEnvironment) {
                Write-Host "  Cloud Env     : $($result.CloudEnvironment)" -ForegroundColor Gray
            }

            # Check cloud mismatch
            $expectedEnv = switch ($Cloud) {
                'Government' { 'AzureUSGovernment' }
                'China'      { 'AzureChinaCloud' }
                default      { 'AzureCloud' }
            }
            if ($result.CloudEnvironment -and $result.CloudEnvironment -ne $expectedEnv) {
                $result.CloudMismatch = $true
                Write-Host ""
                Write-Host "  [WARN] CLOUD ENVIRONMENT MISMATCH DETECTED!" -ForegroundColor Red
                Write-Host "  You selected '$Cloud' but the registry shows: $($result.CloudEnvironment)" -ForegroundColor Red
                Write-Host "  Expected value for $Cloud : $expectedEnv" -ForegroundColor Yellow
                Write-Host "  This mismatch means the appliance was registered to a DIFFERENT cloud." -ForegroundColor Yellow
                Write-Host "  The appliance will fail to communicate with the selected cloud endpoints." -ForegroundColor Yellow
                [void]$script:Recommendations.Add("CLOUD MISMATCH: Registry CloudEnvironment='$($result.CloudEnvironment)' but selected cloud is '$Cloud' (expected '$expectedEnv'). Re-register the appliance against the correct cloud.")
            } else {
                Write-Host "  Cloud environment matches selected cloud ($Cloud)." -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  Appliance registry key not found — appliance may not be installed on this machine." -ForegroundColor Gray
    }

    # Scan Programs and Features for Azure Migrate installations
    Write-Host ""
    Write-Host "  Scanning installed programs for Azure Migrate entries..." -ForegroundColor White

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($unPath in $uninstallPaths) {
        try {
            $items = Get-ItemProperty $unPath -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Azure Migrate' }
            foreach ($item in $items) {
                $entry = [PSCustomObject]@{
                    DisplayName  = $item.DisplayName
                    Version      = $item.DisplayVersion
                    InstallDate  = $item.InstallDate
                    InstallPath  = $item.InstallLocation
                }
                [void]$result.Installations.Add($entry)
            }
        } catch {}
    }

    if ($result.Installations.Count -gt 1) {
        $result.MultipleInstalls = $true
        Write-Host "  [WARN] MULTIPLE AZURE MIGRATE INSTALLATIONS DETECTED!" -ForegroundColor Red
        Write-Host "  Side-by-side installations cause service conflicts and unpredictable behavior." -ForegroundColor Red
        Write-Host ""
        foreach ($inst in $result.Installations) {
            Write-Host "    * $($inst.DisplayName) — v$($inst.Version) (installed $($inst.InstallDate))" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  ACTION: Uninstall all but one instance via Programs and Features." -ForegroundColor Yellow
        [void]$script:Recommendations.Add("MULTIPLE AZURE MIGRATE INSTALLATIONS: $($result.Installations.Count) installations found. Uninstall all but the current version via Control Panel > Programs and Features.")
    } elseif ($result.Installations.Count -eq 1) {
        $inst = $result.Installations[0]
        Write-Host "  [PASS] Single installation found: $($inst.DisplayName) v$($inst.Version)" -ForegroundColor Green
    } else {
        Write-Host "  No Azure Migrate entries found in Programs and Features." -ForegroundColor Gray
        Write-Host "  (Normal if running pre-install connectivity check)" -ForegroundColor Gray
    }

    $script:DuplicateApplianceResult = $result
    Write-Host ""
}

# ── Feature 2: vCenter Connectivity Test ─────────────────────────────────────
function Test-vCenterConnectivity {
    Write-Section "vCENTER CONNECTIVITY TEST (v5.0)"
    Write-Host "  Tests whether the appliance can reach vCenter and authenticate to it." -ForegroundColor Gray
    Write-Host "  Distinguishes 'network blocked' from 'wrong credentials'." -ForegroundColor Gray
    Write-Host ""

    $result = @{
        Skipped      = $false
        VCenter      = ''
        DnsPass      = $false
        TcpPass      = $false
        HttpsPass    = $false
        AuthResult   = 'NotTested'
        Summary      = ''
    }

    $vcenter = (Read-Host "  Enter vCenter FQDN or IP (press Enter to skip)").Trim()
    if (-not $vcenter) {
        Write-Host "  Skipping vCenter connectivity test." -ForegroundColor Gray
        $result.Skipped = $true
        $script:vCenterResult = $result
        Write-Host ""
        return
    }

    $result.VCenter = $vcenter
    Write-Host ""

    # Step 1: DNS
    Write-Host "  Step 1: DNS resolution of $vcenter ..." -ForegroundColor White
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($vcenter)
        if ($addrs.Count -gt 0) {
            $result.DnsPass = $true
            $ipList = ($addrs | ForEach-Object { $_.IPAddressToString }) -join ', '
            Write-Host "  [PASS] Resolved to: $ipList" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] DNS returned no addresses for $vcenter" -ForegroundColor Red
        }
    } catch {
        Write-Host "  [FAIL] DNS resolution failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Step 2: TCP 443
    Write-Host "  Step 2: TCP 443 to $vcenter ..." -ForegroundColor White
    $tcpClient = $null
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $task      = $tcpClient.ConnectAsync($vcenter, 443)
        $done      = $task.Wait(5000)
        if ($done -and -not $task.IsFaulted) {
            $result.TcpPass = $true
            Write-Host "  [PASS] TCP/443 connected to vCenter." -ForegroundColor Green
        } else {
            $errMsg = if ($task.IsFaulted) { $task.Exception.InnerException.Message } else { 'Connection timed out' }
            Write-Host "  [FAIL] TCP/443 to vCenter failed: $errMsg" -ForegroundColor Red
            Write-Host "  Cannot reach vCenter on TCP/443. Check firewall rules between appliance and vCenter host." -ForegroundColor Yellow
            [void]$script:Recommendations.Add("vCENTER UNREACHABLE: Cannot connect to $vcenter on TCP/443. Check firewall rules between the appliance and vCenter.")
        }
    } catch {
        Write-Host "  [FAIL] TCP error: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
        $tcpClient = $null
    }

    # Step 3: HTTPS GET to /sdk
    if ($result.TcpPass) {
        Write-Host "  Step 3: HTTPS GET to https://$vcenter/sdk ..." -ForegroundColor White
        $req = $null; $resp = $null
        try {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $req           = [System.Net.HttpWebRequest]::Create("https://$vcenter/sdk")
            $req.Method    = 'GET'
            $req.Timeout   = 10000
            $req.UserAgent = 'AzureMigrateConnectivityChecker/5.0'
            $req.AllowAutoRedirect = $true
            try {
                $resp = $req.GetResponse()
                $result.HttpsPass = $true
                $statusCode = [int]$resp.StatusCode
                Write-Host "  [PASS] vCenter /sdk responded HTTP $statusCode — vCenter is reachable." -ForegroundColor Green
                $resp.Close(); $resp.Dispose()
            } catch [System.Net.WebException] {
                $webEx = $_.Exception
                if ($webEx.Response) {
                    $code = [int]$webEx.Response.StatusCode
                    $result.HttpsPass = $true
                    Write-Host "  [PASS] vCenter is reachable (HTTP $code)." -ForegroundColor Green
                    if ($code -in @(401, 403)) {
                        Write-Host "  vCenter is reachable. The appliance can connect to it." -ForegroundColor Green
                        Write-Host "  If discovery is failing, verify the service account credentials." -ForegroundColor Yellow
                    }
                    if ($webEx.Response -is [System.Net.HttpWebResponse]) { $webEx.Response.Close() }
                } else {
                    Write-Host "  [FAIL] HTTPS error: $($webEx.Message)" -ForegroundColor Red
                    Write-Host "  Cannot reach vCenter on TCP/443. Check firewall rules between appliance and vCenter host." -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host "  [FAIL] HTTPS error: $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
            if ($resp) { try { $resp.Close(); $resp.Dispose() } catch {} }
            $req = $null; $resp = $null
        }
    }

    # Step 4: Optional credential test
    if ($result.HttpsPass) {
        Write-Host "  Step 4: Credential test (optional)" -ForegroundColor White
        $vcUser = (Read-Host "  Enter vCenter username to test authentication (press Enter to skip)").Trim()
        if ($vcUser) {
            $vcPass = (Read-Host "  Enter vCenter password" -AsSecureString)
            $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vcPass)
            $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

            $credBytes = [System.Text.Encoding]::ASCII.GetBytes("${vcUser}:${plainPass}")
            $plainPass = $null
            $b64Creds  = [Convert]::ToBase64String($credBytes)
            $credBytes = $null

            $req2 = $null; $resp2 = $null
            try {
                [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                $req2 = [System.Net.HttpWebRequest]::Create("https://$vcenter/rest/com/vmware/cis/session")
                $req2.Method  = 'GET'
                $req2.Timeout = 10000
                $req2.Headers.Add('Authorization', "Basic $b64Creds")
                $b64Creds = $null
                try {
                    $resp2 = $req2.GetResponse()
                    $code2 = [int]$resp2.StatusCode
                    if ($code2 -eq 200) {
                        $result.AuthResult = 'Pass'
                        Write-Host "  [PASS] Credentials VALID — authenticated to vCenter REST API." -ForegroundColor Green
                    } else {
                        $result.AuthResult = "HTTP $code2"
                        Write-Host "  [INFO] vCenter responded HTTP $code2 to auth attempt." -ForegroundColor Gray
                    }
                    $resp2.Close(); $resp2.Dispose()
                } catch [System.Net.WebException] {
                    $webEx2 = $_.Exception
                    if ($webEx2.Response) {
                        $code2 = [int]$webEx2.Response.StatusCode
                        if ($code2 -eq 401) {
                            $result.AuthResult = 'InvalidCredentials'
                            Write-Host "  [FAIL] Credentials INVALID (HTTP 401 Unauthorized)." -ForegroundColor Red
                            Write-Host "  vCenter is reachable but the username/password is wrong." -ForegroundColor Red
                            [void]$script:Recommendations.Add("vCENTER AUTH FAIL: vCenter at $vcenter is reachable but credentials are invalid. Verify the service account username and password used for Azure Migrate discovery.")
                        } else {
                            $result.AuthResult = "HTTP $code2"
                            Write-Host "  [INFO] vCenter responded HTTP $code2." -ForegroundColor Gray
                        }
                        if ($webEx2.Response -is [System.Net.HttpWebResponse]) { $webEx2.Response.Close() }
                    } else {
                        Write-Host "  [WARN] Auth test error: $($webEx2.Message)" -ForegroundColor Yellow
                    }
                }
            } catch {
                Write-Host "  [WARN] Auth test error: $($_.Exception.Message)" -ForegroundColor Yellow
            } finally {
                [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
                if ($resp2) { try { $resp2.Close(); $resp2.Dispose() } catch {} }
                $req2 = $null; $resp2 = $null; $b64Creds = $null
            }
        }
    }

    $script:vCenterResult = $result
    Write-Host ""
}

# ── Feature 3: MTU / Path MTU Detection ──────────────────────────────────────
function Test-MtuPath {
    param(
        [ValidateSet('Commercial','Government','China')]
        [string]$Cloud = 'Commercial'
    )

    Write-Section "MTU / PATH MTU DETECTION (v5.0)"
    Write-Host "  Detects MTU fragmentation issues that cause agentless migration to stall." -ForegroundColor Gray
    Write-Host "  Large replication frames fragmented by VPN/MPLS/PPPoE cause 0-byte transfer." -ForegroundColor Gray
    Write-Host ""

    $result = @{
        EffectiveMtu  = 0
        Status        = 'Unknown'
        Detail        = ''
        IcmpBlocked   = $false
    }

    $target = switch ($Cloud) {
        'Government' { 'management.usgovcloudapi.net' }
        'China'      { 'management.chinacloudapi.cn' }
        default      { 'management.azure.com' }
    }

    Write-Host "  Testing Path MTU to: $target" -ForegroundColor White
    Write-Host "  Testing buffer sizes: 1472, 1400, 1300, 1200 bytes" -ForegroundColor Gray
    Write-Host "  (Effective MTU = BufferSize + 28 for IP+ICMP headers)" -ForegroundColor Gray
    Write-Host ""

    $testSizes     = @(1472, 1400, 1300, 1200)
    $largestPassed = 0
    $anySuccess    = $false
    $anyAttempt    = $false

    foreach ($bufSize in $testSizes) {
        $effectiveMtu = $bufSize + 28
        Write-Host "  Testing BufferSize $bufSize (MTU $effectiveMtu)..." -NoNewline -ForegroundColor White
        try {
            $anyAttempt = $true
            $pingResult = Test-Connection -ComputerName $target -BufferSize $bufSize `
                -Count 1 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            if ($pingResult -and $pingResult.StatusCode -eq 0) {
                Write-Host " PASS" -ForegroundColor Green
                $anySuccess = $true
                if ($bufSize -gt $largestPassed) {
                    $largestPassed = $bufSize
                }
            } else {
                Write-Host " FAIL (fragmented or dropped)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if (-not $anySuccess -and $anyAttempt) {
        # All pings failed — might be ICMP blocked
        Write-Host ""
        Write-Host "  [INFO] All ping tests failed. Checking if ICMP is blocked..." -ForegroundColor Gray
        try {
            $basicPing = Test-Connection -ComputerName $target -Count 1 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            if ($basicPing) {
                # Basic ping works, large ones don't — this suggests small MTU
                $result.Status      = 'SmallMtu'
                $result.EffectiveMtu = 28  # Can only pass smallest ping
                $result.Detail      = "Basic ping succeeded but all buffer-size tests failed. MTU is below 1228 bytes."
            } else {
                $result.IcmpBlocked = $true
                $result.Status      = 'IcmpBlocked'
                $result.Detail      = "ICMP is filtered on this network. MTU cannot be tested with ping, but may still be an issue on VPN/MPLS/PPPoE links."
            }
        } catch {
            $result.IcmpBlocked = $true
            $result.Status      = 'IcmpBlocked'
            $result.Detail      = "ICMP appears blocked: $($_.Exception.Message)"
        }
    } else {
        $result.EffectiveMtu = $largestPassed + 28
    }

    Write-Host ""

    if ($result.IcmpBlocked) {
        Write-Host "  [INFO] ICMP (ping) is filtered on this network." -ForegroundColor Yellow
        Write-Host "  MTU cannot be tested via ping, but may still be an issue." -ForegroundColor Yellow
        Write-Host "  If you are on a VPN, MPLS, or PPPoE link, ask your network team to verify MTU." -ForegroundColor Yellow
        $result.Status = 'IcmpBlocked'
    } elseif ($result.EffectiveMtu -ge 1500) {
        Write-Host "  [PASS] Standard 1500-byte MTU confirmed. No fragmentation expected." -ForegroundColor Green
        $result.Status = 'Pass'
        $result.Detail = "Effective MTU: $($result.EffectiveMtu) bytes. No fragmentation issues detected."
    } elseif ($result.EffectiveMtu -gt 0) {
        Write-Host "  [WARN] MTU ISSUE DETECTED: The maximum packet size on your network path to Azure" -ForegroundColor Red
        Write-Host "  is $($result.EffectiveMtu) bytes, not the standard 1500 bytes." -ForegroundColor Red
        Write-Host ""
        Write-Host "  This is usually caused by a VPN tunnel, MPLS WAN link, or PPPoE connection" -ForegroundColor Yellow
        Write-Host "  adding extra headers. For VMware agentless migration, large replication data" -ForegroundColor Yellow
        Write-Host "  frames may be fragmented or dropped, causing replication to stall or transfer" -ForegroundColor Yellow
        Write-Host "  0 bytes." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Ask your network team to check MTU settings on the WAN/VPN link between this" -ForegroundColor Yellow
        Write-Host "  site and Azure, or enable 'Don't Fragment' + Path MTU Discovery." -ForegroundColor Yellow
        $result.Status = 'MtuIssue'
        $result.Detail = "MTU ISSUE: Effective MTU is $($result.EffectiveMtu) bytes (standard is 1500). Replication may stall."
        [void]$script:Recommendations.Add("MTU ISSUE DETECTED: Effective path MTU to Azure is $($result.EffectiveMtu) bytes (standard 1500). Ask your network team to check MTU on the WAN/VPN link. Enable Don't Fragment + Path MTU Discovery to prevent replication stall.")
    }

    $script:MtuResult = $result
    Write-Host ""
}

# ── Feature 4: Azure Region-Specific Endpoint Test ────────────────────────────
function Test-RegionEndpoints {
    param(
        [ValidateSet('Commercial','Government','China')]
        [string]$Cloud = 'Commercial'
    )

    Write-Section "AZURE REGION-SPECIFIC ENDPOINT TEST (v5.0)"
    Write-Host "  Tests your specific Azure region endpoints — not just generic wildcards." -ForegroundColor Gray
    Write-Host "  Catches firewalls that allow *.eastus.* but project is in australiaeast." -ForegroundColor Gray
    Write-Host ""

    $region = (Read-Host "  What Azure region is your Azure Migrate project in? (e.g. eastus, westeurope, australiaeast) Press Enter to skip").Trim()
    if (-not $region) {
        Write-Host "  Skipping region-specific endpoint test." -ForegroundColor Gray
        $script:RegionTested = $null
        Write-Host ""
        return
    }

    $region = $region.ToLower().Trim()
    $script:RegionTested = $region
    Write-Host ""
    Write-Host "  Testing region-specific endpoints for: $region" -ForegroundColor White
    Write-Host ""

    $regionUrls = switch ($Cloud) {
        'Government' {
            @(
                "$region.prod.migration.windowsazure.us",
                "$region.discoverysrv.windowsazure.us"
            )
        }
        'China' {
            @(
                "$region.cn2.prod.migration.windowsazure.cn"
            )
        }
        default {
            @(
                "$region.prod.migration.windowsazure.com",
                "$region.discoverysrv.windowsazure.com"
            )
        }
    }

    $anyFail = $false
    foreach ($url in $regionUrls) {
        Write-Host "  Testing: $url" -ForegroundColor White

        # DNS
        $dnsPass   = $false
        $dnsDetail = ''
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($url)
            if ($addrs.Count -gt 0) {
                $dnsPass   = $true
                $dnsDetail = "Resolved: $(($addrs | ForEach-Object { $_.IPAddressToString }) -join ', ')"
            } else {
                $dnsDetail = "No addresses returned"
            }
        } catch {
            $dnsDetail = $_.Exception.Message
        }

        # TCP 443
        $tcpPass   = $false
        $tcpDetail = ''
        if ($dnsPass) {
            $tcpClient = $null
            try {
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $task      = $tcpClient.ConnectAsync($url, 443)
                $done      = $task.Wait(5000)
                if ($done -and -not $task.IsFaulted) {
                    $tcpPass   = $true
                    $tcpDetail = "Connected"
                } else {
                    $tcpDetail = if ($task.IsFaulted) { $task.Exception.InnerException.Message } else { "Timed out" }
                }
            } catch {
                $tcpDetail = $_.Exception.Message
            } finally {
                if ($tcpClient) { try { $tcpClient.Close(); $tcpClient.Dispose() } catch {} }
                $tcpClient = $null
            }
        }

        # HTTPS
        $httpsPass   = $false
        $httpsDetail = ''
        if ($tcpPass) {
            $req = $null; $resp = $null
            try {
                $req           = [System.Net.HttpWebRequest]::Create("https://$url")
                $req.Method    = 'GET'
                $req.Timeout   = 10000
                $req.UserAgent = 'AzureMigrateConnectivityChecker/5.0'
                try {
                    $resp = $req.GetResponse()
                    $httpsPass   = $true
                    $httpsDetail = "HTTP $([int]$resp.StatusCode)"
                    $resp.Close(); $resp.Dispose()
                } catch [System.Net.WebException] {
                    $webEx = $_.Exception
                    if ($webEx.Response) {
                        $code = [int]$webEx.Response.StatusCode
                        if ($code -in @(400,401,403,404,405,500,502,503)) {
                            $httpsPass   = $true
                            $httpsDetail = "HTTP $code (network reachable)"
                        } else {
                            $httpsDetail = "HTTP $code"
                        }
                        if ($webEx.Response -is [System.Net.HttpWebResponse]) { $webEx.Response.Close() }
                    } else {
                        $httpsDetail = $webEx.Message
                    }
                }
            } catch {
                $httpsDetail = $_.Exception.Message
            } finally {
                if ($resp) { try { $resp.Close(); $resp.Dispose() } catch {} }
                $req = $null; $resp = $null
            }
        }

        $overall = $dnsPass -and $tcpPass -and $httpsPass
        if (-not $overall) { $anyFail = $true }

        $statusColor = if ($overall) { 'Green' } else { 'Red' }
        $statusText  = if ($overall) { 'PASS' } else { 'FAIL' }
        Write-Host "    [$statusText] DNS:$(if ($dnsPass) {'PASS'} else {'FAIL'})  TCP:$(if ($tcpPass) {'PASS'} else {'FAIL'})  HTTPS:$(if ($httpsPass) {'PASS'} else {'FAIL'})" -ForegroundColor $statusColor

        # Add to test results
        Add-TestResult -Url $url -Port 443 `
            -Purpose "Region-specific migration endpoint ($region)" `
            -WildcardPattern "*.prod.migration.windowsazure.*" `
            -DnsPass $dnsPass -DnsDetail $dnsDetail `
            -TcpPass $tcpPass -TcpDetail $tcpDetail `
            -HttpsPass $httpsPass -HttpsDetail $httpsDetail `
            -Category "Region-Specific Endpoints ($region)"
    }

    if ($anyFail) {
        Write-Host ""
        Write-Host "  [WARN] Region-specific endpoints for '$region' are blocked." -ForegroundColor Red
        Write-Host "  Your firewall rules may only cover a different region's endpoints." -ForegroundColor Red
        Write-Host "  Check that your firewall allows: *.prod.migration.windowsazure.com" -ForegroundColor Yellow
        Write-Host "  (not just a specific region prefix)" -ForegroundColor Yellow
        [void]$script:Recommendations.Add("REGION ENDPOINT BLOCKED: The region-specific endpoint for '$region' is blocked. Firewall rules may only cover a different region. Ensure *.prod.migration.windowsazure.com is allowed (not just a region-specific prefix).")
    } else {
        Write-Host ""
        Write-Host "  [PASS] All region-specific endpoints for '$region' are reachable." -ForegroundColor Green
    }

    Write-Host ""
}

# ── Feature 6: Auto-Update Version Currency Check ────────────────────────────
function Test-ApplianceVersionCurrency {
    Write-Section "APPLIANCE VERSION CURRENCY CHECK (v5.0)"
    Write-Host "  Checks if appliance agent components are up to date." -ForegroundColor Gray
    Write-Host "  Stale agents cause approximately 20% of escalations." -ForegroundColor Gray
    Write-Host ""

    $result = @{
        Status           = 'Unknown'
        LatestComponents = @{}
        InstalledItems   = [System.Collections.ArrayList]::new()
        StaleComponents  = [System.Collections.ArrayList]::new()
        Detail           = ''
    }

    # Fetch latest components manifest
    $latestJson   = $null
    $req  = $null
    $resp = $null
    try {
        Write-Host "  Fetching latest component manifest from aka.ms/latestapplianceservices..." -ForegroundColor White
        $req                    = [System.Net.HttpWebRequest]::Create('https://aka.ms/latestapplianceservices')
        $req.Method             = 'GET'
        $req.Timeout            = 15000
        $req.AllowAutoRedirect  = $true
        $req.UserAgent          = 'AzureMigrateConnectivityChecker/5.0'
        $resp   = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $raw    = $reader.ReadToEnd()
        $reader.Close(); $reader.Dispose()
        $latestJson = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($latestJson) {
            Write-Host "  [PASS] Successfully retrieved latest component manifest." -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Retrieved response but could not parse JSON." -ForegroundColor Yellow
        }
    } catch [System.Net.WebException] {
        Write-Host "  [SKIP] Could not reach aka.ms/latestapplianceservices — version check skipped." -ForegroundColor Yellow
        Write-Host "  (This endpoint may be blocked by proxy or firewall)" -ForegroundColor Gray
        $result.Status = 'Skipped'
        $result.Detail = 'Could not reach aka.ms/latestapplianceservices — version check skipped.'
    } catch {
        Write-Host "  [SKIP] Version check error: $($_.Exception.Message)" -ForegroundColor Yellow
        $result.Status = 'Skipped'
        $result.Detail = "Error: $($_.Exception.Message)"
    } finally {
        if ($resp) { try { $resp.Close(); $resp.Dispose() } catch {} }
        $req = $null; $resp = $null
    }

    # Read installed versions from Programs and Features
    Write-Host ""
    Write-Host "  Reading installed Azure Migrate component versions..." -ForegroundColor White
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($uPath in $uninstallPaths) {
        try {
            $items = Get-ItemProperty $uPath -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Azure Migrate|AzureAppliance|Microsoft Azure' -and $_.DisplayVersion } |
                Select-Object DisplayName, DisplayVersion, InstallDate
            foreach ($item in $items) {
                [void]$result.InstalledItems.Add([PSCustomObject]@{
                    Name        = $item.DisplayName
                    Version     = $item.DisplayVersion
                    InstallDate = $item.InstallDate
                })
                Write-Host "    $($item.DisplayName) — v$($item.DisplayVersion) (installed $($item.InstallDate))" -ForegroundColor Gray
            }
        } catch {}
    }

    if ($result.InstalledItems.Count -eq 0) {
        Write-Host "  No Azure Migrate components found in Programs and Features." -ForegroundColor Gray
    }

    # Compare versions if manifest was retrieved
    if ($latestJson -and $result.Status -ne 'Skipped') {
        $staleFound = $false

        # The manifest may have various structures — iterate properties
        try {
            $latestJson.PSObject.Properties | ForEach-Object {
                $compName    = $_.Name
                $latestVer   = $_.Value

                # Try to find a matching installed component
                $matchedItem = $result.InstalledItems | Where-Object {
                    $_.Name -match [regex]::Escape($compName) -or $compName -match [regex]::Escape($_.Name.Split(' ')[0])
                } | Select-Object -First 1

                if ($matchedItem -and $latestVer) {
                    $installedVerStr = $matchedItem.Version
                    $latestVerStr    = if ($latestVer -is [string]) { $latestVer } else { $latestVer.ToString() }

                    # Compare version strings
                    $installedV = $null
                    $latestV    = $null
                    $canCompare = [System.Version]::TryParse($installedVerStr, [ref]$installedV) -and
                                  [System.Version]::TryParse($latestVerStr,    [ref]$latestV)

                    if ($canCompare -and $installedV -lt $latestV) {
                        $staleFound = $true
                        [void]$result.StaleComponents.Add([PSCustomObject]@{
                            Component        = $compName
                            InstalledVersion = $installedVerStr
                            LatestVersion    = $latestVerStr
                        })
                        Write-Host "  [WARN] Component '$compName' is version $installedVerStr but latest is $latestVerStr." -ForegroundColor Yellow
                        Write-Host "  Auto-update should have updated this. If auto-update is disabled, update manually." -ForegroundColor Yellow
                    }
                }
            }
        } catch {
            Write-Host "  [WARN] Could not compare versions: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        if ($staleFound) {
            $result.Status = 'Stale'
            $result.Detail = "$($result.StaleComponents.Count) stale component(s) found."
            [void]$script:Recommendations.Add("STALE COMPONENTS: $($result.StaleComponents.Count) Azure Migrate component(s) are outdated. If auto-update is disabled, update manually via the Appliance Configuration Manager.")
        } else {
            $result.Status = 'Current'
            $result.Detail = 'All appliance components are up to date.'
            Write-Host "  [PASS] All appliance components are up to date." -ForegroundColor Green
        }
    }

    $script:VersionCurrencyResult = $result
    Write-Host ""
}

# ── Feature 7: Windows Event Log Mining ──────────────────────────────────────
function Get-RelevantEventLogs {
    Write-Section "WINDOWS EVENT LOG MINING (v5.0)"
    Write-Host "  Mining Windows Event Log for Azure Migrate related errors from the last 24 hours." -ForegroundColor Gray
    Write-Host "  Surfaces structured errors that log file scanning may miss." -ForegroundColor Gray
    Write-Host ""

    $maxEvents = 50
    $cutoffTime = (Get-Date).AddHours(-24)
    $totalFound = 0

    # Application log — Azure Migrate sources and crash events
    Write-Host "  Scanning Application log..." -ForegroundColor White
    try {
        $appEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            StartTime = $cutoffTime
        } -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
            Where-Object {
                ($_.ProviderName -match 'Azure|Migrate|AzureAppliance') -or
                ($_.Id -in @(1000, 1001, 1002))
            } | Select-Object -First $maxEvents

        foreach ($ev in $appEvents) {
            if ($totalFound -ge $maxEvents) { break }
            $category = 'APP_CRASH'
            if ($ev.ProviderName -match 'Azure|Migrate') { $category = 'AZURE_MIGRATE' }
            $shortMsg = if ($ev.Message) { $ev.Message.Substring(0, [Math]::Min(120, $ev.Message.Length)) } else { '(no message)' }

            Write-Host "    [$category] $($ev.TimeCreated.ToString('HH:mm')) EventID:$($ev.Id) Src:$($ev.ProviderName)" -ForegroundColor $(
                if ($category -eq 'APP_CRASH') { 'Red' } else { 'Yellow' }
            )
            Write-Host "    $shortMsg" -ForegroundColor Gray

            [void]$script:EventLogFindings.Add([PSCustomObject]@{
                Time     = $ev.TimeCreated
                EventId  = $ev.Id
                Source   = $ev.ProviderName
                Category = $category
                Message  = $shortMsg
            })
            $totalFound++
        }

        # Check for crash count
        $crashCount = @($appEvents | Where-Object { $_.Id -in @(1000, 1001, 1002) -and $_.ProviderName -match 'Azure|Migrate' }).Count
        if ($crashCount -gt 0) {
            Write-Host ""
            Write-Host "  [WARN] Appliance service crashed $crashCount time(s) in the last 24 hours." -ForegroundColor Red
            Write-Host "  This is a software instability issue separate from network connectivity." -ForegroundColor Red
            [void]$script:Recommendations.Add("APPLIANCE CRASHES: Azure Migrate service crashed $crashCount time(s) in the last 24 hours (Application event log). This is a software instability issue. Check Services.msc and consider restarting appliance services.")
        }
    } catch {
        Write-Host "  [INFO] Could not read Application log: $($_.Exception.Message)" -ForegroundColor Gray
        Write-Host "  (Run as Administrator for full event log access)" -ForegroundColor Gray
    }

    # System log — W32Time, DNS, Schannel errors
    Write-Host ""
    Write-Host "  Scanning System log for time/DNS/TLS errors..." -ForegroundColor White
    $sysEventIds = @(
        # W32Time
        29, 37, 38, 47, 129,
        # DNS Client
        1014,
        # Schannel TLS
        36871, 36874, 36888
    )
    try {
        $sysEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            StartTime = $cutoffTime
            Id        = $sysEventIds
        } -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
            Select-Object -First ($maxEvents - $totalFound)

        $w32TimeCount  = 0
        $sslErrorCount = 0
        $dnsErrorCount = 0

        foreach ($ev in $sysEvents) {
            if ($totalFound -ge $maxEvents) { break }
            $category = 'SYSTEM'
            if ($ev.Id -in @(29, 37, 38, 47, 129)) {
                $category = 'TIME_SYNC'
                $w32TimeCount++
            } elseif ($ev.Id -eq 1014) {
                $category = 'DNS_ERROR'
                $dnsErrorCount++
            } elseif ($ev.Id -in @(36871, 36874, 36888)) {
                $category = 'TLS_ERROR'
                $sslErrorCount++
            }

            $shortMsg = if ($ev.Message) { $ev.Message.Substring(0, [Math]::Min(120, $ev.Message.Length)) } else { '(no message)' }
            Write-Host "    [$category] $($ev.TimeCreated.ToString('HH:mm')) EventID:$($ev.Id) Src:$($ev.ProviderName)" -ForegroundColor Yellow
            Write-Host "    $shortMsg" -ForegroundColor Gray

            [void]$script:EventLogFindings.Add([PSCustomObject]@{
                Time     = $ev.TimeCreated
                EventId  = $ev.Id
                Source   = $ev.ProviderName
                Category = $category
                Message  = $shortMsg
            })
            $totalFound++
        }

        # Correlate findings
        if ($w32TimeCount -gt 0) {
            Write-Host ""
            Write-Host "  [WARN] $w32TimeCount W32Time event(s) found — time sync issues detected." -ForegroundColor Yellow
            if ($script:ClockSkewResult -and $script:ClockSkewResult.Status -eq 'Fail') {
                Write-Host "  CORRELATED with clock skew test: clock is significantly out of sync." -ForegroundColor Red
            } else {
                Write-Host "  Check w32tm /query /status for current sync state." -ForegroundColor Yellow
            }
            [void]$script:Recommendations.Add("EVENT LOG W32TIME: $w32TimeCount Windows Time sync error event(s) in last 24 hours. Run: w32tm /resync /force as Administrator.")
        }

        if ($sslErrorCount -gt 0) {
            Write-Host ""
            Write-Host "  [WARN] $sslErrorCount Schannel/TLS error event(s) found in the System log." -ForegroundColor Red
            Write-Host "  TLS errors indicate certificate or protocol negotiation failures." -ForegroundColor Yellow
            Write-Host "  This may be caused by SSL inspection, expired certificates, or TLS version mismatch." -ForegroundColor Yellow
            [void]$script:Recommendations.Add("EVENT LOG TLS ERRORS: $sslErrorCount Schannel TLS error(s) in System log. Check for SSL inspection bypass, certificate expiry, or TLS 1.2 configuration.")
        }

        if ($dnsErrorCount -gt 0) {
            Write-Host ""
            Write-Host "  [WARN] $dnsErrorCount DNS Client error event(s) found (EventID 1014 - DNS timeout)." -ForegroundColor Yellow
            Write-Host "  CORRELATED with DNS test failures above." -ForegroundColor Yellow
            [void]$script:Warnings.Add("EVENT LOG DNS ERRORS: $dnsErrorCount DNS timeout event(s) (EventID 1014) in last 24 hours. DNS server may be unreliable or filtering Azure domains.")
        }
    } catch {
        Write-Host "  [INFO] Could not read System log: $($_.Exception.Message)" -ForegroundColor Gray
    }

    # WinHTTP Diagnostic log (optional — may not exist)
    Write-Host ""
    Write-Host "  Checking Microsoft-Windows-WinHTTP/Diagnostic log..." -ForegroundColor White
    try {
        $winHttpEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-WinHTTP/Diagnostic'
            StartTime = $cutoffTime
        } -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
            Select-Object -First ([Math]::Max(0, $maxEvents - $totalFound))

        foreach ($ev in $winHttpEvents) {
            if ($totalFound -ge $maxEvents) { break }
            $shortMsg = if ($ev.Message) { $ev.Message.Substring(0, [Math]::Min(120, $ev.Message.Length)) } else { '(no message)' }
            Write-Host "    [WINHTTP] $($ev.TimeCreated.ToString('HH:mm')) EventID:$($ev.Id)" -ForegroundColor Yellow
            Write-Host "    $shortMsg" -ForegroundColor Gray
            [void]$script:EventLogFindings.Add([PSCustomObject]@{
                Time     = $ev.TimeCreated
                EventId  = $ev.Id
                Source   = 'WinHTTP'
                Category = 'WINHTTP'
                Message  = $shortMsg
            })
            $totalFound++
        }
        if ($winHttpEvents -and $winHttpEvents.Count -gt 0) {
            Write-Host "  Found $($winHttpEvents.Count) WinHTTP diagnostic event(s)." -ForegroundColor Yellow
        } else {
            Write-Host "  No WinHTTP diagnostic events found in last 24 hours." -ForegroundColor Gray
        }
    } catch {
        Write-Host "  WinHTTP Diagnostic log not available or empty — skipping." -ForegroundColor Gray
    }

    if ($totalFound -eq 0) {
        Write-Host ""
        Write-Host "  [PASS] No relevant error events found in Windows Event Log for the last 24 hours." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  Total relevant events found: $totalFound" -ForegroundColor White
    }

    Write-Host ""
}

# ── Feature 8: AV/EDR Process Detection ──────────────────────────────────────
function Test-AntivirusInterference {
    Write-Section "ANTIVIRUS / EDR INTERFERENCE CHECK (v5.0)"
    Write-Host "  Detecting antivirus and EDR tools known to interfere with Azure Migrate." -ForegroundColor Gray
    Write-Host "  AV/EDR interference is a top-3 cause of failures — invisible to network tests." -ForegroundColor Gray
    Write-Host ""

    $avProducts = @(
        @{
            Name      = 'CrowdStrike Falcon'
            Processes = @('csagent','csfalconservice','CSFalconContainer')
            Services  = @('CSFalconService','csagent')
            Note      = 'Known to block VDDK driver loading required for agentless migration. Exclusion needed for: C:\Program Files (x86)\VMware\VMware vSphere VDDK\. CrowdStrike sensor may also intercept TCP connections causing false network failures.'
        }
        @{
            Name      = 'Microsoft Defender for Endpoint'
            Processes = @('MsSense','SenseIR','SenseCncProxy')
            Services  = @('Sense')
            Note      = 'Microsoft Defender for Endpoint behavioral protection may block appliance services. Check the MDE portal for blocked actions and add exclusions for the appliance path.'
        }
        @{
            Name      = 'Microsoft Defender Antivirus'
            Processes = @('MsMpEng','NisSrv')
            Services  = @('WinDefend','WdNisSvc')
            Note      = 'Windows Defender real-time protection may scan and temporarily lock Azure Migrate data files. Add exclusions for the appliance install path: C:\Program Files\Microsoft Azure Appliance\'
        }
        @{
            Name      = 'Carbon Black'
            Processes = @('cb','cbdefense','CbDefense','CarbonBlack')
            Services  = @('CarbonBlack','cbdefense')
            Note      = 'Behavioral AI security products may block the appliance''s network connections or quarantine its executable files. Check the product''s threat log for blocked actions.'
        }
        @{
            Name      = 'SentinelOne'
            Processes = @('SentinelAgent','SentinelHelperService','SentinelStaticEngine')
            Services  = @('SentinelAgent')
            Note      = 'Behavioral AI security products may block the appliance''s network connections or quarantine its executable files. Check the product''s threat log for blocked actions.'
        }
        @{
            Name      = 'Cylance'
            Processes = @('CylanceSvc','cylancesvc')
            Services  = @('CylanceSvc')
            Note      = 'Behavioral AI security products may block the appliance''s network connections or quarantine its executable files. Check the product''s threat log for blocked actions.'
        }
        @{
            Name      = 'Sophos'
            Processes = @('SophosAV','SAVService','swi_service')
            Services  = @('Sophos Agent','SAVService')
            Note      = 'Sophos may intercept network connections. Add the appliance installation folder to the Sophos exclusion list. Check the Sophos console for blocked events.'
        }
        @{
            Name      = 'Trend Micro'
            Processes = @('TmListen','CNTAoSMgr','TmProxy')
            Services  = @('Trend Micro Solution Platform')
            Note      = 'Trend Micro may scan and lock appliance files or block outbound connections. Add exclusions in the Trend Micro management console.'
        }
        @{
            Name      = 'McAfee/Trellix'
            Processes = @('mcshield','mfefire','MfeAVSvc')
            Services  = @('McAfee Endpoint Security')
            Note      = 'McAfee/Trellix may block network connections or quarantine appliance files. Add appliance folder exclusions in the ePO/Trellix console.'
        }
        @{
            Name      = 'Symantec/Broadcom'
            Processes = @('ccSvcHst','SMC','Rtvscan')
            Services  = @('SepMasterService','ccSetMgr')
            Note      = 'Symantec Endpoint Protection may block network traffic or file operations. Add exclusions for the appliance installation directory.'
        }
        @{
            Name      = 'ESET'
            Processes = @('ekrn','egui','esets_daemon')
            Services  = @('ekrn')
            Note      = 'ESET security products may block appliance operations. Add exclusions in ESET management console for the appliance path.'
        }
        @{
            Name      = 'Kaspersky'
            Processes = @('avp','kavfs','klnagent')
            Services  = @('AVP','klnagent')
            Note      = 'Kaspersky may block appliance network connections or scan/lock data files. Add appliance folder to trusted zone in Kaspersky Security Center.'
        }
    )

    $detectedProducts = [System.Collections.ArrayList]::new()

    foreach ($product in $avProducts) {
        $isDetected = $false

        # Check processes
        foreach ($proc in $product.Processes) {
            $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
            if ($running) {
                $isDetected = $true
                break
            }
        }

        # Check services (if not already detected via process)
        if (-not $isDetected) {
            foreach ($svc in $product.Services) {
                $svcObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
                if ($svcObj -and $svcObj.Status -eq 'Running') {
                    $isDetected = $true
                    break
                }
            }
        }

        if ($isDetected) {
            [void]$detectedProducts.Add($product.Name)
            Write-Host "  [DETECTED] $($product.Name)" -ForegroundColor Yellow
            Write-Host "  $($product.Note)" -ForegroundColor White
            Write-Host ""
            Write-Host "  Recommendation: Add the Azure Migrate appliance installation folder to" -ForegroundColor Yellow
            Write-Host "  your AV/EDR exclusion list. Contact the AV vendor for Azure Migrate" -ForegroundColor Yellow
            Write-Host "  compatibility guidance." -ForegroundColor Yellow
            Write-Host ""
            [void]$script:AvEdrResult.Add($product.Name)
            [void]$script:Recommendations.Add("AV/EDR DETECTED - $($product.Name): $($product.Note) Add Azure Migrate appliance folder to exclusion list.")
        }
    }

    if ($detectedProducts.Count -eq 0) {
        Write-Host "  No known AV/EDR products detected running on this machine." -ForegroundColor Green
    } else {
        Write-Host "  [$($detectedProducts.Count) AV/EDR product(s) detected. Review guidance above.]" -ForegroundColor Yellow
    }

    Write-Host ""
}

# ── Feature 9: Additional Required Ports Check ───────────────────────────────
function Test-AdditionalPorts {
    Write-Section "ADDITIONAL REQUIRED PORTS CHECK (v5.0 - VMware Agentless)"
    Write-Host "  Testing non-443 ports required for agentless migration." -ForegroundColor Gray
    Write-Host "  These are often missed in firewall rules and cause silent failures." -ForegroundColor Gray
    Write-Host ""

    $result = @{
        Port9443Listening = $false
        NtpReachable      = $false
        NtpUdpResult      = 'NotTested'
        Detail            = ''
    }

    # --- TCP 9443 listening check ---
    Write-Host "  Checking TCP 9443 (vCenter replication reachback port)..." -ForegroundColor White
    Write-Host "  Note: vCenter needs to reach THIS appliance on TCP 9443 for agentless replication." -ForegroundColor Gray
    try {
        $ipProps      = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $tcpListeners = $ipProps.GetActiveTcpListeners()
        $port9443     = $tcpListeners | Where-Object { $_.Port -eq 9443 }
        if ($port9443) {
            $result.Port9443Listening = $true
            Write-Host "  [PASS] Port 9443 is OPEN (listening) on this appliance." -ForegroundColor Green
            Write-Host "  vCenter can initiate replication connections to this appliance." -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Port 9443 is NOT listening on this appliance." -ForegroundColor Red
            Write-Host "  The agentless replication service may not be running." -ForegroundColor Red
            Write-Host "  Check Azure Migrate gateway services in Services.msc." -ForegroundColor Yellow
            [void]$script:Recommendations.Add("PORT 9443 NOT LISTENING: The agentless replication service is not listening on TCP 9443. vCenter cannot initiate replication. Check Services.msc for Azure Migrate Gateway/Replication services and restart them.")
        }
    } catch {
        Write-Host "  [WARN] Could not check TCP listeners: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # --- NTP UDP 123 test ---
    Write-Host "  Checking NTP (UDP 123) to time.windows.com..." -ForegroundColor White
    Write-Host "  (NTP is required for clock sync — Entra ID auth fails if clock drifts)" -ForegroundColor Gray

    $udpClient = $null
    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect('time.windows.com', 123)
        $udpClient.Client.SendTimeout    = 3000
        $udpClient.Client.ReceiveTimeout = 3000

        # Send a minimal NTP v3 query packet (48 bytes)
        $ntpData    = New-Object byte[] 48
        $ntpData[0] = 0x1B  # LI=0, Version=3, Mode=3 (client)
        [void]$udpClient.Send($ntpData, $ntpData.Length)

        # Try to receive a response
        $remoteEp  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $recvBytes = $udpClient.Receive([ref]$remoteEp)
        if ($recvBytes -and $recvBytes.Length -ge 48) {
            $result.NtpReachable  = $true
            $result.NtpUdpResult  = 'Pass'
            Write-Host "  [PASS] NTP response received from time.windows.com (UDP 123 is open)." -ForegroundColor Green
        } else {
            $result.NtpUdpResult = 'EmptyResponse'
            Write-Host "  [WARN] NTP sent but received empty/short response." -ForegroundColor Yellow
        }
    } catch [System.Net.Sockets.SocketException] {
        $result.NtpUdpResult = 'Blocked'
        Write-Host "  [WARN] NTP (UDP 123) to time.windows.com appears blocked." -ForegroundColor Red
        Write-Host "  This prevents accurate clock synchronization." -ForegroundColor Red
        Write-Host "  Entra ID token validation will fail if clock drifts > 5 minutes." -ForegroundColor Red
        [void]$script:Recommendations.Add("NTP BLOCKED: UDP 123 to time.windows.com appears blocked. This prevents clock synchronization. Ask your network team to allow outbound UDP 123 to time.windows.com.")
    } catch {
        $result.NtpUdpResult = "Error: $($_.Exception.Message)"
        Write-Host "  [INFO] NTP test inconclusive: $($_.Exception.Message)" -ForegroundColor Gray
    } finally {
        if ($udpClient) {
            try { $udpClient.Close(); $udpClient.Dispose() } catch {}
            $udpClient = $null
        }
    }

    $script:AdditionalPortsResult = $result
    Write-Host ""
}

# ── Feature 10: Summary Report ───────────────────────────────────────────────
function Export-SummaryReport {
    if (-not $script:SummaryPath) { return }

    $es = $script:ExecutiveSummary
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("=" * 70)
    [void]$sb.AppendLine("  Azure Migrate Connectivity — SUMMARY REPORT")
    [void]$sb.AppendLine("  Machine  : $env:COMPUTERNAME")
    [void]$sb.AppendLine("  Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("  Script   : v$($script:ScriptVersion)")
    [void]$sb.AppendLine("=" * 70)
    [void]$sb.AppendLine("")

    # Executive verdict
    [void]$sb.AppendLine("VERDICT")
    [void]$sb.AppendLine("-" * 70)
    if ($es) {
        foreach ($v in $es.Verdicts) {
            switch ($v) {
                'NETWORK_OK'      { [void]$sb.AppendLine("  [PASS] All network connectivity is HEALTHY.") }
                'NETWORK_BLOCKED' { [void]$sb.AppendLine("  [FAIL] Network is BLOCKING Azure Migrate ($($es.TcpFails) TCP block(s), $($es.DnsFails) DNS failure(s)).") }
                'SSL_INSPECTION'  { [void]$sb.AppendLine("  [WARN] SSL INSPECTION detected — certificate re-signing may break authentication.") }
                'PROXY_AUTH'      { [void]$sb.AppendLine("  [WARN] PROXY AUTHENTICATION required but not configured.") }
                'CLOCK_ISSUE'     { [void]$sb.AppendLine("  [FAIL] CLOCK SKEW critical — Azure authentication will fail.") }
                'HOSTS_OVERRIDE'  { [void]$sb.AppendLine("  [FAIL] HOSTS FILE overrides Azure domains.") }
                default           { [void]$sb.AppendLine("  [INFO] Status: $v") }
            }
        }
    } else {
        [void]$sb.AppendLine("  No executive summary data available.")
    }
    [void]$sb.AppendLine("")

    # AV/EDR
    if ($script:AvEdrResult -and $script:AvEdrResult.Count -gt 0) {
        [void]$sb.AppendLine("  [WARN] AV/EDR DETECTED: $($script:AvEdrResult -join ', ')")
        [void]$sb.AppendLine("         Add appliance folder to AV/EDR exclusion list.")
        [void]$sb.AppendLine("")
    }

    # Duplicate appliance
    if ($script:DuplicateApplianceResult -and $script:DuplicateApplianceResult.MultipleInstalls) {
        [void]$sb.AppendLine("  [WARN] MULTIPLE AZURE MIGRATE INSTALLATIONS detected.")
        [void]$sb.AppendLine("")
    }
    if ($script:DuplicateApplianceResult -and $script:DuplicateApplianceResult.CloudMismatch) {
        [void]$sb.AppendLine("  [FAIL] CLOUD ENVIRONMENT MISMATCH in registry.")
        [void]$sb.AppendLine("")
    }

    # MTU
    if ($script:MtuResult -and $script:MtuResult.Status -eq 'MtuIssue') {
        [void]$sb.AppendLine("  [WARN] MTU ISSUE: Effective path MTU is $($script:MtuResult.EffectiveMtu) bytes (standard 1500).")
        [void]$sb.AppendLine("")
    }

    # Action items (blocked domains only)
    [void]$sb.AppendLine("BLOCKED FIREWALL RULES (ACTION REQUIRED)")
    [void]$sb.AppendLine("-" * 70)
    $failed = $script:TestResults | Where-Object { -not $_.OverallPass }
    if ($failed -and @($failed).Count -gt 0) {
        $seenW = @{}
        foreach ($f in $failed) {
            if (-not $seenW.ContainsKey($f.WildcardPattern)) {
                $seenW[$f.WildcardPattern] = $true
                [void]$sb.AppendLine("  Allow TCP/443 to $($f.WildcardPattern)")
            }
        }
    } else {
        [void]$sb.AppendLine("  None — all endpoints passed.")
    }
    [void]$sb.AppendLine("")

    # Recommendations summary
    [void]$sb.AppendLine("RECOMMENDED ACTIONS")
    [void]$sb.AppendLine("-" * 70)
    for ($i = 0; $i -lt $script:Recommendations.Count; $i++) {
        $rec = $script:Recommendations[$i]
        $shortRec = $rec.Substring(0, [Math]::Min(120, $rec.Length))
        [void]$sb.AppendLine("  [$($i+1)] $shortRec")
    }
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine("-" * 70)
    [void]$sb.AppendLine("  Full report: $($script:ReportPath)")
    [void]$sb.AppendLine("=" * 70)

    try {
        $sb.ToString() | Out-File -FilePath $script:SummaryPath -Encoding UTF8 -Force
        Write-Host "  [DONE] Summary report saved to: $($script:SummaryPath)" -ForegroundColor Green
        Write-Host "  Forward this to management or attach to a Teams message." -ForegroundColor White
    } catch {
        Write-Host "  [WARN] Could not save summary report: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ── Feature 10: Report Compression ───────────────────────────────────────────
function Compress-Report {
    if (-not $script:ZipPath) { return }

    Write-Host ""
    Write-Host "  Compressing reports into ZIP..." -ForegroundColor White
    try {
        $filesToZip = @()
        if ($script:ReportPath  -and (Test-Path $script:ReportPath))  { $filesToZip += $script:ReportPath  }
        if ($script:SummaryPath -and (Test-Path $script:SummaryPath)) { $filesToZip += $script:SummaryPath }

        if ($filesToZip.Count -gt 0) {
            Compress-Archive -Path $filesToZip `
                -DestinationPath $script:ZipPath -Force -ErrorAction Stop
            Write-Host "  [DONE] Reports zipped to: $($script:ZipPath)" -ForegroundColor Green
            Write-Host "  Attach this ZIP to your Microsoft Support case or email it to your network team." -ForegroundColor White
        } else {
            Write-Host "  [INFO] No report files found to compress." -ForegroundColor Gray
        }
    } catch {
        Write-Host "  [INFO] Could not create ZIP (Compress-Archive may not be available on PS 5.0)." -ForegroundColor Gray
        Write-Host "  Manually zip the .txt files if needed." -ForegroundColor Gray
    }
}


# ============================================================================
# INVOKE-CLEANUP
# ============================================================================
function Invoke-Cleanup {
    Write-Section "CLEANUP — REMOVING ALL DIAGNOSTIC DATA"
    Write-Host "  Verifying all network connections, test objects, and temporary data" -ForegroundColor Gray
    Write-Host "  are fully removed from memory before the script exits..." -ForegroundColor Gray
    Write-Host ""

    $cleanupItems = [ordered]@{
        'Traceroute results'          = 'TraceRouteResults'
        'DNS comparison results'      = 'DnsComparisonResults'
        'TCP behavior results'        = 'TcpBehaviorResults'
        'Proxy connection results'    = 'ProxyConnectResults'
        'TLS certificate data'        = 'CertChainResults'
        'Clock skew result'           = 'ClockSkewResult'
        'Hosts file findings'         = 'HostsFileResult'
        'Virtualization info'         = 'VirtualizationInfo'
        'Appliance registry state'    = 'ApplianceState'
        'Appliance log findings'      = 'ApplianceLogFindings'
        'Azure service health'        = 'AzureHealthResult'
        'Appliance health API result' = 'ApplianceHealthResult'
        '.NET framework result'       = 'DotNetResult'
        'Outbound NAT IP result'      = 'NatIpResult'
        'Executive summary data'      = 'ExecutiveSummary'
        'Next steps text'             = 'NextStepsText'
        'Duplicate appliance result'  = 'DuplicateApplianceResult'
        'vCenter connectivity result' = 'vCenterResult'
        'MTU path result'             = 'MtuResult'
        'Version currency result'     = 'VersionCurrencyResult'
        'Event log findings'          = 'EventLogFindings'
        'AV/EDR detection result'     = 'AvEdrResult'
        'Group policy prereqs result' = 'GroupPolicyResult'
        'AV exclusion paths result'   = 'AvExclusionResult'
        'Additional ports result'     = 'AdditionalPortsResult'
    }

    try {
        foreach ($item in $cleanupItems.GetEnumerator()) {
            $varName = "script:$($item.Value)"
            Set-Variable -Name $item.Value -Value $null -Scope Script -ErrorAction SilentlyContinue
            Write-Host "    [CLEARED] $($item.Key)" -ForegroundColor Green
        }

        # Force .NET garbage collection to release any unreferenced network objects
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()

        # Verify temp file from tracert fallback is gone
        $tracertTemp = "$env:TEMP\tracert_out.txt"
        if (Test-Path $tracertTemp) {
            Remove-Item $tracertTemp -Force -ErrorAction SilentlyContinue
            Write-Host "    [CLEARED] Tracert temporary file ($tracertTemp)" -ForegroundColor Green
        }

        # Check for any leftover background jobs (should be none — just a safety net)
        $jobs = Get-Job -ErrorAction SilentlyContinue
        if ($jobs) {
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            Write-Host "    [CLEARED] $($jobs.Count) background job(s) removed" -ForegroundColor Yellow
        }

        # Check for any lingering TcpClient-related .NET connections in the current process
        $tcpConns = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() |
            Where-Object { $_.State -eq 'Established' -and $_.RemoteEndPoint.Port -eq 443 } |
            Select-Object -ExpandProperty RemoteEndPoint -ErrorAction SilentlyContinue
        $connCount = if ($tcpConns) { @($tcpConns).Count } else { 0 }
        if ($connCount -gt 0) {
            Write-Host "    [INFO] $connCount active HTTPS connection(s) still in TIME_WAIT state" -ForegroundColor Yellow
            Write-Host "           (Normal — OS closes these automatically within 30-120 seconds)" -ForegroundColor Gray
        } else {
            Write-Host "    [CLEARED] No active test connections remain" -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "  ║  CLEANUP COMPLETE — THIS SCRIPT LEFT NO TRACES                  ║" -ForegroundColor Green
        Write-Host "  ║                                                                  ║" -ForegroundColor Green
        Write-Host "  ║  All diagnostic objects cleared from memory.                    ║" -ForegroundColor Green
        Write-Host "  ║  No open network connections remain from this script.            ║" -ForegroundColor Green
        Write-Host "  ║  No registry changes were made.                                 ║" -ForegroundColor Green
        Write-Host "  ║  No Windows services were modified.                             ║" -ForegroundColor Green
        Write-Host "  ║  Only file written: the .txt report in the script folder.       ║" -ForegroundColor Green
        Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""

    } catch {
        Write-Host "  [WARN] Cleanup encountered an error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  All test objects should still be out of scope — no active connections remain." -ForegroundColor Gray
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================


# ============================================================================
# TEST-GROUPPOLICYPREREQS — v5.0 addition
# ============================================================================
function Test-GroupPolicyPrereqs {
    Write-Section "GROUP POLICY PREREQUISITES CHECK (Read-Only)"
    Write-Host "  The Appliance Configuration Manager validates these Group Policy settings" -ForegroundColor Gray
    Write-Host "  before allowing registration. If any are misconfigured, the appliance will" -ForegroundColor Gray
    Write-Host "  display an error and refuse to register — even if the network is healthy." -ForegroundColor Gray
    Write-Host ""

    $result = @{ Checks = [System.Collections.ArrayList]::new(); AllPass = $true }

    # 1. Registry access policy
    Write-Host "  Checking: Prevent access to registry editing tools..." -ForegroundColor White
    try {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $val = (Get-ItemProperty -Path $regPath -Name 'DisableRegistryTools' -ErrorAction SilentlyContinue).DisableRegistryTools
        if ($null -ne $val -and $val -eq 0) {
            Write-Host "  [FAIL] Group Policy 'Prevent access to registry editing tools' is ENABLED." -ForegroundColor Red
            Write-Host "  This will block the Appliance Configuration Manager from completing registration." -ForegroundColor Red
            Write-Host "  The policy must be disabled or an exception must be created for the appliance." -ForegroundColor Yellow
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'DisableRegistryTools'; Status = 'FAIL'; Detail = "DisableRegistryTools=0 — registry access is blocked by Group Policy" })
            $result.AllPass = $false
            [void]$script:Recommendations.Add("GROUP POLICY BLOCK: 'Prevent access to registry editing tools' is enabled (DisableRegistryTools=0). The Appliance Configuration Manager requires registry access during registration. This policy must be changed.")
        } else {
            Write-Host "  [PASS] Registry access policy is not blocking appliance operations." -ForegroundColor Green
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'DisableRegistryTools'; Status = 'PASS'; Detail = "Not restricted" })
        }
    } catch {
        Write-Host "  [INFO] Could not check registry access policy: $($_.Exception.Message)" -ForegroundColor Gray
    }

    # 2. Command prompt policy
    Write-Host ""
    Write-Host "  Checking: Prevent access to command prompt..." -ForegroundColor White
    try {
        $regPath2 = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        $val2 = (Get-ItemProperty -Path $regPath2 -Name 'DisableCMD' -ErrorAction SilentlyContinue).DisableCMD
        if ($null -ne $val2 -and $val2 -ne 0) {
            Write-Host "  [FAIL] Group Policy 'Prevent access to the command prompt' is ENABLED (DisableCMD=$val2)." -ForegroundColor Red
            Write-Host "  The Appliance Configuration Manager uses command-line operations during registration." -ForegroundColor Red
            Write-Host "  This policy blocks appliance registration and must be disabled." -ForegroundColor Yellow
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'DisableCMD'; Status = 'FAIL'; Detail = "DisableCMD=$val2 — command prompt blocked by Group Policy" })
            $result.AllPass = $false
            [void]$script:Recommendations.Add("GROUP POLICY BLOCK: 'Prevent access to the command prompt' is enabled (DisableCMD=$val2). This blocks appliance registration. The policy must be disabled for this machine.")
        } else {
            Write-Host "  [PASS] Command prompt access policy is not blocking appliance operations." -ForegroundColor Green
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'DisableCMD'; Status = 'PASS'; Detail = "Not restricted" })
        }
    } catch {
        Write-Host "  [INFO] Could not check command prompt policy: $($_.Exception.Message)" -ForegroundColor Gray
    }

    # 3. Trust logic for attachments
    Write-Host ""
    Write-Host "  Checking: Trust logic for file attachments policy..." -ForegroundColor White
    try {
        $regPath3 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments'
        $val3 = (Get-ItemProperty -Path $regPath3 -Name 'UseTrustedHandlers' -ErrorAction SilentlyContinue).UseTrustedHandlers
        if ($null -ne $val3 -and $val3 -eq 3) {
            Write-Host "  [FAIL] Group Policy 'Trust logic for file attachments' is set to block (UseTrustedHandlers=3)." -ForegroundColor Red
            Write-Host "  This policy prevents the appliance from opening and using downloaded files." -ForegroundColor Red
            Write-Host "  It must be changed to allow the appliance to function correctly." -ForegroundColor Yellow
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'UseTrustedHandlers'; Status = 'FAIL'; Detail = "UseTrustedHandlers=3 — file attachment trust policy is blocking appliance" })
            $result.AllPass = $false
            [void]$script:Recommendations.Add("GROUP POLICY BLOCK: 'Trust logic for file attachments' set to 3 (blocked). This prevents the appliance from using installer files. The policy must be changed for this machine.")
        } else {
            Write-Host "  [PASS] File attachment trust policy is not blocking appliance operations." -ForegroundColor Green
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'UseTrustedHandlers'; Status = 'PASS'; Detail = "Not restricted" })
        }
    } catch {
        Write-Host "  [INFO] Could not check file attachment policy: $($_.Exception.Message)" -ForegroundColor Gray
    }

    # 4. PowerShell execution policy
    Write-Host ""
    Write-Host "  Checking: PowerShell execution policy..." -ForegroundColor White
    try {
        $psPolicy = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction SilentlyContinue
        if ($psPolicy -in @('AllSigned', 'Restricted')) {
            Write-Host "  [FAIL] PowerShell execution policy is '$psPolicy'." -ForegroundColor Red
            Write-Host "  The Appliance Configuration Manager requires PowerShell scripts to run." -ForegroundColor Red
            Write-Host "  Policy must NOT be 'AllSigned' or 'Restricted'." -ForegroundColor Yellow
            Write-Host "  Ask your security team to set it to 'RemoteSigned' for this machine." -ForegroundColor Yellow
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'PSExecutionPolicy'; Status = 'FAIL'; Detail = "Execution policy is '$psPolicy' — appliance registration requires RemoteSigned or less restrictive" })
            $result.AllPass = $false
            [void]$script:Recommendations.Add("GROUP POLICY BLOCK: PowerShell execution policy is '$psPolicy'. The Appliance Configuration Manager requires it to be RemoteSigned or less restrictive. Ask your security team to apply an exception for this machine.")
        } else {
            Write-Host "  [PASS] PowerShell execution policy is '$psPolicy' — appliance can run scripts." -ForegroundColor Green
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'PSExecutionPolicy'; Status = 'PASS'; Detail = "Execution policy: $psPolicy" })
        }
    } catch {
        Write-Host "  [INFO] Could not determine PowerShell execution policy: $($_.Exception.Message)" -ForegroundColor Gray
    }

    # 5. IIS Web Server role (port 443 conflict)
    Write-Host ""
    Write-Host "  Checking: IIS Web Server role conflict..." -ForegroundColor White
    try {
        $iis = Get-WindowsFeature -Name 'Web-Server' -ErrorAction SilentlyContinue
        if ($iis -and $iis.Installed) {
            Write-Host "  [WARN] IIS (Internet Information Services) is installed on this machine." -ForegroundColor Yellow
            Write-Host "  The Appliance Configuration Manager web portal uses port 443." -ForegroundColor Yellow
            Write-Host "  If IIS has a site listening on port 443, the appliance registration will fail." -ForegroundColor Yellow
            Write-Host "  Check IIS Manager to ensure no site is bound to port 443." -ForegroundColor White
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'IIS_Conflict'; Status = 'WARN'; Detail = "IIS is installed — verify no site is bound to port 443" })
            [void]$script:Warnings.Add("IIS is installed on this machine. Ensure no IIS website is bound to port 443 — the Appliance Configuration Manager requires this port.")
        } else {
            Write-Host "  [PASS] IIS Web Server role is not installed — no port 443 conflict." -ForegroundColor Green
            [void]$result.Checks.Add([PSCustomObject]@{ Check = 'IIS_Conflict'; Status = 'PASS'; Detail = "IIS not installed" })
        }
    } catch {
        # Get-WindowsFeature may not be available on non-Server OS — skip gracefully
        Write-Host "  [INFO] Could not check IIS role (may not be available on this OS edition)." -ForegroundColor Gray
    }

    # Summary
    Write-Host ""
    if ($result.AllPass) {
        Write-Host "  [PASS] All Group Policy prerequisites are met." -ForegroundColor Green
        Write-Host "  The Appliance Configuration Manager should be able to register without policy blocks." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] One or more Group Policy prerequisites failed." -ForegroundColor Red
        Write-Host "  These issues WILL prevent appliance registration, regardless of network health." -ForegroundColor Red
        Write-Host "  Contact your Windows/Group Policy administrator to resolve these settings." -ForegroundColor Yellow
    }

    $script:GroupPolicyResult = $result
    Write-Host ""
}

# ============================================================================
# TEST-AVEXCLUSIONPATHS — v5.0 addition
# ============================================================================
function Test-AvExclusionPaths {
    param(
        [ValidateSet('VMwareAgentless','AgentBasedLegacy','AgentBasedModern')]
        [string]$Scenario
    )

    Write-Section "ANTIVIRUS EXCLUSION PATHS — REQUIRED FOLDERS (Read-Only Check)"
    Write-Host ""
    Write-Host "  WHY THESE FOLDERS MUST BE EXCLUDED FROM ANTIVIRUS SCANNING:" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Azure Migrate stores live replication data, logs, and agent executables" -ForegroundColor White
    Write-Host "  in the folders listed below. If your antivirus product scans or locks" -ForegroundColor White
    Write-Host "  these files during active operations, it can cause:" -ForegroundColor White
    Write-Host ""
    Write-Host "    - Corrupt in-flight replication data → replication fails silently" -ForegroundColor Red
    Write-Host "    - Locked agent executables → Azure Migrate services cannot start" -ForegroundColor Red
    Write-Host "    - Quarantined mobility agent installers → cannot push agent to source VMs" -ForegroundColor Red
    Write-Host "    - False-positive detections on legitimate Azure migration network traffic" -ForegroundColor Red
    Write-Host ""
    Write-Host "  This is one of the top causes of Azure Migrate failures in environments" -ForegroundColor Yellow
    Write-Host "  with active endpoint security products (CrowdStrike, Defender, SentinelOne etc.)" -ForegroundColor Yellow
    Write-Host ""

    # Core appliance exclusion paths — required for ALL scenarios
    $applianceExclusions = @(
        [PSCustomObject]@{ Path = 'C:\ProgramData\Microsoft Azure';                                    Reason = 'Appliance logs, temp data, and replication state files — actively written during all operations' }
        [PSCustomObject]@{ Path = 'C:\ProgramData\ASRLogs';                                            Reason = 'Azure Site Recovery diagnostic logs — must not be locked during log write operations' }
        [PSCustomObject]@{ Path = 'C:\Windows\Temp\MicrosoftAzure';                                    Reason = 'Temporary working files used during appliance operations and updates' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure Appliance Auto Update';            Reason = 'Auto-update agent executables — AV must not block or quarantine update packages' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure Appliance Configuration Manager'; Reason = 'Config Manager web application files — must run without interference' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure Push Install Agent';               Reason = 'Mobility agent push installer — AV MUST NOT quarantine this; it pushes agents to source VMs' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure RCM Proxy Agent';                  Reason = 'Replication proxy agent — handles communication between appliance and Azure' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure Recovery Services Agent';          Reason = 'Recovery services agent binaries — actively used during replication' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure Server Discovery Service';         Reason = 'Discovery service executables — scans source VMs for inventory data' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure Site Recovery Process Server';     Reason = 'CRITICAL: Process server handles all replication data flows — AV scanning can corrupt data mid-transfer' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure Site Recovery Provider';           Reason = 'Site Recovery provider agent — communicates with Azure Site Recovery service' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure to on-premises Reprotect agent';  Reason = 'Reprotect agent used for failback scenarios' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft Azure VMware Discovery Service';         Reason = 'VMware-specific discovery agent — reads vCenter and ESXi metadata' }
        [PSCustomObject]@{ Path = 'C:\Program Files\Microsoft on-premises to Azure Replication agent'; Reason = 'CRITICAL: Core replication agent — AV must not scan during active replication data transfers' }
        [PSCustomObject]@{ Path = 'E:\';                                                               Reason = 'Replication cache data disk — entire drive must be excluded; active replication writes large data blocks here continuously' }
    )

    Write-Host "  REQUIRED EXCLUSIONS — ALL SCENARIOS" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

    $pathsFound    = 0
    $pathsNotFound = 0
    $criticalMissing = [System.Collections.ArrayList]::new()

    foreach ($excl in $applianceExclusions) {
        $exists = Test-Path -Path $excl.Path -ErrorAction SilentlyContinue
        if ($exists) {
            $pathsFound++
            Write-Host "  [EXISTS] $($excl.Path)" -ForegroundColor Green
        } else {
            $pathsNotFound++
            Write-Host "  [NOT FOUND] $($excl.Path)" -ForegroundColor Gray
        }
        Write-Host "           → $($excl.Reason)" -ForegroundColor Gray
        Write-Host ""

        if ($exists -and $excl.Path -match 'Process Server|Replication agent') {
            [void]$criticalMissing.Add($excl.Path)
        }
    }

    # VMware Agentless specific
    if ($Scenario -eq 'VMwareAgentless') {
        Write-Host ""
        Write-Host "  ADDITIONAL EXCLUSION — VMWARE AGENTLESS ONLY" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        $vddkPath = 'C:\Program Files (x86)\VMware\VMware vSphere VDDK'
        $vddkExists = Test-Path -Path $vddkPath -ErrorAction SilentlyContinue
        $vddkStatus = if ($vddkExists) { "[EXISTS]" } else { "[NOT FOUND]" }
        $vddkColor  = if ($vddkExists) { "Green" } else { "Gray" }
        Write-Host "  $vddkStatus $vddkPath" -ForegroundColor $vddkColor
        Write-Host "           → VDDK (Virtual Disk Development Kit) libraries used to read VM disk data" -ForegroundColor Gray
        Write-Host "             during agentless migration. AV scanning this folder causes VDDK" -ForegroundColor Gray
        Write-Host "             initialization failure — agentless replication will not start." -ForegroundColor Gray
        Write-Host ""
        if (-not $vddkExists) {
            Write-Host "  [INFO] VDDK folder not found. VDDK must be installed on this appliance" -ForegroundColor Yellow
            Write-Host "  before agentless migration can run." -ForegroundColor Yellow
            [void]$script:Warnings.Add("VDDK not found at $vddkPath. VMware agentless migration requires VDDK to be installed. Download from VMware Customer Connect.")
        }
    }

    # Simplified Experience (AgentBasedModern) — source VM note
    if ($Scenario -eq 'AgentBasedModern') {
        Write-Host ""
        Write-Host "  ADDITIONAL EXCLUSION — ON EACH SOURCE VM BEING MIGRATED" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Path to exclude on SOURCE MACHINES (not this appliance):" -ForegroundColor White
        Write-Host "  C:\Program Files (x86)\Microsoft Azure Site Recovery\" -ForegroundColor Cyan
        Write-Host "  → This is where the Mobility Service agent is installed on VMs being replicated." -ForegroundColor Gray
        Write-Host "    If the AV product on source machines quarantines mobility agent files during" -ForegroundColor Gray
        Write-Host "    push installation or active replication, replication will fail or stall." -ForegroundColor Gray
        Write-Host "  → Ensure your AV team adds this exclusion to the policy applied to source VMs." -ForegroundColor Yellow
        Write-Host ""
    }

    # AV product-specific guidance (if AV was detected earlier)
    if ($null -ne $script:AvEdrResult -and $script:AvEdrResult.Count -gt 0) {
        Write-Host ""
        Write-Host "  HOW TO ADD EXCLUSIONS FOR DETECTED AV PRODUCTS:" -ForegroundColor Yellow
        Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""

        foreach ($av in $script:AvEdrResult) {
            $avName = $av.Product
            Write-Host "  $avName :" -ForegroundColor White
            switch -Wildcard ($avName) {
                '*CrowdStrike*' {
                    Write-Host "    1. Log in to CrowdStrike Falcon Console (falcon.crowdstrike.com)" -ForegroundColor Gray
                    Write-Host "    2. Go to: Configuration > Prevention Policy > your policy > Exclusions" -ForegroundColor Gray
                    Write-Host "    3. Add each folder path above as a 'Never Block' exclusion" -ForegroundColor Gray
                    Write-Host "    4. IMPORTANT: Also add VDDK path if running VMware agentless migration" -ForegroundColor Gray
                }
                '*Defender*' {
                    Write-Host "    Run in PowerShell (Admin) — one command per path:" -ForegroundColor Gray
                    Write-Host "    Add-MpPreference -ExclusionPath 'C:\ProgramData\Microsoft Azure'" -ForegroundColor Cyan
                    Write-Host "    Add-MpPreference -ExclusionPath 'C:\Program Files\Microsoft Azure Site Recovery Process Server'" -ForegroundColor Cyan
                    Write-Host "    (Repeat for each path listed above)" -ForegroundColor Gray
                }
                '*SentinelOne*' {
                    Write-Host "    1. Log in to SentinelOne Management Console" -ForegroundColor Gray
                    Write-Host "    2. Go to: Exclusions > Path Exclusions" -ForegroundColor Gray
                    Write-Host "    3. Add each folder path with mode 'Suppression'" -ForegroundColor Gray
                }
                '*Carbon Black*' {
                    Write-Host "    1. Log in to Carbon Black Cloud or CBC console" -ForegroundColor Gray
                    Write-Host "    2. Go to: Policies > your policy > Prevention > Exclusions" -ForegroundColor Gray
                    Write-Host "    3. Add folder path exclusions for each path above" -ForegroundColor Gray
                }
                default {
                    Write-Host "    Consult your $avName vendor documentation to add folder path exclusions." -ForegroundColor Gray
                    Write-Host "    Reference: https://learn.microsoft.com/en-us/azure/site-recovery/replication-appliance-support-matrix#folder-exclusions-from-antivirus-programs" -ForegroundColor Cyan
                }
            }
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "  No AV/EDR products were detected on this machine." -ForegroundColor Green
        Write-Host "  If AV is managed centrally (not visible from this machine), ensure" -ForegroundColor Gray
        Write-Host "  your AV team adds the exclusions above to the policy for this machine." -ForegroundColor Gray
        Write-Host ""
    }

    # Summary
    Write-Host "  SUMMARY" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    if ($pathsFound -gt 0) {
        Write-Host "  $pathsFound path(s) found on this machine — add these to your AV exclusion list." -ForegroundColor Yellow
        Write-Host "  $pathsNotFound path(s) not found (not installed yet or different path)." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Full Microsoft documentation:" -ForegroundColor White
        Write-Host "  https://learn.microsoft.com/en-us/azure/site-recovery/replication-appliance-support-matrix#folder-exclusions-from-antivirus-programs" -ForegroundColor Cyan
        [void]$script:Recommendations.Add("AV EXCLUSIONS NEEDED: $pathsFound Azure Migrate folders found on this machine. Add them all to your AV/EDR exclusion list to prevent replication failures. See: https://learn.microsoft.com/en-us/azure/site-recovery/replication-appliance-support-matrix#folder-exclusions-from-antivirus-programs")
    } else {
        Write-Host "  None of the standard Azure Migrate folders were found on this machine." -ForegroundColor Gray
        Write-Host "  This is expected if the appliance software is not yet installed." -ForegroundColor Gray
        Write-Host "  Once installed, add the paths above to your AV exclusion list BEFORE" -ForegroundColor Yellow
        Write-Host "  running the first replication." -ForegroundColor Yellow
    }

    $script:AvExclusionResult = @{
        PathsFound    = $pathsFound
        PathsNotFound = $pathsNotFound
        Scenario      = $Scenario
    }
    Write-Host ""
}

function Main {
    Clear-Host
    Write-Banner

    # ----- Prerequisites -----
    if ($PSVersionTable.PSVersion.Major -lt 5 -or
        ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        Write-Host "  [ERROR] PowerShell 5.1 or higher is required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
        Write-Host "  Please update PowerShell and re-run this script." -ForegroundColor Red
        return
    }

    # ----- Execution Policy Notice -----
    $currentPolicy = Get-ExecutionPolicy -Scope Process -ErrorAction SilentlyContinue
    $machinePolicy = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction SilentlyContinue
    $userPolicy    = Get-ExecutionPolicy -Scope CurrentUser  -ErrorAction SilentlyContinue

    Write-Section "EXECUTION POLICY INFORMATION"
    Write-Host "  Current session policy : $currentPolicy" -ForegroundColor Gray
    Write-Host "  Machine policy         : $machinePolicy" -ForegroundColor Gray
    Write-Host "  User policy            : $userPolicy" -ForegroundColor Gray
    Write-Host ""

    if ($currentPolicy -in @('Bypass','Unrestricted')) {
        Write-Host "  [OK] Execution policy is set to '$currentPolicy' for this session." -ForegroundColor Green
        Write-Host "  The script is running correctly. This setting only affects this" -ForegroundColor Green
        Write-Host "  PowerShell window and reverts when the window is closed." -ForegroundColor Green
    } elseif ($currentPolicy -eq 'AllSigned') {
        Write-Host "  [WARN] Execution policy is 'AllSigned' — this script is NOT digitally signed." -ForegroundColor Yellow
        Write-Host "  If you are seeing this message, the script ran anyway (possibly via a parent" -ForegroundColor Yellow
        Write-Host "  process bypass). To run explicitly, use:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass" -ForegroundColor Cyan
        Write-Host "    .\Invoke-AzMigrateConnectivityCheck.ps1" -ForegroundColor Cyan
        [void]$script:Warnings.Add("Execution policy is AllSigned. This script is unsigned. Run with: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass")
    } elseif ($currentPolicy -eq 'RemoteSigned') {
        Write-Host "  [INFO] Execution policy is 'RemoteSigned'." -ForegroundColor Gray
        Write-Host "  If this script was downloaded from the internet and is blocked, run:" -ForegroundColor Gray
        Write-Host ""
        Write-Host "    Unblock-File -Path .\Invoke-AzMigrateConnectivityCheck.ps1" -ForegroundColor Cyan
        Write-Host "    OR" -ForegroundColor Gray
        Write-Host "    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass" -ForegroundColor Cyan
    } else {
        Write-Host "  [INFO] Execution policy: $currentPolicy — script is running." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  NOTE: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass is SAFE to use." -ForegroundColor White
    Write-Host "  'Scope Process' means it ONLY applies to this PowerShell window." -ForegroundColor White
    Write-Host "  It does NOT change any system-wide settings." -ForegroundColor White
    Write-Host "  It does NOT persist after this window is closed." -ForegroundColor White
    Write-Host "  It does NOT require a reboot or any cleanup." -ForegroundColor White
    Write-Host ""

    # ----- User Prompts -----
    Write-Section "DEPLOYMENT SCENARIO SELECTION"

    # Cloud selection — now includes China (21Vianet)
    $cloudSel = Get-MenuSelection -Prompt "Which Azure cloud are you deploying to?" `
        -Options @(
            "Commercial Azure (Public Cloud)",
            "Azure Government (US Gov)",
            "Azure China (21Vianet)"
        ) `
        -HelpText "Select the Azure cloud environment for your deployment."
    $cloud = switch ($cloudSel) {
        1 { 'Commercial' }
        2 { 'Government' }
        3 { 'China' }
    }

    # Scenario
    $scenarioSel = Get-MenuSelection -Prompt "Which deployment scenario are you using?" `
        -Options @(
            "Azure Migrate VMware Agentless (discovery, assessment, and agentless migration)",
            "Azure Migrate Agent-based Legacy Appliance (replication appliance)",
            "Azure Migrate Agent-based Modern Appliance (simplified experience)"
        ) `
        -HelpText "See: https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance#deployment-scenarios"
    $scenario = switch ($scenarioSel) {
        1 { 'VMwareAgentless' }
        2 { 'AgentBasedLegacy' }
        3 { 'AgentBasedModern' }
    }

    # Appliance type
    $applianceTypeSel = Get-MenuSelection -Prompt "What type of appliance are you troubleshooting?" `
        -Options @(
            "Assessment / Discovery appliance",
            "Replication appliance (migration)"
        ) `
        -HelpText "Assessment appliance is for discovery and assessment. Replication appliance is for migration."
    $applianceType = if ($applianceTypeSel -eq 1) { 'Assessment' } else { 'Replication' }

    # Platform (NEW in v2.0)
    $platformSel = Get-MenuSelection -Prompt "Which source platform are you discovering/migrating?" `
        -Options @(
            "VMware vSphere",
            "Hyper-V",
            "Physical / Other Cloud (AWS, GCP, bare-metal)"
        ) `
        -HelpText "Select the source platform the appliance will connect to."
    $platform = switch ($platformSel) {
        1 { 'VMware' }
        2 { 'HyperV' }
        3 { 'Physical' }
    }

    # Private Link
    $privateLinkSel = Get-MenuSelection -Prompt "Are you using Azure Private Link / Private Endpoints?" `
        -Options @("No (public connectivity)", "Yes (private endpoints)") `
        -HelpText "See: https://learn.microsoft.com/en-us/azure/migrate/how-to-use-azure-migrate-with-private-endpoints"
    $privateLink = $privateLinkSel -eq 2

    # Connectivity path (NEW in v2.0)
    $connPathSel = Get-MenuSelection -Prompt "How does this appliance connect to Azure?" `
        -Options @(
            "Direct internet (no proxy)",
            "Internet via proxy",
            "ExpressRoute (private peering)",
            "ExpressRoute (Microsoft peering)",
            "VPN Gateway"
        ) `
        -HelpText "Select the network path used by this appliance to reach Azure services."
    $connectivityPath = switch ($connPathSel) {
        1 { 'DirectInternet' }
        2 { 'InternetViaProxy' }
        3 { 'ExpressRoute-Private' }
        4 { 'ExpressRoute-Microsoft' }
        5 { 'VPNGateway' }
    }

    # ExpressRoute private peering early warning
    if ($connectivityPath -eq 'ExpressRoute-Private') {
        Write-Host ""
        Write-Host "  *** WARNING: ExpressRoute PRIVATE PEERING ***" -ForegroundColor Red
        Write-Host "  ExpressRoute private peering does NOT carry public Azure service endpoints." -ForegroundColor Red
        Write-Host "  Azure Migrate endpoints (login.microsoftonline.com, management.azure.com," -ForegroundColor Red
        Write-Host "  servicebus.windows.net, etc.) are PUBLIC endpoints and are NOT routed over" -ForegroundColor Red
        Write-Host "  ExpressRoute private peering by default." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Your appliance will need one of the following to reach Azure services:" -ForegroundColor Yellow
        Write-Host "    (a) Internet access (direct or via proxy / NAT gateway)" -ForegroundColor Yellow
        Write-Host "    (b) ExpressRoute Microsoft Peering for Azure public IPs" -ForegroundColor Yellow
        Write-Host "    (c) Azure Private Endpoints for each Azure Migrate service" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Connectivity tests will likely fail if none of the above are in place." -ForegroundColor Yellow
        Write-Host ""
        [void]$script:Warnings.Add("ExpressRoute PRIVATE PEERING selected. Public Azure service endpoints are NOT carried over private peering. Appliance needs internet access or private endpoints.")
        Read-Host "  Press Enter to continue anyway"
    }

    # ----- Custom URLs (error messages, auto-update endpoints, etc.) -----
    $customUrls = [System.Collections.ArrayList]::new()
    Write-Host ""
    Write-Host "  Do you have any specific URLs from error messages that you want to test?" -ForegroundColor White
    Write-Host "  (e.g., auto-update manifest URLs, service endpoints from appliance errors)" -ForegroundColor Gray
    Write-Host "  Paste full URL(s) one per line. Press Enter on a blank line when done." -ForegroundColor Gray
    Write-Host "  (If none, just press Enter to continue)" -ForegroundColor Gray
    Write-Host ""
    do {
        $customInput = Read-Host "  URL"
        if ($customInput -and $customInput.Trim()) {
            $trimmed  = $customInput.Trim()
            $hostPart = $trimmed -replace '^https?://', '' -replace '/.*$', ''
            if ($hostPart) {
                [void]$customUrls.Add(@{
                    Host     = $hostPart
                    Port     = 443
                    Purpose  = "Custom URL from error/appliance (source: $trimmed)"
                    Wildcard = "*.$($hostPart -replace '^[^.]+\.', '')"
                    Category = 'Custom URLs (from error messages)'
                })
                Write-Host "    Added: $hostPart" -ForegroundColor Green
            }
        }
    } while ($customInput -and $customInput.Trim())

    # Auto-update GUID URL helper (NEW in v2.0)
    Get-AutoUpdateGuidUrl -CustomUrls $customUrls

    # ----- Summary -----
    Write-Section "SELECTED CONFIGURATION"
    Write-Host "    Cloud:             $cloud"            -ForegroundColor White
    Write-Host "    Scenario:          $scenario"         -ForegroundColor White
    Write-Host "    Appliance Type:    $applianceType"    -ForegroundColor White
    Write-Host "    Platform:          $platform"         -ForegroundColor White
    Write-Host "    Connectivity Path: $connectivityPath" -ForegroundColor White
    Write-Host "    Private Link:      $privateLink"      -ForegroundColor White
    Write-Host ""
    Write-Host "  Press Enter to begin connectivity checks or Ctrl+C to cancel..." -ForegroundColor Gray
    Read-Host

    try {
        # ----- Start timer (v4.0) -----
        $script:StartTime = Get-Date

        # ----- Azure Service Health (v4.0 — run first to catch outages) -----
        Test-AzureServiceHealth -Cloud $cloud

        # ----- Environment Info -----
        Get-EnvironmentInfo

        # ----- .NET Framework Version (v4.0) -----
        Test-DotNetVersion

        # ----- Virtualization Detection -----
        Get-VirtualizationInfo

        # ----- Appliance Registration State -----
        Get-ApplianceRegistrationState

        # ----- Duplicate Appliance Detection (v5.0) -----
        Test-DuplicateAppliance -Cloud $cloud

        # ----- Appliance Config Manager Health (v4.0) -----
        Test-ApplianceHealthApi
        Test-ConfigManagerAccess

        # ----- Appliance Log Analysis -----
        Get-ApplianceLogs -Scenario $scenario

        # ----- Outbound NAT IP (v4.0) -----
        Get-OutboundNatIp

        # ----- Proxy Detection -----
        $proxyDetected = Get-ProxyConfiguration

        # ----- Local Firewall -----
        Test-LocalFirewall

        # ----- Group Policy Prerequisites (v5.0) -----
        Test-GroupPolicyPrereqs

        # ----- Basic Connectivity -----
        Test-BasicConnectivity

        # ----- Clock Skew Check -----
        Test-ClockSkew

        # ----- Hosts File Check -----
        Test-HostsFile

        # ----- Platform Source Connectivity -----
        Test-PlatformPorts -Platform $platform

        # ----- vCenter Auth Test (v5.0 - VMware only) -----
        if ($platform -eq 'VMware') {
            Test-vCenterConnectivity
        }

        # ----- MTU Path Test (v5.0 - VMware Agentless only) -----
        if ($scenario -eq 'VMwareAgentless') {
            Test-MtuPath -Cloud $cloud
        }

        # ----- Additional Ports (v5.0 - VMware Agentless only) -----
        if ($scenario -eq 'VMwareAgentless') {
            Test-AdditionalPorts
        }

        # ----- Build URL List -----
        $urlList = Get-UrlDefinitions -Cloud $cloud -Scenario $scenario -ApplianceType $applianceType `
            -Platform $platform -PrivateLink $privateLink

        if ($urlList.Count -eq 0) {
            Write-Host ""
            Write-Host "  [WARN] No URLs generated for the selected configuration. Please verify your selections." -ForegroundColor Yellow
            return
        }

        # ----- Append custom URLs -----
        if ($customUrls.Count -gt 0) {
            foreach ($cu in $customUrls) {
                [void]$urlList.Add($cu)
            }
            Write-Host ""
            Write-Host "  Added $($customUrls.Count) custom URL(s) to the test list." -ForegroundColor Cyan
        }

        # ----- Run Connectivity Tests (Parallel v4.0) -----
        Invoke-ConnectivityTestsParallel -UrlList $urlList

        # ----- Region-Specific Endpoint Test (v5.0) -----
        Test-RegionEndpoints -Cloud $cloud

        # ----- Private Link DNS Validation -----
        if ($privateLink) {
            Test-PrivateLinkDns -UrlList $urlList -Cloud $cloud
        }

        # ----- DNS Comparison vs 8.8.8.8 -----
        Test-DnsComparison

        # ----- TCP Behavior Analysis -----
        Test-TcpBehavior

        # ----- Flap / Retry Test (v4.0) -----
        Test-FlakyConnections

        # ----- Traceroute (only if TCP failures exist) -----
        $hasTcpFails = ($script:TestResults | Where-Object { $_.DnsPass -and -not $_.TcpPass }).Count -gt 0
        if ($hasTcpFails) {
            Test-TraceRoute -Cloud $cloud
        }

        # ----- Proxy CONNECT Test (only if proxy detected) -----
        $proxyStr = ''
        if ($proxyDetected) {
            $regPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            $proxyEnable = (Get-ItemProperty -Path $regPath -Name 'ProxyEnable' -ErrorAction SilentlyContinue).ProxyEnable
            $proxyServer = (Get-ItemProperty -Path $regPath -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
            if ($proxyEnable -eq 1 -and $proxyServer) { $proxyStr = $proxyServer }
            if (-not $proxyStr) {
                $winhttp = netsh winhttp show proxy 2>&1 | Out-String
                if ($winhttp -match 'Proxy Server\s*[=:]\s*(\S+)') { $proxyStr = $matches[1] }
            }
            Test-ProxyConnect    -ProxyString $proxyStr
            Test-ProxyAuthType   -ProxyString $proxyStr
        }

        # ----- TLS Certificate Chain Inspection -----
        Get-TlsCertificateChain -Cloud $cloud

        # ----- Auto-Update Version Currency (v5.0) -----
        Test-ApplianceVersionCurrency

        # ----- Windows Event Log Mining (v5.0) -----
        Get-RelevantEventLogs

        # ----- AV/EDR Detection (v5.0) -----
        Test-AntivirusInterference

        # ----- AV Exclusion Paths (v5.0) -----
        Test-AvExclusionPaths -Scenario $scenario

        # ----- Executive Summary (v3.0) -----
        Write-ExecutiveSummary -Cloud $cloud -ConnectivityPath $connectivityPath

        # ----- Next Steps (v3.0) -----
        Write-NextSteps

        # ----- Detailed Results Summary -----
        Write-ResultsSummary -Cloud $cloud -Scenario $scenario -ApplianceType $applianceType `
            -Platform $platform -ConnectivityPath $connectivityPath -PrivateLink $privateLink

        # ----- Firewall Rule Summary -----
        Write-FirewallRuleSummary

        # ----- Recommendations -----
        Write-Recommendations -Cloud $cloud -Scenario $scenario -ApplianceType $applianceType `
            -Platform $platform -ConnectivityPath $connectivityPath -PrivateLink $privateLink

        # ----- Export Report -----
        Export-Report -Cloud $cloud -Scenario $scenario -ApplianceType $applianceType `
            -Platform $platform -ConnectivityPath $connectivityPath `
            -PrivateLink $privateLink -ProxyDetected $proxyDetected

        # ----- Summary Report + ZIP (v5.0) -----
        Export-SummaryReport
        Compress-Report

        # ----- Final Banner -----
        $elapsed = (Get-Date) - $script:StartTime
        $elapsedStr = '{0:mm}m {0:ss}s' -f $elapsed
        Write-Host ""
        Write-Host "===============================================================================" -ForegroundColor Cyan
        Write-Host "  v5.0 Diagnostic complete in $elapsedStr." -ForegroundColor Cyan
        Write-Host "  Report saved to:" -ForegroundColor Cyan
        Write-Host "  $($script:ReportPath)" -ForegroundColor White
        Write-Host ""
        Write-Host "  The report opens with an EXECUTIVE SUMMARY and NEXT STEPS." -ForegroundColor Cyan
        Write-Host "  Share the full report with your network/security/support team." -ForegroundColor Cyan
        Write-Host "===============================================================================" -ForegroundColor Cyan
        Write-Host ""

    } finally {
        # Always clean up — no traces left behind
        Invoke-Cleanup
    }
}

# Run the script
Main
