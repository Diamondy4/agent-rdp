# actions.ps1 - UI Automation actions
#
# Every action resolves its target through the COM model (selectors.ps1 /
# uia_com.ps1) and then acts through the COM pattern API on the node id. Pointer
# actions (click, context menu) use a position taken from the node's own rectangle.

function Invoke-Focus {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector
    [UiaComWalker]::FocusElement($target["Node"].Id)

    return @{ focused = $true }
}

function Invoke-Click {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector
    $node = $target["Node"]

    if (-not $node.Enabled) { throw "Element is disabled" }

    $doubleClick = if ($null -ne $Params.double_click) { $Params.double_click } else { $false }

    # Pointer actions need a position; it comes from the node's own rectangle.
    $point = Get-UiaNodeClickPoint $node
    if ($null -eq $point) {
        throw "Element has no valid bounding rectangle (may be off-screen or invisible)"
    }

    [void][MouseInput]::SetCursorPos($point["x"], $point["y"])
    Start-Sleep -Milliseconds 50

    if ($doubleClick) {
        [MouseInput]::DoubleClick()
    } else {
        [MouseInput]::LeftClick()
    }

    return @{ clicked = $true; x = $point["x"]; y = $point["y"]; double_click = $doubleClick }
}

function Invoke-ContextMenu {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector

    $point = Get-UiaNodeClickPoint $target["Node"]
    if ($null -eq $point) {
        throw "Element has no valid bounding rectangle (may be off-screen or invisible)"
    }

    [void][MouseInput]::SetCursorPos($point["x"], $point["y"])
  Start-Sleep -Milliseconds 50
    [MouseInput]::RightClick()

    return @{ context_menu = $true; x = $point["x"]; y = $point["y"] }
}

# Classic Win32 text controls accept WM_SETTEXT; used when the node exposes no
# value pattern (the COM call then throws).
function Set-UiaTextFallback {
    param($Node, [string]$Text)

    if ($Node.NativeWindowHandle -eq 0) { return $false }
    if ($Node.ClassName -notmatch '^(Edit|RichEdit|RICHEDIT|Scintilla|TextArea)') { return $false }

    [void][Win32Message]::SendMessage([IntPtr]$Node.NativeWindowHandle, [Win32Message]::WM_SETTEXT, [IntPtr]::Zero, $Text)

    return $true
}

function Invoke-Fill {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector
    $node = $target["Node"]

    try {
        [UiaComWalker]::SetElementValue($node.Id, $Params.text)
    } catch {
        if (-not (Set-UiaTextFallback -Node $node -Text $Params.text)) { throw }
    }

    return @{ filled = $true; text = $Params.text }
}

function Invoke-Clear {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector
    $node = $target["Node"]

    try {
        [UiaComWalker]::ClearElementValue($node.Id)
    } catch {
        if (-not (Set-UiaTextFallback -Node $node -Text "")) { throw }
    }

    return @{ cleared = $true }
}

function Invoke-Toggle {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector

    $desired = -1
    if ($null -ne $Params.state) { if ($Params.state) { $desired = 1 } else { $desired = 0 } }

    [UiaComWalker]::ToggleElement($target["Node"].Id, $desired)

    return @{ toggled = $true; method = "TogglePattern" }
}

function Invoke-Select {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector

    if (-not $Params.item) {
        [UiaComWalker]::SelectElement($target["Node"].Id)
        return @{ selected = $true; method = "SelectionItemPattern" }
    }

    # Item by name: select it inside the container, opening the container first when
    # the item only exists while it is expanded (combo boxes).
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $item = Find-UiaNodeInModel -Node $target["Node"] -Path @() -Match { param($n) return ($n.Name -eq $Params.item) }
        if ($null -ne $item) {
            [UiaComWalker]::SelectElement($item["Node"].Id)
            return @{ selected = $true; item = $Params.item; method = "SelectionItemPattern" }
        }

        if ($attempt -eq 0) {
            # Opening the container is an optional aid for combo boxes; a container
            # without ExpandCollapsePattern just goes straight to the retry.
            try { [UiaComWalker]::SetElementExpanded($target["Node"].Id, $true) } catch {}
            Start-Sleep -Milliseconds 250
            $target = Find-UiaNodeTarget -Selector $Params.selector
        }
    }

    throw "Item not found in container: $($Params.item)"
}

