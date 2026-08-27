<#
.SYNOPSIS
  ClaudeBG - custom background for Claude Desktop on Windows.

.DESCRIPTION
  Claude Desktop seals its app.asar with an Electron integrity fuse and loads the
  chat UI remotely from claude.ai. This script works around both:

    1. Disables the EnableEmbeddedAsarIntegrityValidation fuse on claude.exe
       (backing up the original exe first).
    2. Patches two files inside app.asar:
         .vite/build/index.pre.js  - main process: an IPC handler with fs access
                                     that reads your image off disk.
         .vite/build/mainView.js   - the claude.ai preload: fetches the image over
                                     IPC and injects it with webFrame.insertCSS.

  Because the image, the opacity AND the stylesheet are all read from disk at
  page load (not baked into the archive), everything except the injection points
  can be changed without repacking - just edit the file and reload the window.

  Files in %APPDATA%\ClaudeBG:
    current.jpg   the background, downscaled and re-encoded by -SetImage
    config.json   { "opacity": 0..1 }
    bg.css        the art direction; owns the whole look when present
    status.log    one line written by the renderer at each page load

  KNOWN CONSTRAINTS (all empirically verified, do not "simplify" these away):
    - CSP blocks file:// @import AND file:// url() images. data: URIs DO work,
      which is why the image is base64'd over IPC.
    - The preload is sandboxed: require("fs") is NOT available there. That is why
      the file read happens in the main process and crosses via ipcMain.handle.
    - Modifying app.asar without disabling the fuse = hard crash at launch:
      "FATAL ... Integrity check failed for asar archive entry '<header>'".
    - The active version folder is NOT reliably the highest-numbered one.
      packages\RELEASES is the source of truth.

  This is a personal, at-your-own-risk modification of your own installed app.
  It breaks claude.exe's Authenticode signature and disables a tamper check.
  Re-run -Patch after every Claude Desktop auto-update. Use -Restore to undo.

.EXAMPLE
  .\ClaudeBG.ps1 -Status
  .\ClaudeBG.ps1 -Patch
  .\ClaudeBG.ps1 -SetImage "C:\pics\wallpaper.jpg" -Opacity 0.30
  .\ClaudeBG.ps1 -SetOpacity 0.25
  .\ClaudeBG.ps1 -Probe        # dump claude.ai's live DOM to domdump.json
  .\ClaudeBG.ps1 -Restore
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Status')]  [switch] $Status,
    [Parameter(ParameterSetName = 'Patch')]   [switch] $Patch,
    [Parameter(ParameterSetName = 'Restore')] [switch] $Restore,
    [Parameter(ParameterSetName = 'Probe')]   [switch] $Probe,
    [Parameter(ParameterSetName = 'SetImage', Mandatory = $true)] [string] $SetImage,
    [Parameter(ParameterSetName = 'SetImage')] [ValidateRange(0.0, 1.0)] [double] $Opacity = 0.35,
    [Parameter(ParameterSetName = 'SetOpacity', Mandatory = $true)] [ValidateRange(0.0, 1.0)] [double] $SetOpacity,
    [Parameter(ParameterSetName = 'SetImage')]
    [Parameter(ParameterSetName = 'SetOpacity')]
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
$DataDir     = Join-Path $env:APPDATA 'ClaudeBG'
$ImagePath   = Join-Path $DataDir 'current.jpg'
$LegacyImage = Join-Path $DataDir 'current.png'
$ConfigPath  = Join-Path $DataDir 'config.json'

# The image crosses to the renderer as a base64 data: URI inside a single
# webFrame.insertCSS call, and that call fails SILENTLY past a certain size -
# the rule never lands, --claudebg-img stays undefined, and you get no
# background and no error. A 15 MB PNG (~20 MB of base64) was doing exactly
# that. Downscaling to the long edge below and encoding JPEG keeps the payload
# in the low hundreds of KB, which is also just less absurd to inline in CSS.
$MaxEdge     = 2560
$JpegQuality = 88

