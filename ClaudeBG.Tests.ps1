<#
  Pester suite for ClaudeBG.ps1.   Run:  Invoke-Pester

  Two of these are CRITICAL and exist because their failure is silent:

    * Get-ClaudeDesktopProcess must never match ~\.local\bin\claude.exe. That
      path is the Claude Code CLI, and matching it means the kill path ends the
      user's own terminal session.

    * Invoke-Restore must delete the patch marker AND both .orig backups.
      Leaving them behind is what made ".orig exists" an unusable patch signal:
      after a restore it reported "patched" forever and auto-heal never ran again.

  Loading this file depends on ClaudeBG.ps1 being dot-sourceable, which is why
  the trailing switch there is guarded.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'ClaudeBG.ps1')
}

Describe 'Get-LaunchPlan' {
    # Pure: no disk, no processes, no Node, no Claude install. Every branch of
    # the launcher is decided here, so this is where the launcher gets tested.

    It 'returns Fail when no install was found' {
        Get-LaunchPlan -AppDir ''  -PatchState 'Patched' -ClaudeRunning $false -NoHeal $false | Should -Be 'Fail'
        Get-LaunchPlan -AppDir $null -PatchState 'Patched' -ClaudeRunning $false -NoHeal $false | Should -Be 'Fail'
    }

    It 'returns Launch when patched and Claude is closed' {
        Get-LaunchPlan -AppDir 'C:\app-1' -PatchState 'Patched' -ClaudeRunning $false -NoHeal $false | Should -Be 'Launch'
    }

    It 'returns NoOp when patched and Claude is already running' {
        Get-LaunchPlan -AppDir 'C:\app-1' -PatchState 'Patched' -ClaudeRunning $true -NoHeal $false | Should -Be 'NoOp'
    }

    It 'returns Heal when <state> and healing is allowed' -ForEach @(
        @{ state = 'Unpatched' }
        @{ state = 'Stale' }
    ) {
        Get-LaunchPlan -AppDir 'C:\app-1' -PatchState $state -ClaudeRunning $false -NoHeal $false | Should -Be 'Heal'
    }

    It 'heals regardless of whether Claude is running' {
        # Invoke-Patch stops Claude itself, so a running app is not a reason to skip.
        Get-LaunchPlan -AppDir 'C:\app-1' -PatchState 'Stale' -ClaudeRunning $true -NoHeal $false | Should -Be 'Heal'
    }

    It 'NEVER returns Heal when NoHeal is set' -ForEach @(
        @{ state = 'Unpatched'; running = $true  }
        @{ state = 'Unpatched'; running = $false }
        @{ state = 'Stale';     running = $true  }
        @{ state = 'Stale';     running = $false }
    ) {
        # The second tray instance passes -NoHeal. If this ever returns Heal it
        # kills the running Claude with no window to explain the 20-second pause.
        Get-LaunchPlan -AppDir 'C:\app-1' -PatchState $state -ClaudeRunning $running -NoHeal $true |
            Should -Not -Be 'Heal'
    }

    It 'returns WarnAndLaunch when unpatched, NoHeal, and Claude is closed' {
        Get-LaunchPlan -AppDir 'C:\app-1' -PatchState 'Unpatched' -ClaudeRunning $false -NoHeal $true |
            Should -Be 'WarnAndLaunch'
    }

    It 'returns WarnOnly when unpatched, NoHeal, and Claude is already running' {
        Get-LaunchPlan -AppDir 'C:\app-1' -PatchState 'Unpatched' -ClaudeRunning $true -NoHeal $true |
            Should -Be 'WarnOnly'
    }
}

Describe 'Get-ClaudeDesktopProcess' {

    BeforeAll { $fakeRoot = 'C:\Users\Test\AppData\Local\AnthropicClaude' }

    It 'CRITICAL: never matches the Claude Code CLI' {
        # ~\.local\bin\claude.exe is this repo's own terminal session. A filter
        # like `Get-Process claude` would match it and Stop-ClaudeDesktop would
        # end the session the developer is working in.
        Mock Get-Process {
            @(
                [pscustomobject]@{ Name = 'claude'; Path = 'C:\Users\Test\.local\bin\claude.exe' }
                [pscustomobject]@{ Name = 'claude'; Path = 'C:\Users\Test\AppData\Local\AnthropicClaude\app-1.2.3\claude.exe' }
            )
        }

        $found = Get-ClaudeDesktopProcess -Root $fakeRoot

        $found.Count | Should -Be 1
        $found[0].Path | Should -BeLike '*AnthropicClaude*'
        @($found | Where-Object { $_.Path -like '*.local\bin*' }).Count | Should -Be 0
    }

    It 'returns an empty array when nothing matches' {
        Mock Get-Process { @([pscustomobject]@{ Name = 'notepad'; Path = 'C:\Windows\notepad.exe' }) }
        @(Get-ClaudeDesktopProcess -Root $fakeRoot).Count | Should -Be 0
    }

    It 'tolerates processes with no readable Path' {
        # Protected system processes expose a null Path; the filter must not blow up.
        Mock Get-Process { @([pscustomobject]@{ Name = 'System'; Path = $null }) }
        { Get-ClaudeDesktopProcess -Root $fakeRoot } | Should -Not -Throw
        @(Get-ClaudeDesktopProcess -Root $fakeRoot).Count | Should -Be 0
    }
}