function Invoke-Expand {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector
    [UiaComWalker]::SetElementExpanded($target["Node"].Id, $true)

    return @{ expanded = $true; method = "ExpandCollapsePattern" }
}

function Invoke-Collapse {
    param($Params)

    $target = Find-UiaNodeTarget -Selector $Params.selector
    [UiaComWalker]::SetElementExpanded($target["Node"].Id, $false)

    return @{ collapsed = $true; method = "ExpandCollapsePattern" }
}

function Invoke-Scroll {
    param($Params)

    if ($Params.to_child) {
        $child = Find-UiaNodeTarget -Selector $Params.to_child
        [UiaComWalker]::ScrollElementIntoView($child["Node"].Id)
        return @{ scrolled = $true; to_child = $Params.to_child }
    }

    $target = Find-UiaNodeTarget -Selector $Params.selector
    $amount = if ($Params.amount) { [int]$Params.amount } else { 1 }
    $direction = if ($Params.direction) { $Params.direction } else { "down" }

    [UiaComWalker]::ScrollElement($target["Node"].Id, $direction, $amount)

    return @{ scrolled = $true; direction = $direction; amount = $amount }
}
# Resolve a window selector (or the foreground window) to a node in a fresh walk.
function Find-UiaWindowNode {
    param($Selector)

    $model = Get-UiaModel

    if ($Selector) {
        $match = Find-UiaNode -Selector $Selector -Root $model
        if ($null -eq $match) { throw "Window not found: $Selector" }
        return $match["Node"]
    }

    $foreground = [MouseInput]::GetForegroundWindow().ToInt64()
    $match = Find-UiaNodeInModel -Node $model -Path @() -Match { param($n) return ([int64]$n.NativeWindowHandle -eq $foreground) }
    if ($null -eq $match) { throw "Foreground window not found in the accessibility tree" }

    return $match["Node"]
}

function Invoke-Window {
    param($Params)

    $action = $Params.action

    if ($action -eq "list") {
        # Top-level windows come from a fresh walk's model.
        $model = Get-UiaModel
        $windows = @()

        foreach ($node in $model.Children) {
            if ($node.Role -ne "Window") { continue }

            $bounds = Get-UiaNodeBounds $node
            if ($null -eq $bounds) { $bounds = @{ x = -1; y = -1; width = -1; height = -1 } }

            $windows += @{
                title = $node.Name
                process_id = $node.ProcessId
                bounds = $bounds
                minimized = ($node.WindowVisualState -eq 2)
                maximized = ($node.WindowVisualState -eq 1)
            }
        }

        return @{ windows = $windows }
    }

    $window = Find-UiaWindowNode -Selector $Params.selector

    switch ($action) {
        "focus" {
            [UiaComWalker]::FocusElement($window.Id)
            return @{ action = "focus"; success = $true }
        }
        "maximize" {
            [UiaComWalker]::SetElementWindowState($window.Id, 1)
            return @{ action = "maximize"; success = $true }
        }
        "minimize" {
            [UiaComWalker]::SetElementWindowState($window.Id, 2)
            return @{ action = "minimize"; success = $true }
        }
        "restore" {
            [UiaComWalker]::SetElementWindowState($window.Id, 0)
            return @{ action = "restore"; success = $true }
        }
        "close" {
            [UiaComWalker]::CloseElementWindow($window.Id)
            return @{ action = "close"; success = $true }
        }
    }

    throw "Unknown window action: $action"
}

function Invoke-WaitFor {
    param($Params)

    $selector = $Params.selector
    $timeout = if ($Params.timeout_ms) { [int]$Params.timeout_ms } else { 30000 }
    $state = if ($Params.state) { $Params.state } else { "visible" }

    $startTime = Get-Date

    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
        if ($elapsed -gt $timeout) {
            throw "Timeout waiting for element: $selector (state: $state)"
        }

        # Heartbeat while polling: wait_for can run for tens of seconds and the
        # daemon must not read that as a dead agent.
        if ($null -eq $script:LastProgressAt -or ((Get-Date) - $script:LastProgressAt).TotalMilliseconds -gt 1000) {
            $script:LastProgressAt = Get-Date
            Send-DvcProgress -Handle $script:DvcHandle -Id $script:CurrentRequestId -Phase "wait_for" -ElapsedMs ([int]$elapsed)
        }

        $match = $null
        try {
            # Shallow walks keep polling affordable.
            $model = Get-UiaModel -MaxDepth 8
            $match = Find-UiaNode -Selector $selector -Root $model
        } catch {}

        switch ($state) {
            "visible" {
                if ($null -ne $match -and -not $match["Node"].Offscreen) { return @{ found = $true; state = $state; elapsed_ms = [int]$elapsed } }
            }
            "enabled" {
                if ($null -ne $match -and $match["Node"].Enabled) { return @{ found = $true; state = $state; elapsed_ms = [int]$elapsed } }
            }
            "gone" {
                if ($null -eq $match) { return @{ found = $true; state = $state; elapsed_ms = [int]$elapsed } }
            }
        }

        Start-Sleep -Milliseconds 250
    }
}