function Get-CurrentImage {
    if (Test-Path $ImagePath)   { return $ImagePath }
    if (Test-Path $LegacyImage) { return $LegacyImage }
    return $null
}

function Write-Step { param([string]$m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "  $m" -ForegroundColor Yellow }

# --- Resolve the version folder Claude actually launches -----------------------
# RELEASES names the current package; fall back to numeric version sort (NEVER a
# plain string sort: app-1.2.234 vs app-1.34493.1 only sorts right by accident).
function Get-ActiveAppDir {
    $releases = Join-Path $InstallRoot 'packages\RELEASES'
    if (Test-Path $releases) {
        $line = (Get-Content $releases | Where-Object { $_ -match 'AnthropicClaude-([0-9.]+)-full\.nupkg' } | Select-Object -Last 1)
        if ($line -match 'AnthropicClaude-([0-9.]+)-full\.nupkg') {
            $candidate = Join-Path $InstallRoot "app-$($Matches[1])"
            if (Test-Path (Join-Path $candidate 'resources\app.asar')) { return $candidate }
        }
    }
    $dirs = Get-ChildItem $InstallRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'app-*' -and (Test-Path (Join-Path $_.FullName 'resources\app.asar')) }
    if (-not $dirs) { throw "No Claude Desktop install found under $InstallRoot" }
    return ($dirs | Sort-Object { try { [version]($_.Name -replace '^app-','') } catch { [version]'0.0.0' } } | Select-Object -Last 1).FullName
}

# Only ever kill the Desktop app. ~\.local\bin\claude.exe is the Claude Code CLI -
# killing that would take out the user's own terminal session.
function Stop-ClaudeDesktop {
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallRoot\*" }
    if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallRoot\*" })) {
            Start-Sleep -Milliseconds 800   # let Windows release the exe/asar file locks
            return
        }
        Start-Sleep -Milliseconds 250
    }
}

function Start-ClaudeDesktop { param([string]$AppDir) Start-Process (Join-Path $AppDir 'claude.exe') | Out-Null }

function Restart-ClaudeDesktop {
    $appDir = Get-ActiveAppDir
    Stop-ClaudeDesktop
    Start-ClaudeDesktop -AppDir $appDir
    Write-Ok "Claude Desktop restarted."
}

