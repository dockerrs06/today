# PrePostDeploymentScript.ps1 - Triggers-focused, ARM-aware (sundasr)
# Stops triggers before deployment and (optionally) starts triggers after deployment.
# - Robust ARM name parsing (handles [concat(parameters('factoryName'), '/trigger')])
# - Clear diagnostics
# - Safe polling to verify final state
# - Post-deploy start is opt-in via -startTriggersPostDeploy

[CmdletBinding()]
param(
    [parameter(Mandatory = $false)] [String]   $armTemplate,
    [parameter(Mandatory = $true )] [String]   $ResourceGroupName,
    [parameter(Mandatory = $true )] [String]   $DataFactoryName,
    [parameter(Mandatory = $false)] [Bool]     $predeployment = $true,
    [parameter(Mandatory = $false)] [Bool]     $deleteDeployment = $false, # kept for compatibility (not used here)
    [parameter(Mandatory = $false)] [Bool]     $startTriggersPostDeploy = $false,
    [parameter(Mandatory = $false)] [String[]] $ExplicitStopTriggerList = @()
)

function Get-ArmResourceLeafName {
    param([string]$FullName)

    if ([string]::IsNullOrWhiteSpace($FullName)) { return $FullName }

    $trim = $FullName.Trim()

    # If it's an ARM expression (e.g., [concat(parameters('factoryName'), '/trigger')])
    if ($trim.StartsWith('[')) {
        # Extract the LAST single-quoted literal from the expression
        $matches = [regex]::Matches($trim, "'([^']+)'")
        if ($matches.Count -gt 0) {
            $last = $matches[$matches.Count - 1].Groups[1].Value
            return $last.TrimStart('/')   # '/trigger' -> 'trigger'
        }
    }

    # Fallback for plain strings: "factory/trigger" -> "trigger"
    return ($trim -split '/')[ -1 ]
}

function Load-ArmResources {
    param([string]$Path)

    if (-not $Path) {
        Write-Host "INFO: No ARM template path provided; proceeding with live factory data only."
        return @()
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "WARN: ARM template not found at: $Path"
        return @()
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -eq $json -or $null -eq $json.resources) {
            Write-Host "WARN: ARM template parsed but contains no 'resources'."
            return @()
        }
        return $json.resources
    } catch {
        Write-Host "WARN: Failed to parse ARM template: $($_.Exception.Message)"
        return @()
    }
}

function Wait-TriggerState {
    param(
        [string]$Name,
        [string]$Desired = 'Stopped',
        [int]$TimeoutSeconds = 45
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        try {
            $t = Get-AzDataFactoryV2Trigger -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $Name -ErrorAction Stop
            if ($t.RuntimeState -eq $Desired) { return $true }
        } catch { }
    } while([DateTime]::UtcNow -lt $deadline)
    return $false
}

# -------------------- Banner --------------------
Write-Host "=== ADF Trigger Control Script (Triggers-only) ==="
Write-Host "Factory        : $DataFactoryName"
Write-Host "Resource Group : $ResourceGroupName"
Write-Host "ARM Template   : $armTemplate"
Write-Host "Mode           : $([string]::Copy($(if($predeployment){'PRE'}else{'POST'})))"
Write-Host "StartAfterPost : $startTriggersPostDeploy"
Write-Host "Explicit Stop  : $(@($ExplicitStopTriggerList).Count) item(s)"
Write-Host "=================================================="

# Load ARM resources and compute template trigger names (ARM-aware)
$resources = Load-ArmResources -Path $armTemplate
$triggersInTemplate = $resources | Where-Object { $_.type -eq 'Microsoft.DataFactory/factories/triggers' }

$triggerNamesInTemplate = @()
if ($triggersInTemplate) {
    $triggerNamesInTemplate = $triggersInTemplate | ForEach-Object { Get-ArmResourceLeafName $_.name }
}

Write-Host "Template triggers count: $($triggerNamesInTemplate.Count)"
if ($triggerNamesInTemplate.Count -gt 0) {
    Write-Host "Template trigger names : $($triggerNamesInTemplate -join ', ')"
} else {
    Write-Host "Template trigger names : (none)"
}

# Get deployed triggers (live)
$triggersDeployed = Get-AzDataFactoryV2Trigger -DataFactoryName $DataFactoryName -ResourceGroupName $ResourceGroupName
Write-Host "Deployed triggers count: $($triggersDeployed.Count)"
if ($triggersDeployed.Count -gt 0) {
    Write-Host ("Deployed trigger names : " + (($triggersDeployed | Select-Object -ExpandProperty Name) -join ', '))
} else {
    Write-Host "Deployed trigger names : (none)"
}

