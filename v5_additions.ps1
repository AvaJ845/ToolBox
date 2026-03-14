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