# config.json is read by Node inside Claude's main process, and JSON.parse throws
# on a leading U+FEFF. Windows PowerShell's `Set-Content -Encoding UTF8` ALWAYS
# writes that BOM, so a config written that way silently lost every opacity the
# user ever set - the injected reader caught the parse error and fell back to its
# built-in default. Write BOM-less UTF-8 explicitly; never use Set-Content here.
function Write-BgConfig {
    param([double]$Op)
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $json = "{ `"opacity`": $($Op.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }"
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Assert-Node {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js is required (for npx @electron/asar and @electron/fuses) but was not found on PATH." }
}

# --- Injected code -------------------------------------------------------------
# The archive is only ever repacked by -Patch, so anything that might need
# tuning has to be read from disk at page load instead of baked in here. Three
# things are: the image, the opacity, and bg.css (the art direction).
#
# NOTE the \uFEFF strip: readFileSync(...,"utf8") does NOT remove a BOM, and the
# surrounding catch is silent, so a BOM'd config.json degrades to the default
# opacity with no error anywhere. Write-BgConfig no longer writes one, but keep
# this - it repairs configs left behind by older versions or a hand edit.
$MainJs = @'
try{
var __cbgE=require("electron"),__cbgF=require("fs"),__cbgP=require("path");
var __cbgD=__cbgP.join(process.env.APPDATA||"","ClaudeBG");
var __cbgJpg=__cbgP.join(__cbgD,"current.jpg"),__cbgPng=__cbgP.join(__cbgD,"current.png");
var __cbgCfg=__cbgP.join(__cbgD,"config.json");
var __cbgCss=__cbgP.join(__cbgD,"bg.css"),__cbgDump=__cbgP.join(__cbgD,"domdump.json"),__cbgFlag=__cbgP.join(__cbgD,"probe.on");
__cbgE.ipcMain.handle("claudebg:get",function(){
  try{
    var o=.35;
    try{
      var c=JSON.parse(__cbgF.readFileSync(__cbgCfg,"utf8").replace(/^\uFEFF/,""));
      if(typeof c.opacity==="number"&&isFinite(c.opacity))o=Math.min(1,Math.max(0,c.opacity));
    }catch(e){}
    var u="";try{u=__cbgF.readFileSync(__cbgCss,"utf8").replace(/^\uFEFF/,"")}catch(e){}
    var pr=false;try{pr=__cbgF.existsSync(__cbgFlag)}catch(e){}
    // Sniff the magic bytes rather than trusting the extension, so the data:
    // URI never claims a type the bytes aren't.
    var b=__cbgF.readFileSync(__cbgF.existsSync(__cbgJpg)?__cbgJpg:__cbgPng);
    var m=(b[0]===0xFF&&b[1]===0xD8)?"image/jpeg":
          (b[0]===0x89&&b[1]===0x50)?"image/png":
          (b[0]===0x47&&b[1]===0x49)?"image/gif":"image/jpeg";
    return{img:b.toString("base64"),mime:m,bytes:b.length,opacity:o,css:u,probe:pr};
  }catch(x){return null}
});
__cbgE.ipcMain.handle("claudebg:dump",function(ev,d){
  try{__cbgF.writeFileSync(__cbgDump,d);__cbgF.unlinkSync(__cbgFlag)}catch(e){}
  return 1;
});
// Health line, so a background that fails to land says so somewhere instead of
// just not appearing. Both bugs this file has shipped - a BOM'd config and an
// oversized image - were silent; -Status reads this back.
__cbgE.ipcMain.handle("claudebg:log",function(ev,s){
  try{__cbgF.writeFileSync(__cbgP.join(__cbgD,"status.log"),new Date().toISOString()+"  "+s+"\n")}catch(e){}
  return 1;
});
}catch(x){}
'@

# Preload (sandboxed - no fs here, but the DOM IS reachable). Pulls image+CSS over
# IPC and injects them. The base layer only publishes custom properties and a
# fallback overlay; bg.css, when present, owns the entire look and can be edited
# and reloaded with Ctrl+R without ever repacking the archive.
$PreloadJs = @'
try{ if(!e.__claudebg){ e.__claudebg=1;
e.ipcRenderer.invoke("claudebg:get").then(function(d){
  if(!d||!d.img)return;
  var scrim=(1-d.opacity).toFixed(3);
  e.webFrame.insertCSS(
    ':root{--claudebg-img:url("data:'+d.mime+';base64,'+d.img+'");'+
    '--claudebg-opacity:'+d.opacity+';--claudebg-scrim:'+scrim+'}',
    {cssOrigin:'author'});
  if(d.css&&d.css.trim())
    e.webFrame.insertCSS(d.css,{cssOrigin:'author'});
  else
    // NB html::before, not ::after - on this build ::after does not render on
    // the root element, while ::before does. Verified by bisect.
    e.webFrame.insertCSS('html::before{content:"";position:fixed;inset:0;'+
      'background-image:var(--claudebg-img);background-size:cover;background-position:center;'+
      'opacity:var(--claudebg-opacity);z-index:2147483647;pointer-events:none}',
      {cssOrigin:'author'});

  // Did the rule actually land? insertCSS drops oversized payloads without
  // throwing, which reads as "the background just stopped working".
  setTimeout(function(){
    var v="";
    try{v=getComputedStyle(document.documentElement).getPropertyValue("--claudebg-img")}catch(e2){}
    var kb=Math.round(d.bytes/1024);
    e.ipcRenderer.invoke("claudebg:log", v.length>64
      ? "ok - image "+kb+"KB ("+d.mime+"), opacity "+d.opacity+", bg.css "+(d.css?d.css.length:0)+" bytes"
      : "FAILED - --claudebg-img did not resolve; image is "+kb+"KB, too large for insertCSS. Re-run -SetImage.");
  },2000);

  if(d.probe)__cbgProbe();
});
// Structure only - tag/testid/role/geometry/computed colours. Never text content.
function __cbgProbe(){
  // claude.ai is a SPA, so one capture at load only ever describes the landing
  // route. Re-capture on each pathname change (settled, not immediately) and
  // accumulate, so a single -Probe run can cover /new AND a conversation.
  var caps=[],last=null,pending=null,ticks=0;
  var iv=setInterval(function(){
    if(++ticks>360){clearInterval(iv);return}          // give up after ~3 min
    var p=location.pathname;
    if(p===last)return;
    last=p;
    clearTimeout(pending);
    pending=setTimeout(function(){__cbgCapture(caps,p)},2500);
  },500);
}
function __cbgCapture(caps,path){
  var els=document.querySelectorAll("body *");
  if(els.length<200)return;
  var out=[];
    for(var i=0;i<els.length&&out.length<500;i++){
      var el=els[i],r=el.getBoundingClientRect(),cs=getComputedStyle(el);
      var big=r.width*r.height>30000;
      var hot=el.hasAttribute("data-testid")||el.getAttribute("role")||el.isContentEditable||
              /^(NAV|ASIDE|MAIN|HEADER|FOOTER|FORM|FIELDSET|TEXTAREA)$/.test(el.tagName);
      if(!big&&!hot)continue;
      out.push({tag:el.tagName,testid:el.getAttribute("data-testid")||"",
        role:el.getAttribute("role")||"",label:(el.getAttribute("aria-label")||"").slice(0,40),
        ce:el.isContentEditable?1:0,
        cls:(typeof el.className==="string"?el.className:"").slice(0,200),
        bg:cs.backgroundColor,bd:cs.backdropFilter,pos:cs.position,z:cs.zIndex,
        iso:cs.isolation,tf:cs.transform==="none"?"":"yes",op:cs.opacity,fil:cs.filter,
        x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height)});
    }
  caps.push({path:path.replace(/[0-9a-f-]{8,}/g,"<id>"),
             vw:innerWidth,vh:innerHeight,els:out});
  e.ipcRenderer.invoke("claudebg:dump",JSON.stringify(caps,null,1));
}
}}catch(x){}
'@

function Invoke-Patch {
    Assert-Node
    $appDir = Get-ActiveAppDir
    Write-Step "Active install: $appDir"
    $res  = Join-Path $appDir 'resources'
    $asar = Join-Path $res 'app.asar'
    $exe  = Join-Path $appDir 'claude.exe'

    Stop-ClaudeDesktop
    Write-Step "Claude Desktop closed."

    # Backups. app.asar.orig needs its own .unpacked sibling or extraction of the
    # 6 native modules fails.
    if (-not (Test-Path "$exe.orig"))  { Copy-Item $exe "$exe.orig";  Write-Ok "Backed up claude.exe -> claude.exe.orig" }
    if (-not (Test-Path "$asar.orig")) { Copy-Item $asar "$asar.orig"; Write-Ok "Backed up app.asar -> app.asar.orig" }
    if ((Test-Path "$asar.unpacked") -and -not (Test-Path "$asar.orig.unpacked")) {
        Copy-Item "$asar.unpacked" "$asar.orig.unpacked" -Recurse
        Write-Ok "Backed up app.asar.unpacked"
    }

    # Fuse. Without this the app hard-crashes on any modified archive.
    # Windows keeps a lock on claude.exe for a moment after the process exits,
    # so the write gets EBUSY if attempted immediately - retry until it lands.
    Write-Step "Disabling asar integrity fuse (breaks Authenticode signature - expected)..."
    $flipped = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        & npx --yes @electron/fuses write --app $exe EnableEmbeddedAsarIntegrityValidation=off 2>$null | Out-Null
        $fuse = (& npx --yes @electron/fuses read --app $exe 2>$null | Select-String 'EnableEmbeddedAsarIntegrityValidation')
        if ($fuse -match 'Disabled') { $flipped = $true; break }
        Write-Warn2 "claude.exe still locked (attempt $attempt/6); waiting..."
        Start-Sleep -Seconds 2
    }
    if (-not $flipped) { throw "Could not disable the integrity fuse - claude.exe stayed locked. Close Claude Desktop (check the tray) and re-run." }
    Write-Ok "Fuse disabled."

    # Always rebuild from the pristine backup so re-patching is idempotent.
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("claudebg-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $src = Join-Path $work 'src'
    Write-Step "Extracting pristine app.asar..."
    & npx --yes @electron/asar extract "$asar.orig" $src | Out-Null

    $mainFile = Join-Path $src '.vite\build\index.pre.js'
    $preFile  = Join-Path $src '.vite\build\mainView.js'
    if (-not (Test-Path $mainFile)) { throw "index.pre.js not found - Claude Desktop's layout changed." }
    if (-not (Test-Path $preFile))  { throw "mainView.js not found - Claude Desktop's layout changed." }

    $mc = Get-Content $mainFile -Raw
    $mapMarker = '//# sourceMappingURL=index.pre.js.map'
    if ($mc.Contains($mapMarker)) { $mc = $mc.Replace($mapMarker, $MainJs + "`n" + $mapMarker) } else { $mc = $mc + "`n" + $MainJs }
    Set-Content -Path $mainFile -Value $mc -NoNewline -Encoding UTF8
    Write-Ok "Patched index.pre.js (IPC image provider)."

    $pc = Get-Content $preFile -Raw
    $anchor = ',{cssOrigin:`author`});'   # end of Claude's own insertCSS call
    if (-not $pc.Contains($anchor)) { throw "insertCSS anchor not found in mainView.js - Claude Desktop's preload changed." }
    $pc = $pc.Replace($anchor, $anchor + "`n" + $PreloadJs)
    Set-Content -Path $preFile -Value $pc -NoNewline -Encoding UTF8
    Write-Ok "Patched mainView.js (CSS injector)."

    Write-Step "Repacking..."
    $out = Join-Path $work 'app.asar'
    & npx --yes @electron/asar pack $src $out --unpack '*.{node,dll,exe}' | Out-Null
    if (-not (Test-Path $out)) { throw "Repack failed." }

    Copy-Item $out $asar -Force
    if (Test-Path "$out.unpacked") { Copy-Item "$out.unpacked\*" "$asar.unpacked" -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "Installed patched app.asar."

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    if (-not (Test-Path $ConfigPath)) { Write-BgConfig 0.35 }
    # Ship the default art direction alongside the patch, but never clobber an
    # edited one - bg.css is the file the user is expected to tinker with.
    $cssSrc = Join-Path $PSScriptRoot 'bg.css'
    $cssDst = Join-Path $DataDir 'bg.css'
    if ((Test-Path $cssSrc) -and -not (Test-Path $cssDst)) {
        [System.IO.File]::WriteAllText($cssDst, [System.IO.File]::ReadAllText($cssSrc), (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Installed default bg.css."
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

    if (-not (Get-CurrentImage)) { Write-Warn2 "No background set yet. Run: .\ClaudeBG.ps1 -SetImage <path>" }
    Start-ClaudeDesktop -AppDir $appDir
    Write-Ok "Patch complete. Claude Desktop restarted."
}

function Invoke-SetImage {
    param([string]$Path, [double]$Op, [switch]$SkipRestart)
    if (-not (Test-Path $Path)) { throw "Image not found: $Path" }
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

    # Normalise whatever the user picked (jpg/png/bmp/gif) to a downscaled JPEG.
    #
    # Decode from a MemoryStream, NOT Image.FromFile: FromFile holds a lock on the
    # source file for the lifetime of the Image, so when $Path IS current.jpg the
    # Save below writes into a file GDI+ still has open and throws the useless
    # "A generic error occurred in GDI+". Re-setting the same image is a normal
    # thing to do, so the round-trip has to be safe.
    Add-Type -AssemblyName System.Drawing
    $bytes  = [System.IO.File]::ReadAllBytes((Resolve-Path $Path))
    $stream = New-Object System.IO.MemoryStream(,$bytes)
    try {
        $img = [System.Drawing.Image]::FromStream($stream)   # stream must stay open until after Save
        try {
            $scale = [Math]::Min(1.0, $MaxEdge / [Math]::Max($img.Width, $img.Height))
            $w = [int][Math]::Round($img.Width  * $scale)
            $h = [int][Math]::Round($img.Height * $scale)

            $bmp = New-Object System.Drawing.Bitmap $w, $h
            try {
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                try {
                    $g.InterpolationMode  = 'HighQualityBicubic'
                    $g.PixelOffsetMode    = 'HighQuality'
                    $g.SmoothingMode      = 'HighQuality'
                    $g.CompositingQuality = 'HighQuality'
                    # Flatten onto black - JPEG has no alpha, and an unflattened
                    # transparent PNG would otherwise composite onto garbage.
                    $g.Clear([System.Drawing.Color]::Black)
                    $g.DrawImage($img, 0, 0, $w, $h)
                } finally { $g.Dispose() }

                $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                       Where-Object { $_.MimeType -eq 'image/jpeg' }
                $ep  = New-Object System.Drawing.Imaging.EncoderParameters 1
                $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                                   [System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
                try   { $bmp.Save($ImagePath, $enc, $ep) }
                finally { $ep.Dispose() }
                Write-Step "Resized $($img.Width)x$($img.Height) -> ${w}x${h}"
            } finally { $bmp.Dispose() }
        }
        finally { $img.Dispose() }
    }
    finally { $stream.Dispose() }

    # One image on disk, not two: a stale current.png would win nothing but
    # confusion now that the injected reader prefers .jpg.
    if ((Test-Path $LegacyImage) -and $LegacyImage -ne $Path) {
        Remove-Item $LegacyImage -Force -ErrorAction SilentlyContinue
    }

    $kb = [math]::Round((Get-Item $ImagePath).Length / 1KB)
    if ($kb -gt 3000) { Write-Warn2 "Image is ${kb} KB - large payloads can make insertCSS drop the rule silently." }
    else              { Write-Ok    "Encoded to ${kb} KB JPEG." }

    Write-BgConfig $Op
    Write-Ok "Background set (opacity $Op). No repack needed."

    if (-not $SkipRestart) { Restart-ClaudeDesktop }
    else { Write-Warn2 "Press Ctrl+R in Claude Desktop to apply." }
}

# Opacity lives in config.json, which the main process re-reads at page load - so
# changing it needs no image work at all. (It used to re-run -SetImage against
# current.png, which is what made every opacity change fail.)
function Invoke-SetOpacity {
    param([double]$Op, [switch]$SkipRestart)
    Write-BgConfig $Op
    Write-Ok "Opacity set to $Op."
    if (-not (Get-CurrentImage)) {
        Write-Warn2 "No background image set yet. Run: .\ClaudeBG.ps1 -SetImage <path>"
        return
    }
    if (-not $SkipRestart) { Restart-ClaudeDesktop }
    else { Write-Warn2 "Press Ctrl+R in Claude Desktop to apply." }
}

# Ask the running app what its own DOM looks like. claude.ai's markup is the one
# thing this project cannot read from disk, and guessing selectors for it is how
# you get a background that breaks silently. Arms a one-shot flag the injected
# preload picks up at next page load; the flag disarms itself once written.
function Invoke-Probe {
    $dump = Join-Path $DataDir 'domdump.json'
    $flag = Join-Path $DataDir 'probe.on'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Remove-Item $dump -Force -ErrorAction SilentlyContinue
    Set-Content $flag '1' -NoNewline
    Write-Step "Probe armed. Restarting Claude Desktop..."
    Restart-ClaudeDesktop
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path $dump) {
            $caps = @(Get-Content $dump -Raw | ConvertFrom-Json)
            Write-Ok "Captured $(($caps | ForEach-Object { "$($_.path) ($($_.els.Count) els)" }) -join ', ') -> $dump"
            Write-Warn2 "Still watching for ~3 min: open a conversation and it will capture that route too."
            return
        }
        Start-Sleep -Seconds 1
    }
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    throw "No dump after 60s. Is the patch applied, and did the main window finish loading?"
}

function Invoke-Restore {
    $appDir = Get-ActiveAppDir
    $res  = Join-Path $appDir 'resources'
    $asar = Join-Path $res 'app.asar'
    $exe  = Join-Path $appDir 'claude.exe'
    Stop-ClaudeDesktop
    if (Test-Path "$asar.orig") { Copy-Item "$asar.orig" $asar -Force; Write-Ok "Restored original app.asar." } else { Write-Warn2 "No app.asar.orig backup found." }
    if (Test-Path "$exe.orig")  { Copy-Item "$exe.orig"  $exe  -Force; Write-Ok "Restored original claude.exe (signature + integrity fuse back)." } else { Write-Warn2 "No claude.exe.orig backup found." }
    Start-ClaudeDesktop -AppDir $appDir
    Write-Ok "Restored. Claude Desktop restarted."
}

function Invoke-Status {
    $appDir = Get-ActiveAppDir
    $res  = Join-Path $appDir 'resources'
    $asar = Join-Path $res 'app.asar'
    $exe  = Join-Path $appDir 'claude.exe'
    Write-Host ""
    Write-Host "ClaudeBG status" -ForegroundColor White
    Write-Host "  active install : $appDir"
    Write-Host "  app.asar       : $([math]::Round((Get-Item $asar).Length/1MB,1)) MB"
    Write-Host "  backups        : asar=$(Test-Path "$asar.orig")  exe=$(Test-Path "$exe.orig")"
    try {
        $f = (& npx --yes @electron/fuses read --app $exe 2>$null | Select-String 'EnableEmbeddedAsarIntegrityValidation')
        # NB: '.*is' is greedy and eats into "D-is-abled", printing "abled".
        Write-Host "  integrity fuse : $(if ($f -match '\b(Enabled|Disabled)\b') { $Matches[1] } else { '(unknown)' })"
    } catch { Write-Host "  integrity fuse : (unknown - is Node installed?)" }
    Write-Host "  signature      : $((Get-AuthenticodeSignature $exe).Status)"
    $cur = Get-CurrentImage
    Write-Host "  background     : $(if ($cur) { "$cur  ($([math]::Round((Get-Item $cur).Length/1KB)) KB)" } else { '(none set)' })"
    $style = Join-Path $DataDir 'bg.css'
    Write-Host "  style          : $(if (Test-Path $style) { "$style  ($((Get-Item $style).Length) bytes)" } else { '(built-in overlay)' })"
    $log = Join-Path $DataDir 'status.log'
    if (Test-Path $log) { Write-Host "  last page load : $((Get-Content $log -Raw).Trim())" }
    if (Test-Path $ConfigPath) { Write-Host "  config         : $((Get-Content $ConfigPath -Raw).Trim())" }
    Write-Host ""
}

switch ($PSCmdlet.ParameterSetName) {
    'Patch'    { Invoke-Patch }
    'Restore'  { Invoke-Restore }
    'Probe'    { Invoke-Probe }
    'SetImage'   { Invoke-SetImage   -Path $SetImage -Op $Opacity -SkipRestart:$NoRestart }
    'SetOpacity' { Invoke-SetOpacity -Op $SetOpacity -SkipRestart:$NoRestart }
    default    { Invoke-Status }
}