# -------------------- PRE: Stop --------------------
if ($predeployment) {

    # If template has triggers, stop only those; else stop all deployed triggers
    if ($triggerNamesInTemplate.Count -gt 0) {
        Write-Host "INFO: Stopping ONLY triggers found in ARM template."
        $triggersToStop = $triggersDeployed | Where-Object { $triggerNamesInTemplate -contains $_.Name }
    } else {
        Write-Host "INFO: No triggers in template. Stopping ALL deployed triggers."
        $triggersToStop = $triggersDeployed
    }

    # Add explicit list (if provided)
    if ($ExplicitStopTriggerList.Count -gt 0) {
        $extra = $triggersDeployed | Where-Object { $ExplicitStopTriggerList -contains $_.Name }
        $triggersToStop = @($triggersToStop + $extra) | Sort-Object Name -Unique
    }

    Write-Host "Triggers to stop      : $(@($triggersToStop).Count)"
    if ($triggersToStop) {
        Write-Host ("Stop list             : " + (($triggersToStop | Select-Object -ExpandProperty Name) -join ', '))
    }

    foreach ($t in $triggersToStop) {
        try {
            # For Event Grid-based triggers, unsubscribe first (future-proof)
            $tType = $t.Properties.GetType().Name
            if ($tType -eq 'BlobEventsTrigger' -or $tType -eq 'CustomEventsTrigger') {
                Write-Host " - Unsubscribing events for: $($t.Name)"
                try {
                    $null = Remove-AzDataFactoryV2TriggerSubscription -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $t.Name -ErrorAction Stop
                } catch {
                    Write-Host "   WARN: Unsubscribe failed for $($t.Name): $($_.Exception.Message)"
                }
            }

            Write-Host " - Stopping trigger: $($t.Name)"
            Stop-AzDataFactoryV2Trigger -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $t.Name -Force -ErrorAction Stop

            if (Wait-TriggerState -Name $t.Name -Desired 'Stopped' -TimeoutSeconds 45) {
                Write-Host "   Status after stop: Stopped"
            } else {
                $cur = Get-AzDataFactoryV2Trigger -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $t.Name -ErrorAction SilentlyContinue
                $st = if ($cur) { $cur.RuntimeState } else { '(unknown)' }
                Write-Warning "   Trigger '$($t.Name)' did not report 'Stopped' (current: $st)"
            }
        } catch {
            Write-Host "WARN: Failed to stop trigger $($t.Name): $($_.Exception.Message)"
        }
    }

    return
}

# -------------------- POST: Optional start --------------------
if ($startTriggersPostDeploy) {
    # Start only those which are marked as Started in the template
    $triggersToStart = $triggersInTemplate |
        Where-Object { $_.properties.runtimeState -eq 'Started' } |
        ForEach-Object { Get-ArmResourceLeafName $_.name }

    Write-Host "Post-Deploy: triggers marked 'Started' in template: $(@($triggersToStart).Count)"
    if ($triggersToStart) {
        Write-Host ("Start list: " + ($triggersToStart -join ', '))
    }

    foreach ($name in $triggersToStart) {
        try {
            Write-Host "Starting trigger: $($name)"
            Start-AzDataFactoryV2Trigger -ResourceGroupName $ResourceGroupName -DataFactoryName $DataFactoryName -Name $name -Force -ErrorAction Stop
        } catch {
            Write-Host "WARN: Failed to start trigger $($name): $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "INFO: Skipping post-deploy trigger start (startTriggersPostDeploy=false)."
}




# param(
#     [Parameter(Mandatory=$true)]
#     [string]$ResourceGroupName,

#     [Parameter(Mandatory=$true)]
#     [string]$DataFactoryName,

#     [Parameter(Mandatory=$true)]
#     [ValidateSet("Stop","Start")]
#     [string]$Mode
# )

# # -----------------------------
# # Safety — Load module
# # -----------------------------
# Import-Module Az.DataFactory -Force

# Write-Host "====================================="
# Write-Host "ADF Trigger Control Script"
# Write-Host "RG   : $ResourceGroupName"
# Write-Host "ADF  : $DataFactoryName"
# Write-Host "Mode : $Mode"
# Write-Host "====================================="

# # -----------------------------
# # Get triggers
# # -----------------------------
# $triggers = Get-AzDataFactoryV2Trigger `
#     -ResourceGroupName $ResourceGroupName `
#     -DataFactoryName $DataFactoryName

# if (!$triggers) {
#     Write-Host "No triggers found."
#     exit 0
# }

# Write-Host "Total triggers found: $($triggers.Count)"

# # -----------------------------
# # STOP MODE
# # -----------------------------
# if ($Mode -eq "Stop") {

#     foreach ($t in $triggers) {

#         Write-Host "Trigger: $($t.Name) | State: $($t.RuntimeState)"

#         if ($t.RuntimeState -eq "Started") {

#             Write-Host ">>> Stopping trigger: $($t.Name)"

#             Stop-AzDataFactoryV2Trigger `
#                 -ResourceGroupName $ResourceGroupName `
#                 -DataFactoryName $DataFactoryName `
#                 -Name $t.Name `
#                 -Force | Out-Null
#         }
#         else {
#             Write-Host "Already stopped — skipping"
#         }
#     }
# }

# # -----------------------------
# # START MODE
# # -----------------------------
# if ($Mode -eq "Start") {

#     foreach ($t in $triggers) {

#         Write-Host "Trigger: $($t.Name) | State: $($t.RuntimeState)"

#         if ($t.RuntimeState -ne "Started") {

#             Write-Host ">>> Starting trigger: $($t.Name)"

#             Start-AzDataFactoryV2Trigger `
#                 -ResourceGroupName $ResourceGroupName `
#                 -DataFactoryName $DataFactoryName `
#                 -Name $t.Name `
#                 -Force | Out-Null
#         }
#         else {
#             Write-Host "Already started — skipping"
#         }
#     }
# }

# # -----------------------------
# # VERIFY FINAL STATE
# # -----------------------------
# Write-Host ""
# Write-Host "Final Trigger States:"
# Get-AzDataFactoryV2Trigger `
#     -ResourceGroupName $ResourceGroupName `
#     -DataFactoryName $DataFactoryName |
# Select Name, RuntimeState |
# Format-Table

# Write-Host "====================================="
# Write-Host "Script completed"
# Write-Host "====================================="
