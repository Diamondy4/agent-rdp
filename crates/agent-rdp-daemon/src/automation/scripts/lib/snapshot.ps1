# snapshot.ps1 - Accessibility tree snapshot and element state functions

# Interactive patterns - elements with these can be interacted with
$script:InteractivePatterns = @("invoke", "value", "toggle", "selectionitem", "expandcollapse", "rangevalue", "scroll")

# Cloaked or minimized windows can report infinite (or NaN) rectangles; casting
# those to [int] throws an Int32 overflow, so bounds are normalized instead.
function Test-FiniteRect {
    param($Rect)

    foreach ($value in @($Rect.X, $Rect.Y, $Rect.Width, $Rect.Height)) {
        $number = [double]$value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $false }
    }

    return $true
}

function ConvertTo-SafeInt32 {
    param([double]$Value)

    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return -1 }

    return [int]$Value
}

# Budgets that keep pathological accessibility trees (large Chromium/Electron
# web content) from hanging the agent: the traversal stops once either limit is
# reached and reports truncated = true.
function Get-SnapshotBudget {
    param([string]$Name, [int]$Default)

    $raw = [Environment]::GetEnvironmentVariable($Name)
    $value = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw, [ref]$value) -and $value -gt 0) {
        return $value
    }

    return $Default
}

# Override per host with AGENT_RDP_SNAPSHOT_MAX_NODES / AGENT_RDP_SNAPSHOT_MAX_SECONDS;
# raise the time budget only once the daemon's DVC request timeout is raised too.
$script:MaxSnapshotNodes = Get-SnapshotBudget 'AGENT_RDP_SNAPSHOT_MAX_NODES' 8000
# Keep the time budget below the daemon's 10 s DVC request timeout, otherwise a
# slow traversal is reported as a dead channel instead of a truncated snapshot.
$script:MaxSnapshotSeconds = Get-SnapshotBudget 'AGENT_RDP_SNAPSHOT_MAX_SECONDS' 6

function Get-ElementStates {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [string[]]$Patterns = $null
    )

    if ($null -eq $Patterns) { $Patterns = @(Get-SupportedPatterns $Element) }

    $states = @()
    $current = $Element.Current

    if ($current.IsEnabled) { $states += "enabled" }
    if ($current.IsKeyboardFocusable) { $states += "focusable" }
    if ($current.HasKeyboardFocus) { $states += "focused" }
    if ($current.IsOffscreen) { $states += "offscreen" }

    # Probe patterns only when the element supports them: the pattern list is
    # fetched once per node and shared with the traversal.
    if ($Patterns -contains "value") {
        try {
            $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            if ($valuePattern -and $valuePattern.Current.IsReadOnly) {
                $states += "readonly"
            } else {
                $states += "editable"
            }
        } catch {}
    }

    if ($Patterns -contains "text") {
        try {
            $textPattern = $Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            if ($textPattern) { $states += "multiline" }
        } catch {}
    }

    return $states
}

function Get-SupportedPatterns {
    param([System.Windows.Automation.AutomationElement]$Element)

    $patterns = @()
    $supportedPatterns = $Element.GetSupportedPatterns()

    foreach ($pattern in $supportedPatterns) {
        $name = $pattern.ProgrammaticName -replace "PatternIdentifiers.Pattern$", ""
        $patterns += $name.ToLower()
    }

    return $patterns
}

function Test-IsInteractive {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [string[]]$Patterns = $null
    )

    # Check if keyboard focusable
    if ($Element.Current.IsKeyboardFocusable) { return $true }

    # Check for interactive patterns
    if ($null -eq $Patterns) { $Patterns = @(Get-SupportedPatterns $Element) }

    foreach ($p in $Patterns) {
        if ($script:InteractivePatterns -contains $p) { return $true }
    }

    return $false
}

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

