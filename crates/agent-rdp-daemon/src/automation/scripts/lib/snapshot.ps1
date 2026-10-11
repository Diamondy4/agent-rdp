# snapshot.ps1 - accessibility tree snapshots: walk (COM), render, refs

# Interactive patterns - elements with these can be interacted with
$script:InteractivePatterns = @("invoke", "value", "toggle", "selectionitem", "expandcollapse", "rangevalue", "scroll")

function Get-SnapshotBudget {
    param([string]$Name, [int]$Default)

    $raw = [Environment]::GetEnvironmentVariable($Name)
    $value = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$value) -and $value -gt 0) {
        return $value
    }

    return $Default
}

# Budgets that keep pathological trees from running away. The walk stops once
# either limit is reached and reports truncated = true with the reason.
# Override per host with AGENT_RDP_SNAPSHOT_MAX_NODES / AGENT_RDP_SNAPSHOT_MAX_SECONDS.
$script:MaxSnapshotNodes = Get-SnapshotBudget 'AGENT_RDP_SNAPSHOT_MAX_NODES' 20000
$script:MaxSnapshotSeconds = Get-SnapshotBudget 'AGENT_RDP_SNAPSHOT_MAX_SECONDS' 6

function Test-IsEmptyStructural {
    param($Node)

    # Empty if no name, no value, no interactive patterns, and no children
    $hasName = -not [string]::IsNullOrEmpty($Node["name"])
    $hasValue = -not [string]::IsNullOrEmpty($Node["value"])
    $hasChildren = $Node["children"] -and $Node["children"].Count -gt 0

    # Structural roles that can be pruned if empty
    $structuralRoles = @("Pane", "Group", "Custom", "Document", "ScrollBar", "Thumb")
    $isStructural = $structuralRoles -contains $Node["role"]

    return $isStructural -and -not $hasName -and -not $hasValue -and -not $hasChildren
}

