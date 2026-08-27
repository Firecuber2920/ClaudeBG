# ClaudeBG

Put your own background image behind **Claude Desktop on Windows**.

Claude Desktop has no setting for this. ClaudeBG adds one. You pick a picture,
choose how strongly it shows through, and the sidebar and the message box stay
crisp and readable on top of it.

---

## Please read this first

This tool **modifies your installed copy of Claude Desktop**. That is the only
way to do it, and it has real consequences you should understand before you
start. None of this is hidden from you:

- **It edits Claude Desktop's program files.** It makes a backup of the
  originals first, and `-Restore` puts them back exactly.
- **It turns off one of Claude Desktop's tamper checks**, and that breaks the
  digital signature on `claude.exe`. Windows will still run the app, but the app
  can no longer prove to itself that its files are untouched. This is a genuine
  security tradeoff. If that is not a trade you want to make, stop here.
- **It is not made or supported by Anthropic.** If Claude Desktop misbehaves
  while patched, undo the patch before reporting a bug to anyone.
- **Claude Desktop updates will wipe it.** That is harmless — you just re-apply
  it. See [When Claude updates](#when-claude-updates).
- **It only touches your own machine.** Nothing is uploaded anywhere, and your
  picture never leaves your computer.

If anything goes wrong at any point, this puts everything back the way it was:

```powershell
.\ClaudeBG.ps1 -Restore
```

---

## What you need first

**1. Claude Desktop for Windows**, already installed and run at least once.

**2. Node.js.** The installer uses two small tools that come with it. If you
don't have it, get the "LTS" version from [nodejs.org](https://nodejs.org/) and
click through the installer with the default options.

To check whether you already have it, open PowerShell (press <kbd>Win</kbd>, type
`PowerShell`, press Enter) and type:

```powershell
node --version
```

If you see a version number like `v22.11.0`, you're set. If you see an error
about `node` not being recognised, install Node.js and then **close and reopen
PowerShell** before continuing.

You do **not** need administrator rights.

---

## Installing

### Step 1 — Open PowerShell in this folder

In File Explorer, open the folder containing `ClaudeBG.ps1`. Right-click on an
empty part of the folder and choose **"Open in Terminal"** (on some versions of
Windows it's "Open PowerShell window here").

You should see a prompt showing the folder path. Everything below gets typed
there.

### Step 2 — Unblock the files

Windows marks files downloaded from the internet as untrusted and refuses to run
them. This clears that mark for this folder only:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

Nothing is printed if it works. That's normal.

### Step 3 — Apply the patch

```powershell
powershell -ExecutionPolicy Bypass -File .\ClaudeBG.ps1 -Patch
```

> **Why the long command?** Windows blocks PowerShell scripts by default.
> `-ExecutionPolicy Bypass` tells it to allow this one script, just this once. It
> does not change any setting on your computer.

**Claude Desktop will close and reopen during this.** That's expected — it can't
be running while its files are being edited. The whole thing takes about a
minute, and you'll see progress as it goes:

```
  Active install: C:\Users\you\AppData\Local\AnthropicClaude\app-1.37937.1
  Claude Desktop closed.
  Disabling asar integrity fuse (breaks Authenticode signature - expected)...
  Fuse disabled.
  Extracting pristine app.asar...
  Patched index.pre.js (IPC image provider).
  Patched mainView.js (CSS injector).
  Repacking...
  Installed patched app.asar.
  Patch complete. Claude Desktop restarted.
```

If it stops with a red error message instead, nothing has been half-applied —
the script checks as it goes and stops rather than leaving a mess. See
[If something goes wrong](#if-something-goes-wrong).

### Step 4 — Pick your background

```powershell
powershell -ExecutionPolicy Bypass -File .\ClaudeBG.ps1 -SetImage "C:\Users\you\Pictures\forest.jpg" -Opacity 0.65
```

Put the full path to your picture in the quotes. JPG, PNG, BMP and GIF all work,
and the picture can be any size — it gets resized automatically.

`-Opacity` is how strongly the picture shows through, from `0` (invisible) to
`1` (full strength). **0.65 is a good place to start.** Claude Desktop restarts
once more and your background appears.

That's it. You're done.

---

## Day-to-day use: type "ClaudeBG"

After `-Patch`, press <kbd>Win</kbd>, type **`ClaudeBG`**, press Enter.

That opens Claude Desktop **and** starts the small ClaudeBG icon in your
notification area, in one go. Use it instead of Claude's own icon and your
background is simply always on — there is nothing to remember to turn on.

It also repairs itself. If Claude Desktop updated since you last used it, a
notification tells you it's reapplying your background, it does the work, and
then Claude opens with the picture already there. You do not have to notice that
anything happened.

Type it again while everything is already running and it just brings Claude up.
No dialog, no second icon.

> Windows can take a few seconds to index a brand-new Start Menu entry. If
> searching finds nothing immediately after `-Patch`, wait a moment and try
> again.

To have the entry without the rest, or to check on it:

```powershell
.\ClaudeBG.ps1 -InstallShortcut
.\ClaudeBG.ps1 -RemoveShortcut
```

`-Patch` installs it for you, and re-installs it every time it runs — so if you
move this folder, running `-Patch` again fixes the shortcut. `-Restore` removes
it. That does mean deleting the entry by hand won't stick while ClaudeBG is
still patched; use `-Restore` if you want it gone for good.

## The tray app

You can also double-click **`ClaudeBGTray.exe`** directly. Either way you get a
small round icon in your notification area (bottom-right, near the clock), and
right-clicking it gives you everything:

| Menu item | What it does |
|---|---|
| **Change background…** | Pick a different picture |
| **Opacity** | 15% / 25% / 35% / 50% / 65% |
| **Reapply patch (after a Claude update)** | Use this after Claude Desktop updates |
| **Restore original Claude** | Undo everything |
| **Status…** | Show what's currently set up |
| **Exit** | Close the tray app (your background stays) |

Changing the background or the opacity restarts Claude Desktop, because the
picture is loaded when the window opens.

> **Can't see the icon?** Windows 11 hides new notification icons by default.
> Click the **`^`** arrow next to the clock — it'll be in there. Drag it down
> onto the taskbar to keep it visible.

> **Windows warns you about the file?** `ClaudeBGTray.exe` isn't signed by a
> registered software publisher, so SmartScreen may show a blue "Windows
> protected your PC" box. Click **More info → Run anyway**. If you'd rather not,
> skip the tray app entirely — every feature is available as a command.

---

## When Claude updates

Claude Desktop installs updates into a brand-new folder, which used to mean your
background just quietly stopped appearing one day.

**You no longer have to do anything about this.** If you open Claude by typing
`ClaudeBG`, it notices the update, tells you it's reapplying your background,
does it, and then opens Claude. The first launch after an update takes an extra
20 seconds or so; every other launch is unaffected.

Two things to know: the repair needs Node.js, and it closes and reopens Claude
Desktop as part of the work. If Node isn't available, Claude still opens — just
without the background — and a message explains why.

To check the state at any time:

```powershell
.\ClaudeBG.ps1 -Status
```

The `patch` line reads `current`, `STALE` (an update happened; the next launch
will fix it), or `not patched`.

If you'd rather repair it by hand:

**Tray app:** right-click the icon → **Reapply patch**

**Or by command:**

```powershell
powershell -ExecutionPolicy Bypass -File .\ClaudeBG.ps1 -Patch
```

Your picture and opacity settings are remembered — you only need to re-patch.

---

## Removing it

```powershell
powershell -ExecutionPolicy Bypass -File .\ClaudeBG.ps1 -Restore
```

This restores the original `claude.exe` and program files from the backups made
during install, including the signature and the tamper check. Claude Desktop
goes back to normal.

---

## If something goes wrong

Start by asking the tool what it thinks is happening:

```powershell
powershell -ExecutionPolicy Bypass -File .\ClaudeBG.ps1 -Status
```

```
ClaudeBG status
  active install : C:\Users\you\AppData\Local\AnthropicClaude\app-1.37937.1
  app.asar       : 31.6 MB
  backups        : asar=True  exe=True
  integrity fuse : Disabled
  signature      : HashMismatch
  background     : C:\Users\you\AppData\Roaming\ClaudeBG\current.jpg  (642 KB)
  style          : C:\Users\you\AppData\Roaming\ClaudeBG\bg.css  (6504 bytes)
  last page load : ok - image 642KB (image/jpeg), opacity 0.65, bg.css 6504 bytes
  config         : { "opacity": 0.65 }
```

`integrity fuse : Disabled` and `signature : HashMismatch` are **expected** while
patched — that's the tradeoff described at the top, not a fault.

The line to read is **`last page load`**. Claude Desktop writes it every time its
window opens, and it says whether the background actually made it onto the page.

| What you see | What it means | What to do |
|---|---|---|
| `...running scripts is disabled on this system` | Windows blocked the script | Use the full `powershell -ExecutionPolicy Bypass -File ...` form |
| `Node.js is required ... was not found on PATH` | Node.js missing, or PowerShell was open before you installed it | Install Node.js, then close and reopen PowerShell |
| `Could not disable the integrity fuse` | Claude Desktop is still running | Fully quit Claude — check the notification area — and re-run |
| `insertCSS anchor not found` / `index.pre.js not found` | A Claude update changed the app's internals | The tool needs updating; run `-Restore` in the meantime |
| Background just isn't there | Usually a Claude update wiped the patch | Re-run `-Patch` |
| `last page load : FAILED - ...too large...` | Your picture made too big a payload | Re-run `-SetImage`, which resizes automatically |
| Nothing in the taskbar after running the tray | Windows 11 hid the icon | Click the `^` arrow by the clock |
| Claude Desktop won't start at all | — | `-Restore`, which is exactly what it's for |

---

## Making it look how you want

Beyond the picture and the opacity slider, the whole look lives in a plain text
file you can edit:

```
%APPDATA%\ClaudeBG\bg.css
```

(Paste that into File Explorer's address bar to get there. `%APPDATA%` is a
shortcut Windows understands.)

Open it in Notepad, change something, save, then press <kbd>Ctrl</kbd>+<kbd>R</kbd>
in Claude Desktop to see it. No reinstalling, no restart. If you make a mess of
it, delete the file and re-run `-Patch` to get the original back.

The file is commented throughout, and the one value most worth touching is
marked **`THIS IS THE KNOB`** — it controls how much the middle column is dimmed
behind your messages. Raise it if long conversations feel like hard work; lower
it to let more of the picture through.

---

## All the commands

| Command | What it does |
|---|---|
| `-Patch` | Apply (or re-apply) the patch. Needs Node.js |
| `-SetImage "<path>" -Opacity <0-1>` | Set the picture and its strength |
| `-SetOpacity <0-1>` | Change strength only, leaving the picture alone |
| `-Status` | Show current state and the last page-load health line |
| `-Restore` | Undo everything |
| `-Probe` | Developer tool: record claude.ai's live page structure |
| `-NoRestart` | Add to `-SetImage`/`-SetOpacity` to skip the restart (press <kbd>Ctrl</kbd>+<kbd>R</kbd> yourself) |

---
---

# For maintainers

Everything below is about *why* the code is shaped the way it is. You don't need
any of it to use ClaudeBG.

## Files

| path | what |
|---|---|
| `ClaudeBG.ps1` | everything: `-Patch`, `-Launch`, `-SetImage`, `-SetOpacity`, `-Probe`, `-Status`, `-InstallShortcut`, `-RemoveShortcut`, `-Restore` |
| `bg.css` | the art direction. Copied to `%APPDATA%\ClaudeBG\` on `-Patch`, read at page load, so edits apply with **Ctrl+R** — no repack |
| `ClaudeBGTray.cs` / `ClaudeBGTray.exe` | tray front-end (WinForms, .NET Framework 4.8) |
| `ClaudeBG.ico` | the icon, built into the exe. Regenerate with `tools\make-icon.ps1` — don't hand-edit it |
| `tools/make-icon.ps1` | draws the icon at 16/32/48/256 and writes the `.ico` |
| `ClaudeBG.Tests.ps1` | Pester suite. Run `Invoke-Pester` |
| `demo-background.png` | a generated gradient, handy for testing without using a personal photo |
| `spike/*.png` | screenshots from each step of the investigation — **gitignored**, since they show the sidebar with real conversation titles |

Files it writes outside this folder:

| path | what |
|---|---|
| `%APPDATA%\ClaudeBG\patched.json` | which `app-<version>` is patched. This is how a stale patch is detected |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClaudeBG.lnk` | the Start Menu entry |

Both are removed by `-Restore`, along with the `.orig` backups.

Rebuild the tray app with the compiler Windows already ships — no SDK needed.
`/win32icon` is what puts the icon on the exe, the Start Menu entry, the taskbar
and Alt-Tab, so don't drop it:

```powershell
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe `
  /out:ClaudeBGTray.exe /win32icon:ClaudeBG.ico `
  /reference:System.dll /reference:System.Drawing.dll `
  /reference:System.Windows.Forms.dll tray\ClaudeBGTray.cs
```

Run the tests before committing changes to `ClaudeBG.ps1`:

```powershell
Invoke-Pester
```

Two of them are marked CRITICAL. One asserts that the process filter never
matches `~\.local\bin\claude.exe` — that's the Claude Code CLI, and matching it
would kill your own terminal session. The other asserts `-Restore` deletes the
patch marker and both `.orig` backups, because leaving them behind makes ClaudeBG
believe it is patched when it isn't, forever.

## How it works, and why it works this way

Getting here required working around five hard constraints, each verified
empirically rather than assumed. If you change this code, respect them:

**1. The chat UI isn't in the app.** `index.html` inside `app.asar` says so on
line 1: *"this is the html for app title bar and error UI. everything else gets
loaded from claude.ai"*. Styling `index.html` gets you a themed title bar and
nothing else. The injection has to reach a remote page.

**2. `app.asar` is sealed by an Electron integrity fuse.** `claude.exe` ships with
`EnableEmbeddedAsarIntegrityValidation` enabled — the executable holds a hash of
the archive and validates it at launch. Any repack, even a byte-identical no-op
roundtrip, changes the header hash and the app dies at startup with:

```
FATAL:electron\shell\common\asar\asar_util.cc:148]
Integrity check failed for asar archive entry '<header>'
```

So `-Patch` disables that fuse first. **This breaks the executable's Authenticode
signature and removes a tamper check** — that is a real security tradeoff you are
accepting, and it is why `-Restore` exists.

**3. Debug flags are refused.** The obvious alternative — attaching over the
DevTools Protocol — is blocked. `index.pre.js` carries a hardcoded blocklist
(`remote-debugging-port`, `remote-debugging-pipe`, `disable-web-security`,
`host-rules`, …) and the app exits with:

```
Claude: refusing to start — a debugging or network-override switch is present
on the command line.
```

**4. CSP blocks external files, but allows `data:`.** Inside the claude.ai page:

| approach | result |
|---|---|
| `@import url("file:///…css")` | blocked |
| `background-image: url("file:///…png")` | blocked |
| `background-image: url("data:image/png;base64,…")` | **works** |
| `require("fs")` in the preload | unavailable (sandboxed) |

That combination dictates the design. The preload can inject CSS but can't read
files; the main process can read files but can't inject CSS. So:

```
main process (index.pre.js)          preload (mainView.js)
  fs.readFileSync(current.jpg)         ipcRenderer.invoke("claudebg:get")
  → base64                    ──IPC──▶ → webFrame.insertCSS(data: URI)
```

The payoff: because the image is read from disk **at page load**, swapping
backgrounds later never repacks anything. `-SetImage` just rewrites one JPEG.
Verified — the `app.asar` hash is identical before and after a swap.

**5. The payload has a size ceiling, and it fails silently.** `insertCSS` drops
an oversized rule without throwing: `--claudebg-img` simply never gets defined,
and you get no background and no error. A 15 MB PNG (~20 MB of base64) sat right
past that ceiling. `-SetImage` now downscales to 2560px on the long edge and
re-encodes JPEG — typically ~600 KB — and the renderer writes a health line to
`status.log` at each page load saying whether the rule actually landed. `-Status`
reads it back.

## The image goes behind the UI, not over it

The first version painted the image on top of everything with `html::after` at
`z-index: 2147483647`. That caps usable opacity at about 0.35: at 0.65 every
glyph is only 35% of itself. And you cannot win it back with `z-index`, because
`html::after` lives in the root stacking context while `.dframe-sidebar` and
`.dframe-content` both set `isolation: isolate`, which traps any `z-index` set
inside them.

So the image moved to the canvas, and the app's two opaque full-viewport layers
were made transparent:

```
canvas ................... the image, full strength
html::before ............. scrim, opacity = 1 - --claudebg-opacity
main.dframe-content::before  reading band behind the centre column
aside.dframe-sidebar ..... frosted panel, above the image
.bg-surface-3 (composer) . frosted panel, above the image
```

The surfaces you read from are frosted rather than washed: a near-opaque fill to
keep the designed contrast ratio, `backdrop-filter: blur()` to destroy the photo
detail that fights letterforms, `saturate()` to stop the tint going muddy, and a
hairline inset ring plus a drop shadow so each panel reads as a distinct plane.
The ring is an inset `box-shadow`, not a `border`, because the composer is
`box-content` and a real border would resize it.

Message text is not a styleable surface — it is bare text whose markup is
Tailwind hashes that will not survive a redeploy. Rather than chase per-message
selectors, the whole centre column gets one soft gradient scrim on `main`'s own
pseudo-element. `bg.css` marks the single value to turn if it needs to be calmer
or bolder.

## Known limitations

- **The style is anchored to claude.ai's markup.** `bg.css` targets
  `aside.dframe-sidebar`, `main.dframe-content` and the `bg-surface-N` elevation
  tokens. Those are semantic classes rather than Tailwind hashes, so they are the
  most stable hooks available — but they are still someone else's markup. If a
  redeploy renames them the background survives and the panels stop being
  frosted. `-Probe` re-reads the live DOM so you can re-anchor in a minute.
- **Only `/new` was verified visually.** `-Probe` captures every route visited
  while it is armed, but a conversation route was never captured, so the reading
  band's width over real messages is reasoned, not measured. To check it: run
  `-Probe`, open a conversation within ~3 min, then re-read `domdump.json`.
- **Every Claude Desktop update wipes it.** Squirrel installs into a fresh
  `app-<version>` folder. Re-run `-Patch` (or the tray's "Reapply patch").
- **It will break** whenever Anthropic changes the preload's `insertCSS` call —
  the patch anchors to it, and `-Patch` fails loudly rather than silently
  corrupting anything.
- Only the main window is styled.

## Gotchas worth knowing

- The active version folder is **not** the highest-numbered one. On the machine
  this was built on, `app-1.34493.1` was installed while `app-1.2.234` was still
  running. `packages\RELEASES` is the source of truth.

- Two `claude.exe` processes may be the **Claude Code CLI**
  (`~\.local\bin\claude.exe`). Kill logic filters strictly by install path —
  otherwise you take out your own terminal session.

- Windows holds a lock on `claude.exe` briefly after exit, so the fuse write
  retries rather than failing on the first `EBUSY`.

- **`::after` does not render anywhere in this app; `::before` does.** Found by
  bisecting four test swatches — `html::before` painted, `html::after`,
  `body::before` and `body::after` did not. The original overlay used
  `html::after`, so it was one Claude release away from vanishing regardless.
  Anchor everything to `::before`.

- **`mask-image` does not clip an element that has `backdrop-filter`.** The
  reading band was meant to be a masked blur; the mask was ignored and the blur
  covered the whole chat area. Soft edges come from gradients instead.

- **Windows 11 hides new tray icons.** A first-run `NotifyIcon` goes into the
  overflow flyout behind the `^` chevron, not onto the taskbar — the app looks
  like it never started. Drag it out of the flyout, or set `IsPromoted=1` under
  `HKCU:\Control Panel\NotifyIconSettings\<id>` (match on `ExecutablePath`).

- **`Set-Content -Encoding UTF8` writes a BOM, and `JSON.parse` throws on it.**
  Node's `readFileSync(p, "utf8")` does *not* strip a leading U+FEFF, so
  `config.json` written the PowerShell way never parsed — and because the
  injected reader catches parse errors silently, every background quietly
  rendered at the hardcoded default `0.35` no matter what opacity was set. The
  config is now written with `UTF8Encoding($false)`, and the injected reader
  strips a BOM defensively. Watch for this anywhere PowerShell hands a file to
  Node.

- **`Image.FromFile` locks its source for the lifetime of the `Image`.** Setting
  the current image again — which is what an opacity change used to do — then
  saves into a file GDI+ still has open and dies with the famously unhelpful
  *"A generic error occurred in GDI+."* `-SetImage` decodes from a `MemoryStream`
  so the round-trip is safe, and `-SetOpacity` skips the image entirely.

- **A `NotifyIcon` is not a `Control`**, so it has no `BeginInvoke` for background
  work to marshal through. `ContextMenuStrip` is the tempting stand-in and it is
  wrong: its window handle only exists while the menu is open, so invoking after
  the menu closed threw on the worker thread and silently killed the tray. The
  app keeps one hidden `Control` with a forced handle for this.
