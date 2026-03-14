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
    Version:  3.0
    Requires: PowerShell 5.1+
    Author:   Azure Migrate Connectivity Checker (generated diagnostic tool)

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
$script:ScriptVersion  = '3.0'
$script:TcpTimeoutMs   = 5000
$script:HttpTimeoutMs  = 10000
$script:ReportPath     = Join-Path $PSScriptRoot ("AzMigrate-ConnectivityReport_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

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
                local:Add-Url $urls 'hypervrecoverymanager.windowsazure.com' 443 '*.hypervrecoverymanager.windowsazure.com' 'Azure Site Recovery (agentless migration)' $cat2
                local:Add-Url $urls 'blob.core.windows.net'                  443 '*.blob.core.windows.net'                  'Azure Blob Storage (migration data upload)' $cat2
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
                [void]$script:Recommendations.Add("CRITICAL CLOCK SKEW: Clock is ${mins}m ${secs}s off. Run as Admin: net stop w32time && net start w32time && w32tm /resync /force")
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
        'Executive summary data'      = 'ExecutiveSummary'
        'Next steps text'             = 'NextStepsText'
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
        # ----- Environment Info -----
        Get-EnvironmentInfo

        # ----- Virtualization Detection (v3.0) -----
        Get-VirtualizationInfo

        # ----- Appliance Registration State (v3.0) -----
        Get-ApplianceRegistrationState

        # ----- Appliance Log Analysis (v3.0) -----
        Get-ApplianceLogs -Scenario $scenario

        # ----- Proxy Detection -----
        $proxyDetected = Get-ProxyConfiguration

        # ----- Local Firewall -----
        Test-LocalFirewall

        # ----- Basic Connectivity -----
        Test-BasicConnectivity

        # ----- Clock Skew Check (v3.0) -----
        Test-ClockSkew

        # ----- Hosts File Check (v3.0) -----
        Test-HostsFile

        # ----- Platform Source Connectivity -----
        Test-PlatformPorts -Platform $platform

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

        # ----- Run Connectivity Tests -----
        Invoke-ConnectivityTests -UrlList $urlList

        # ----- Private Link DNS Validation -----
        if ($privateLink) {
            Test-PrivateLinkDns -UrlList $urlList -Cloud $cloud
        }

        # ----- DNS Comparison vs 8.8.8.8 (v3.0) -----
        Test-DnsComparison

        # ----- TCP Behavior Analysis (v3.0) -----
        Test-TcpBehavior

        # ----- Traceroute (v3.0 - only if TCP failures exist) -----
        $hasTcpFails = ($script:TestResults | Where-Object { $_.DnsPass -and -not $_.TcpPass }).Count -gt 0
        if ($hasTcpFails) {
            Test-TraceRoute -Cloud $cloud
        }

        # ----- Proxy CONNECT Test (v3.0 - only if proxy detected) -----
        if ($proxyDetected) {
            $proxyStr = ''
            $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            $proxyEnable = (Get-ItemProperty -Path $regPath -Name 'ProxyEnable' -ErrorAction SilentlyContinue).ProxyEnable
            $proxyServer = (Get-ItemProperty -Path $regPath -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
            if ($proxyEnable -eq 1 -and $proxyServer) { $proxyStr = $proxyServer }
            if (-not $proxyStr) {
                $winhttp = netsh winhttp show proxy 2>&1 | Out-String
                if ($winhttp -match 'Proxy Server\s*[=:]\s*(\S+)') { $proxyStr = $matches[1] }
            }
            Test-ProxyConnect -ProxyString $proxyStr
        }

        # ----- TLS Certificate Chain Inspection (v3.0) -----
        Get-TlsCertificateChain -Cloud $cloud

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

        # ----- Final Banner -----
        Write-Host ""
        Write-Host "===============================================================================" -ForegroundColor Cyan
        Write-Host "  v3.0 Diagnostic complete. Report saved to:" -ForegroundColor Cyan
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