Describe 'Patch marker' {

    BeforeEach {
        $marker = Join-Path $TestDrive "marker-$([guid]::NewGuid().ToString('N')).json"
    }

    It 'reports Unpatched when the marker is absent' {
        Get-PatchState -AppDir 'C:\root\app-1.2.234' -Path $marker | Should -Be 'Unpatched'
    }

    It 'reports Patched when the marker names the active version' {
        Write-PatchMarker -AppDir 'C:\root\app-1.2.234' -Path $marker
        Get-PatchState -AppDir 'C:\root\app-1.2.234' -Path $marker | Should -Be 'Patched'
    }

    It 'reports Stale after Claude updates into a new version folder' {
        # This is the state the whole auto-heal design runs on.
        Write-PatchMarker -AppDir 'C:\root\app-1.2.234' -Path $marker
        Get-PatchState -AppDir 'C:\root\app-1.34493.1' -Path $marker | Should -Be 'Stale'
    }

    It 'treats a corrupt marker as Unpatched rather than throwing' {
        # A crash mid-write leaves truncated JSON. Repairing when we did not need
        # to is cheap and visible; skipping a repair we did need is silent.
        Set-Content -Path $marker -Value '{ "version": "app-1.2' -NoNewline
        { Get-PatchState -AppDir 'C:\root\app-1.2.234' -Path $marker } | Should -Not -Throw
        Get-PatchState -AppDir 'C:\root\app-1.2.234' -Path $marker | Should -Be 'Unpatched'
    }

    It 'treats valid JSON with no version field as Unpatched' {
        Set-Content -Path $marker -Value '{ "patchedAt": "2026-01-01" }' -NoNewline
        Get-PatchState -AppDir 'C:\root\app-1.2.234' -Path $marker | Should -Be 'Unpatched'
    }

    It 'writes BOM-less UTF-8' {
        # Same trap as config.json: a leading U+FEFF breaks JSON.parse on the
        # Node side, and Set-Content -Encoding UTF8 always emits one.
        Write-PatchMarker -AppDir 'C:\root\app-1.2.234' -Path $marker
        [System.IO.File]::ReadAllBytes($marker)[0] | Should -Not -Be 0xEF
    }

    It 'records the version that was patched' {
        Write-PatchMarker -AppDir 'C:\root\app-1.2.234' -Path $marker
        (Read-PatchMarker -Path $marker).version | Should -Be 'app-1.2.234'
    }

    It 'Remove-PatchMarker is safe to call when nothing is there' {
        { Remove-PatchMarker -Path $marker } | Should -Not -Throw
    }
}

Describe 'Get-ActiveAppDir' {

    BeforeEach {
        $root = Join-Path $TestDrive "root-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'app-1.2.234\resources')   | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'app-1.34493.1\resources') | Out-Null
        Set-Content (Join-Path $root 'app-1.2.234\resources\app.asar')   'x'
        Set-Content (Join-Path $root 'app-1.34493.1\resources\app.asar') 'x'
    }

    It 'CRITICAL: trusts RELEASES over the highest version number' {
        # The whole reason this function exists. app-1.34493.1 was installed while
        # app-1.2.234 was still the one Claude actually launched. Picking the
        # highest number patches a folder nobody runs, and the background then
        # silently never appears.
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'packages') | Out-Null
        Set-Content (Join-Path $root 'packages\RELEASES') `
            "0000000000000000000000000000000000000000 AnthropicClaude-1.2.234-full.nupkg 12345"

        Get-ActiveAppDir -Root $root | Should -Be (Join-Path $root 'app-1.2.234')
    }

    It 'falls back to a NUMERIC version sort when RELEASES is absent' {
        # Never a string sort: "app-1.34493.1" sorts BELOW "app-1.2.234" as text,
        # which is the exact bug the [version] cast exists to avoid.
        Get-ActiveAppDir -Root $root | Should -Be (Join-Path $root 'app-1.34493.1')
    }

    It 'ignores a RELEASES entry whose folder is not installed' {
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'packages') | Out-Null
        Set-Content (Join-Path $root 'packages\RELEASES') `
            "0000000000000000000000000000000000000000 AnthropicClaude-9.9.9-full.nupkg 12345"

        Get-ActiveAppDir -Root $root | Should -Be (Join-Path $root 'app-1.34493.1')
    }

    It 'ignores a version folder with no app.asar in it' {
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'app-2.0.0') | Out-Null
        Get-ActiveAppDir -Root $root | Should -Be (Join-Path $root 'app-1.34493.1')
    }

    It 'throws when there is no install at all' {
        { Get-ActiveAppDir -Root (Join-Path $TestDrive 'nothing-here') } |
            Should -Throw '*No Claude Desktop install found*'
    }
}