function Invoke-Run {
    param($Params)

    $command = $Params.command
    $commandArgs = if ($Params.args) { $Params.args -join " " } else { "" }
    $wait = if ($null -ne $Params.wait) { $Params.wait } else { $false }
    $hidden = if ($null -ne $Params.hidden) { $Params.hidden } else { $false }
    $timeoutMs = if ($Params.timeout_ms) { [int]$Params.timeout_ms } else { 10000 }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"

    # Pass the command verbatim: quoting it inside -Command re-parses the text and
    # silently drops embedded double quotes, so encode it as UTF-16LE base64.
    $fullCommand = $command
    if (-not [string]::IsNullOrEmpty($commandArgs)) {
        $fullCommand = "$command $commandArgs"
    }
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($fullCommand))
    $startInfo.Arguments = "-NoProfile -EncodedCommand $encodedCommand"
    $startInfo.WorkingDirectory = $env:USERPROFILE
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $wait
    $startInfo.RedirectStandardError = $wait
    $startInfo.CreateNoWindow = $hidden

    $process = [System.Diagnostics.Process]::Start($startInfo)

    if ($wait) {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # Wait in short slices so a long-running command can send heartbeats; the
        # overall budget behaves exactly as before.
        $runStart = Get-Date
        $exited = $false

        while (-not $process.WaitForExit(250)) {
            $elapsedRun = ((Get-Date) - $runStart).TotalMilliseconds

            if ($null -eq $script:LastProgressAt -or ((Get-Date) - $script:LastProgressAt).TotalMilliseconds -gt 1000) {
                $script:LastProgressAt = Get-Date
                Send-DvcProgress -Handle $script:DvcHandle -Id $script:CurrentRequestId -Phase "run" -ElapsedMs ([int]$elapsedRun)
            }

            if ($elapsedRun -gt $timeoutMs) { break }
        }
        if ($process.HasExited) { $exited = $true }

        if (-not $exited) {
            try { $process.Kill() } catch {}
            throw "Process timed out after $timeoutMs ms and was killed"
        }

        [void]$stdoutTask.Wait(5000)
        [void]$stderrTask.Wait(5000)

        return @{
            exit_code = $process.ExitCode
            stdout = $stdoutTask.Result
            stderr = $stderrTask.Result
        }
    } else {
        return @{
            pid = $process.Id
        }
    }
}

function Invoke-Get {
    param($Params)

    # Reads come straight from a fresh walk's model node - no live element needed.
    $target = Find-UiaNodeTarget -Selector $Params.selector
    $node = $target["Node"]

    $property = if ($Params.property) { $Params.property } else { "all" }
    $result = @{}

    if ($property -eq "all" -or $property -eq "name") { $result["name"] = $node.Name }
    if ($property -eq "all" -or $property -eq "value") { $result["value"] = $node.Value }

    if ($property -eq "all" -or $property -eq "states") {
        $result["states"] = @(Get-UiaNodeStates $node)
    }

    if ($property -eq "all" -or $property -eq "bounds") {
        $bounds = Get-UiaNodeBounds $node
        if ($null -ne $bounds) { $result["bounds"] = $bounds }
        else { $result["bounds"] = @{ x = -1; y = -1; width = -1; height = -1 } }
    }

    return $result
}

function Get-AgentStatus {
    return @{
        agent_running = $true
        agent_pid = $PID
        version = $script:Version
        capabilities = @(
            "snapshot", "invoke", "select", "toggle", "expand", "collapse",
            "context_menu", "focus", "get", "fill", "clear",
            "scroll", "window", "run", "wait_for", "status"
        )
    }
}