# Render a walker node into the snapshot shape the CLI expects. Refs record the
# node identity and a point inside it; the live element is looked up on demand.
function ConvertTo-ComSnapshotNode {
    param(
        [UiaNode]$Node,
        [int[]]$Path,
        [ref]$RefCounter,
        [bool]$InteractiveOnly = $false,
        [bool]$Compact = $false,
        [int]$Depth = 0,
        [int]$MaxDepth = 10
    )

    if ($Depth -gt $MaxDepth) {
        $script:WasTruncated = $true
        return $null
    }

    $RefCounter.Value++
    $ref = $RefCounter.Value

    # NB: not $node - PowerShell variable names are case-insensitive and the
    # parameter above is already $Node.
    $rendered = [ordered]@{}
    $rendered["ref"] = $ref

    $script:RefMap[$ref] = @{
        Role = $Node.Role
        Name = $Node.Name
        AutomationId = $Node.AutomationId
    }

    if (-not [string]::IsNullOrEmpty($Node.Role)) { $rendered["role"] = $Node.Role }
    if (-not [string]::IsNullOrEmpty($Node.Name)) { $rendered["name"] = $Node.Name }
    if (-not [string]::IsNullOrEmpty($Node.AutomationId)) { $rendered["automation_id"] = $Node.AutomationId }
    if (-not [string]::IsNullOrEmpty($Node.ClassName)) { $rendered["class_name"] = $Node.ClassName }

    $bounds = Get-UiaNodeBounds $Node
    if ($null -ne $bounds) { $rendered["bounds"] = $bounds }

    $states = @(Get-UiaNodeStates $Node)
    if ($states.Count -gt 0) { $rendered["states"] = $states }

    if ($Node.HasValue -and $null -ne $Node.Value) { $rendered["value"] = $Node.Value }
    if ($null -ne $Node.Patterns -and $Node.Patterns.Count -gt 0) { $rendered["patterns"] = @($Node.Patterns) }

    $children = @()
    foreach ($child in $Node.Children) {
        $childNode = ConvertTo-ComSnapshotNode -Node $child -Path ($Path + $child.ChildIndex) -RefCounter $RefCounter `
            -InteractiveOnly $InteractiveOnly -Compact $Compact -Depth ($Depth + 1) -MaxDepth $MaxDepth
        if ($childNode) { $children += $childNode }
    }
    $rendered["children"] = @($children)

    if ($InteractiveOnly) {
        $isInteractive = $Node.Focusable
        if (-not $isInteractive -and $null -ne $Node.Patterns) {
            foreach ($p in $Node.Patterns) { if ($script:InteractivePatterns -contains $p) { $isInteractive = $true; break } }
        }
        if (-not $isInteractive -and $children.Count -eq 0) { return $null }
    }

    if ($Compact -and (Test-IsEmptyStructural $rendered)) { return $null }

    return $rendered
}

function Invoke-Snapshot {
    param($Params)

    $maxDepth = if ($null -ne $Params.max_depth) { [int]$Params.max_depth } else { 10 }
    $interactiveOnly = if ($null -ne $Params.interactive_only) { $Params.interactive_only } else { $false }
    $compact = if ($null -ne $Params.compact) { $Params.compact } else { $false }
    $focused = if ($null -ne $Params.focused) { $Params.focused } else { $false }

    # One cached COM walk of the desktop; everything below is served from it.
    $comSnapshot = Get-UiaComSnapshot -MaxDepth 40 -MaxNodes $script:MaxSnapshotNodes -MaxSeconds $script:MaxSnapshotSeconds

    $renderNode = $null
    $renderPath = @()

    if ($Params.selector) {
        # A @ref scope points into the previous snapshot, so it is resolved
        # before this snapshot replaces the ref map below.
        $match = Find-UiaNode -Selector $Params.selector -Root $comSnapshot.Root
        if ($null -ne $match) {
            $renderNode = $match["Node"]
            $renderPath = $match["Path"]
        }
    } elseif ($focused) {
        $match = Find-UiaNodeInModel -Node $comSnapshot.Root -Path @() -Match { param($n) return $n.Focused }
        if ($null -ne $match) {
            $renderNode = $match["Node"]
            $renderPath = $match["Path"]
        }
    } else {
        $renderNode = $comSnapshot.Root
    }

    if ($null -eq $renderNode) {
        throw "Could not locate the snapshot scope in the accessibility tree: $($Params.selector)"
    }

    # From here on, @ref selectors point at this snapshot.
    $script:RefMap = @{}
    $script:WasTruncated = $false
    $script:LastProgressAt = Get-Date
    $refCounter = [ref]0
    $script:SnapshotId = [guid]::NewGuid().ToString().Substring(0, 8)

    $tree = ConvertTo-ComSnapshotNode -Node $renderNode -Path $renderPath -RefCounter $refCounter `
        -InteractiveOnly $interactiveOnly -Compact $compact -MaxDepth $maxDepth

    $truncatedReason = $null

    if ($comSnapshot.PerWindow) {
        Write-Log "COM walk used the per-window fallback: the desktop-wide cache build failed" "WARN"
    }

    if ($comSnapshot.ProviderFailure) {
        $script:WasTruncated = $true
        $missing = ""
        if ($comSnapshot.SkippedNames -and $comSnapshot.SkippedNames.Count -gt 0) {
            $missing = ": " + ($comSnapshot.SkippedNames -join "; ")
        }
        $truncatedReason = "a UI Automation provider failed (" + $comSnapshot.SkippedWindows + " subtree(s) missing" + $missing + ")"
    }

    if ($comSnapshot.Truncated) {
        $script:WasTruncated = $true
        if ($null -eq $truncatedReason) {
            if ($comSnapshot.NodeCount -ge $script:MaxSnapshotNodes) {
                $truncatedReason = "node budget (" + $script:MaxSnapshotNodes + " nodes) reached"
            } else {
                $truncatedReason = "time budget (" + $script:MaxSnapshotSeconds + " s) reached"
            }
        }
    } elseif ($script:WasTruncated -and $null -eq $truncatedReason) {
        $truncatedReason = "depth limit (" + $maxDepth + ") reached"
    }

    return @{
        snapshot_id = $script:SnapshotId
        ref_count = $refCounter.Value
        truncated = $script:WasTruncated
        truncated_reason = $truncatedReason
        max_depth = $maxDepth
        root = $tree
    }
}
