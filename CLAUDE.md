# ClaudeBG

Puts a custom background image behind Claude Desktop on Windows. Personal,
at-your-own-risk modification of an installed app.

- `ClaudeBG.ps1` — all the real work (fuse disable, app.asar patch, image/opacity).
- `tray/ClaudeBGTray.cs` → `ClaudeBGTray.exe` — WinForms tray front-end, shells out to the script.
- `bg.css` — the art direction, copied to `%APPDATA%\ClaudeBG\bg.css` at patch time.

See README.md for the constraints that are empirically verified and must not be
"simplified" away (CSP, asar integrity fuse, sandboxed preload, version-folder
resolution).

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