Describe 'Invoke-Restore' {
    # Invoke-Restore reaches the marker and the shortcut through the script-level
    # defaults, which a test cannot reassign from outside the defining scope. So
    # those two are asserted as behaviour (Should -Invoke) and the file deletions,
    # which run against a fixture path, are asserted directly. Mocking them also
    # keeps the suite from touching the real Start Menu, which an earlier version
    # of this file did.

    BeforeEach {
        $appDir = Join-Path $TestDrive "app-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path (Join-Path $appDir 'resources') | Out-Null

        Set-Content (Join-Path $appDir 'resources\app.asar')      'patched'
        Set-Content (Join-Path $appDir 'resources\app.asar.orig') 'pristine'
        Set-Content (Join-Path $appDir 'claude.exe')              'patched'
        Set-Content (Join-Path $appDir 'claude.exe.orig')         'pristine'

        Mock Get-ActiveAppDir    { $appDir }
        Mock Stop-ClaudeDesktop  { }
        Mock Start-ClaudeDesktop { }
        Mock Remove-PatchMarker  { }
        Mock Remove-Shortcut     { }
        Mock Write-Host          { }
    }

    It 'restores the pristine files over the patched ones' {
        Invoke-Restore
        Get-Content (Join-Path $appDir 'resources\app.asar') -Raw | Should -Match 'pristine'
        Get-Content (Join-Path $appDir 'claude.exe')         -Raw | Should -Match 'pristine'
    }

    It 'CRITICAL: deletes both .orig backups' {
        # Leaving these behind made ".orig exists" report patched forever after a
        # restore, so auto-heal never ran again. It also broke the README's
        # "-Restore puts them back exactly" and stranded the backup disk space.
        Invoke-Restore
        Test-Path (Join-Path $appDir 'resources\app.asar.orig') | Should -BeFalse
        Test-Path (Join-Path $appDir 'claude.exe.orig')         | Should -BeFalse
    }

    It 'CRITICAL: clears the patch marker' {
        Invoke-Restore
        Should -Invoke Remove-PatchMarker -Times 1 -Exactly
    }

    It 'removes the Start Menu shortcut' {
        Invoke-Restore
        Should -Invoke Remove-Shortcut -Times 1 -Exactly
    }

    It 'restores before deleting, so a crash mid-restore cannot lose the originals' {
        Invoke-Restore
        Get-Content (Join-Path $appDir 'claude.exe') -Raw | Should -Match 'pristine'
    }

    It 'does not throw when the backups are already gone' {
        Remove-Item (Join-Path $appDir 'resources\app.asar.orig') -Force
        Remove-Item (Join-Path $appDir 'claude.exe.orig') -Force
        { Invoke-Restore } | Should -Not -Throw
    }
}

Describe 'Start Menu shortcut' {
    # Real COM round-trips, but always against a TestDrive path - never the real
    # per-user Start Menu.

    BeforeEach {
        $lnk    = Join-Path $TestDrive "ClaudeBG-$([guid]::NewGuid().ToString('N')).lnk"
        $target = Join-Path $TestDrive 'ClaudeBGTray.exe'
        Set-Content $target 'stub'
    }

    It 'writes a .lnk pointing at the tray exe, then removes it' {
        Install-Shortcut -Path $lnk -Target $target
        Test-Path $lnk | Should -BeTrue
        Get-ShortcutTarget -Path $lnk | Should -Be $target

        Remove-Shortcut -Path $lnk
        Test-Path $lnk | Should -BeFalse
    }

    It 'sets no icon override, so the exe icon is inherited' {
        # csc /win32icon puts the icon in the exe. An IconLocation here would be a
        # second copy of the artwork that nothing keeps in sync.
        Install-Shortcut -Path $lnk -Target $target
        $shell = New-Object -ComObject WScript.Shell
        try   { $shell.CreateShortcut($lnk).IconLocation | Should -Match '^\s*,\s*0\s*$' }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    It 'points WorkingDirectory at the folder holding the exe' {
        Install-Shortcut -Path $lnk -Target $target
        $shell = New-Object -ComObject WScript.Shell
        try   { $shell.CreateShortcut($lnk).WorkingDirectory | Should -Be (Split-Path $target -Parent) }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    It 'Get-ShortcutTarget returns null when nothing is installed' {
        Get-ShortcutTarget -Path $lnk | Should -BeNullOrEmpty
    }

    It 'Remove-Shortcut is safe to call twice' {
        Install-Shortcut -Path $lnk -Target $target
        Remove-Shortcut -Path $lnk
        { Remove-Shortcut -Path $lnk } | Should -Not -Throw
    }

    It 'overwrites an existing shortcut rather than failing' {
        Install-Shortcut -Path $lnk -Target $target
        { Install-Shortcut -Path $lnk -Target $target } | Should -Not -Throw
        Get-ShortcutTarget -Path $lnk | Should -Be $target
    }
}