function Get-AccessibilityTree {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [int]$MaxDepth = 10,
        [int]$CurrentDepth = 0,
        [ref]$RefCounter,
        [bool]$InteractiveOnly = $false,
        [bool]$Compact = $false
    )

    if ($CurrentDepth -gt $MaxDepth) {
        $script:WasTruncated = $true
        return $null
    }

    $script:SnapshotNodes++
    if ($script:SnapshotNodes -gt $script:MaxSnapshotNodes) {
        $script:WasTruncated = $true
        return $null
    }

    if ($null -ne $script:SnapshotStart -and
        ((Get-Date) - $script:SnapshotStart).TotalSeconds -gt $script:MaxSnapshotSeconds) {
        $script:WasTruncated = $true
        return $null
    }

    # Heartbeat every 64 nodes so the daemon can tell a long traversal from a
    # dead agent (the response only arrives at the very end).
    # dead agent (the response only arrives at the very end). The node modulo
    # keeps the check cheap and the timestamp bounds the rate to ~1/s.
    if (($script:SnapshotNodes % 64) -eq 0 -and
        ((Get-Date) - $script:LastProgressAt).TotalMilliseconds -gt 1000) {
        $script:LastProgressAt = Get-Date
        Send-DvcProgress -Handle $script:DvcHandle -Id $script:CurrentRequestId -Phase "snapshot" `
            -ElapsedMs ([int]((Get-Date) - $script:SnapshotStart).TotalMilliseconds) -Nodes $script:SnapshotNodes
    }

    # For interactive filter, check if this element or any descendant is interactive
    # One pattern query per node drives the interactive filter, the state probes
    # and the reported pattern list (it used to be queried twice per node).
    $patterns = @(Get-SupportedPatterns $Element)

    # For interactive filter, check if this element or any descendant is interactive
    $isInteractive = Test-IsInteractive $Element $patterns

    $RefCounter.Value++
    $ref = $RefCounter.Value
    $script:RefMap[$ref] = $Element

    $rect = $Element.Current.BoundingRectangle
    $node = [ordered]@{}

    # Always include ref (with "e" prefix handled in output)
    $node["ref"] = $ref

    $node["role"] = $Element.Current.ControlType.ProgrammaticName -replace "ControlType\.", ""

    if (-not [string]::IsNullOrEmpty($Element.Current.Name)) {
        $node["name"] = $Element.Current.Name
    }

    if (-not [string]::IsNullOrEmpty($Element.Current.AutomationId)) {
        $node["automation_id"] = $Element.Current.AutomationId
    }

    if (-not [string]::IsNullOrEmpty($Element.Current.ClassName)) {
        $node["class_name"] = $Element.Current.ClassName
    }

    if (Test-FiniteRect $rect) {
        $node["bounds"] = @{
            x = ConvertTo-SafeInt32 $rect.X
            y = ConvertTo-SafeInt32 $rect.Y
            width = ConvertTo-SafeInt32 $rect.Width
            height = ConvertTo-SafeInt32 $rect.Height
        }
    }

    $states = @(Get-ElementStates $Element $patterns)
    if ($states.Count -gt 0) {
        $node["states"] = $states
    }

    # Read the value only for elements that expose a value pattern
    if ($patterns -contains "value") {
        try {
            $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            if ($valuePattern) {
                $node["value"] = $valuePattern.Current.Value
            }
        } catch {}
    }

    if ($patterns.Count -gt 0) {
        $node["patterns"] = $patterns
    }

    # Recurse into children: a single FindAll replaces the RawViewWalker loop,
    # which cost two cross-process calls per child for the same raw view.
    $children = @()
    try {
        $childElements = $Element.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)

        foreach ($child in $childElements) {
            $childNode = Get-AccessibilityTree -Element $child -MaxDepth $MaxDepth `
                -CurrentDepth ($CurrentDepth + 1) -RefCounter $RefCounter `
                -InteractiveOnly $InteractiveOnly -Compact $Compact
            if ($childNode) {
                $children += $childNode
            }
        }
    } catch {}

    $node["children"] = @($children)

    # Apply interactive filter: skip non-interactive elements with no interactive children
    if ($InteractiveOnly) {
        $hasInteractiveChildren = $children.Count -gt 0
        if (-not $isInteractive -and -not $hasInteractiveChildren) {
            return $null
        }
    }

    # Apply compact filter: remove empty structural elements
    if ($Compact -and (Test-IsEmptyStructural $node)) {
        return $null
    }

    return $node
}

function Invoke-Snapshot {
    param($Params)

    # Resolve the scope selector before the ref map is replaced, so that a
    # snapshot can be scoped to a @ref taken from the previous snapshot.
    $scopeRoot = $null
    if ($Params.selector) {
        $scopeRoot = Find-Element -Selector $Params.selector
        if (-not $scopeRoot) {
            throw "Could not find element for snapshot: $($Params.selector)"
        }
    }

    $script:RefMap = @{}
    $script:WasTruncated = $false
    $script:SnapshotNodes = 0
    $script:SnapshotStart = Get-Date
    $script:LastProgressAt = Get-Date
    $refCounter = [ref]0
    $script:SnapshotId = [guid]::NewGuid().ToString().Substring(0, 8)

    $maxDepth = if ($null -ne $Params.max_depth) { [int]$Params.max_depth } else { 10 }
    $interactiveOnly = if ($null -ne $Params.interactive_only) { $Params.interactive_only } else { $false }
    $compact = if ($null -ne $Params.compact) { $Params.compact } else { $false }
    $focused = if ($null -ne $Params.focused) { $Params.focused } else { $false }

    # Determine root element(s)
    if ($scopeRoot) {
        $tree = Get-AccessibilityTree -Element $scopeRoot -MaxDepth $maxDepth `
            -RefCounter $refCounter -InteractiveOnly $interactiveOnly -Compact $compact
    } elseif ($focused) {
        # Start from focused element
        $root = [System.Windows.Automation.AutomationElement]::FocusedElement
        if (-not $root) {
            throw "No focused element found"
        }
        $tree = Get-AccessibilityTree -Element $root -MaxDepth $maxDepth `
            -RefCounter $refCounter -InteractiveOnly $interactiveOnly -Compact $compact
    } else {
        # Use RootElement (desktop) and walk with RawViewWalker
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $tree = Get-AccessibilityTree -Element $root -MaxDepth $maxDepth `
            -RefCounter $refCounter -InteractiveOnly $interactiveOnly -Compact $compact
    }

    return @{
        snapshot_id = $script:SnapshotId
        ref_count = $refCounter.Value
        truncated = $script:WasTruncated
        max_depth = $maxDepth
        root = $tree
    }
}
