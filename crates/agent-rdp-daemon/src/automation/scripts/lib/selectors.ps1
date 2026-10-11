# selectors.ps1 - selector parsing and node lookup over the COM model

# Find a node for a selector in a model. Returns @{ Node = ...; Path = ... } or null.
# Forms: @ref (from the previous snapshot), #AutomationId, .ClassName, ~*name*,
# role:Type[name], or an exact name.
function Find-UiaNode {
    param([string]$Selector, $Root)

    if ([string]::IsNullOrEmpty($Selector)) { throw "Selector cannot be empty" }

    # A bare prefix is always malformed; reject it instead of searching for it.
    if ($Selector -match '^[@#~.]$' -or $Selector -eq 'role:') {
        throw "Malformed selector: $Selector"
    }

    if ($Selector -match '^@e?(\d+)$') {
        $ref = [int]$Matches[1]

        if ($null -eq $script:SnapshotId -or $script:RefMap.Count -eq 0) {
            throw "No snapshot taken. Run automate snapshot first before using @ref selectors."
        }

        if (-not $script:RefMap.ContainsKey($ref)) {
            throw "Invalid ref: $Selector not found in snapshot (snapshot has $($script:RefMap.Count) elements, snapshot_id=$($script:SnapshotId))"
        }

        $entry = $script:RefMap[$ref]

        Write-ComDebug ("ref @e" + $ref + " -> role=" + $entry["Role"] + " name=[" + $entry["Name"] + "] id=[" + $entry["AutomationId"] + "]")

        return Find-UiaNodeInModel -Node $Root -Path @() -Match {
            param($n)
            return ($n.Role -eq $entry["Role"] -and
                    [string]$n.Name -eq [string]$entry["Name"] -and
                    [string]$n.AutomationId -eq [string]$entry["AutomationId"])
        }
    }

    if ($Selector -match '^#(.+)$') {
        $automationId = $Matches[1]
        return Find-UiaNodeInModel -Node $Root -Path @() -Match { param($n) return ($n.AutomationId -eq $automationId) }
    }

    if ($Selector -match '^\.(.+)$') {
        $className = $Matches[1]
        return Find-UiaNodeInModel -Node $Root -Path @() -Match { param($n) return ($n.ClassName -eq $className) }
    }

    if ($Selector -match '^~(.+)$') {
        $namePattern = $Matches[1]
        return Find-UiaNodeInModel -Node $Root -Path @() -Match { param($n) return ($n.Name -like $namePattern) }
    }

    if ($Selector -match '^role:(\w+)\[(.+)\]$') {
        $roleName = $Matches[1]
        $elementName = $Matches[2]
        return Find-UiaNodeInModel -Node $Root -Path @() -Match { param($n) return ($n.Role -eq $roleName -and $n.Name -eq $elementName) }
    }

    return Find-UiaNodeInModel -Node $Root -Path @() -Match { param($n) return ($n.Name -eq $Selector) }
}

# Resolve a selector against a fresh walk. The node carries Id, which addresses the
# element that walk stored, so actions use COM patterns on it.
function Find-UiaNodeTarget {
    param([string]$Selector)

    $model = Get-UiaModel
    $match = Find-UiaNode -Selector $Selector -Root $model

    if ($null -eq $match) { throw "Element not found: $Selector" }

    Write-ComDebug ("selector " + $Selector + " -> id=" + $match["Node"].Id + " role=" + $match["Node"].Role + " name=[" + $match["Node"].Name + "]")

    return $match
}
