# ClaudeGuard

A free, zero-setup safety tool for Claude Code / Claude Desktop users on Windows: backs up
your local `~/.claude` data, diagnoses a real and currently-unfixed Anthropic bug, and
verifies nothing got lost after a reinstall.

## Status: built 2026-08-26, not launched

Per this operator's Line 1 policy (see [PROJECTS.md](../../PROJECTS.md)): no second "own
product" launches until fusebox validates with real paying users. This exists ready to go
the moment that's true, or sooner if the policy is deliberately overridden - built now
because the problem is real and the fix was cheap to build, not because it's launching yet.

## The problem this fixes (real, documented, not guessed)

This came directly out of a real incident: Claude Desktop broke with "This app can't open"
on this operator's own machine, and the standard fix (uninstall/reinstall) risked losing
Claude Code's chat history - which had already happened once before to this exact user.

Researched properly before building anything, not assumed from one bad afternoon:

1. **Root cause, confirmed with logs**: recent Claude Desktop MSIX (Microsoft Store-style)
   builds on Windows bundle `vk_swiftshader.dll`. On machines with Memory Integrity (HVCI)
   enabled, Windows Code Integrity blocks that DLL (event 3033), the GPU process crashes,
   and the whole package gets flagged `Modified, NeedsRemediation`. The next launch fails
   with "This app can't open." Repair/reinstall only resets the clock - it self-corrupts
   again within a session. Documented with logs, independently reproduced on NVIDIA, AMD,
   Intel-integrated, and Windows-on-ARM machines, in Anthropic's own bug tracker:
   [anthropics/claude-code#88323](https://github.com/anthropics/claude-code/issues/88323).
   Explained in detail (and where "the fix that sticks" - switching to the non-MSIX
   Squirrel build - comes from): [wuweiai.io write-up](https://wuweiai.io/blog/fix-claude-desktop-this-app-cant-open-windows).
2. **Reinstalling can silently destroy Claude Code chat history** while other data (regular
   Chat, project files, memory) survives - a confirmed Anthropic bug:
   [anthropics/claude-code#62997](https://github.com/anthropics/claude-code/issues/62997).
3. **Lost sessions are often unrecoverable from the UI even though the transcript files are
   still on disk** - so a user frequently can't even tell what they lost without checking
   the filesystem directly: [anthropics/claude-code#81907](https://github.com/anthropics/claude-code/issues/81907).

Verified live on this operator's own machine (2026-08-26, `ClaudeGuard.ps1 diagnose`): not
currently broken, but 20 historical Code Integrity blocks specifically naming Claude, on a
machine with Memory Integrity enabled - i.e. a real, live-fire example of exactly this risk,
not a hypothetical. **Then it broke for real** (a separate crash a day later, itself likely
triggered by loading a page with a Cloudflare Turnstile challenge in a browser-automation
tool - the wuweiai.io write-up specifically flags Cloudflare challenges as a fast, reliable
trigger for this bug) - **and the fix above was applied live and confirmed working**: the old
MSIX package is fully uninstalled (`Get-AppxPackage *Claude*` returns nothing) and Claude
Desktop now runs from the unpackaged Squirrel build with no package-integrity status left to
corrupt.

## What this is NOT

[jtklinger/claude-code-backup-guide](https://github.com/jtklinger/claude-code-backup-guide)
already does comprehensive, git-versioned, cross-machine backup/restore of Claude Code's
full data model (settings, skills, plugins, sessions, everything) - it's actively maintained,
well-built (24 stars), and the right tool if you're comfortable with bash/git/jq. ClaudeGuard
doesn't try to replace it or compete with it.

ClaudeGuard is narrower and solves a different half of the problem: it's the only thing here
that actually looks at the Windows MSIX/Code Integrity corruption itself (package status,
event log, HVCI state) - which a data-backup tool has no reason to touch - and it's a single
double-clickable script with zero setup (no git repo, no config file, no dependencies beyond
PowerShell) for people who just want a yes/no answer and a safety net, not a workflow.

## Commands

```powershell
.\ClaudeGuard.ps1 diagnose   # read-only. Checks package status, Code Integrity event log,
                             # and Memory Integrity state. Never modifies anything.

.\ClaudeGuard.ps1 backup     # zips ~/.claude to %USERPROFILE%\ClaudeGuard\backups\ with a
                             # timestamp, and writes a manifest (project/session/memory
                             # counts) so "did I lose anything" has a real number to check.

.\ClaudeGuard.ps1 verify     # compares current ~/.claude against the most recent backup's
                             # manifest and reports exactly what's missing, if anything.
```

Default (no argument) runs `diagnose`.

## Applying the permanent fix

`diagnose` will tell you if this machine is at risk or currently broken, but ClaudeGuard
does not apply the actual fix automatically - it involves downloading and moving real
program files, which is a genuine system change that deserves a deliberate decision, not a
script silently doing it for you.

**Update 2026-08-27: done live, end to end, on this operator's own machine.** The steps
below aren't theoretical anymore - every gotcha listed was hit for real and is exactly what
tripped things up, not a guess at what might go wrong.

1. **Get the real current version number first.** The URL has a `<version>` placeholder in
   it - copy-pasting it literally (as written) 404s with an S3 "NoSuchKey" error. Fetch
   `https://downloads.claude.ai/releases/win32/x64/RELEASES` and read the version out of it
   (e.g. `1.37937.3`), then build the real download URL:
   `https://downloads.claude.ai/releases/win32/x64/AnthropicClaude-1.37937.3-full.nupkg`
   (~230MB).
2. **`.nupkg` is a ZIP file wearing a different extension.** Windows won't offer "Extract
   All" on it directly. Rename the downloaded file's extension from `.nupkg` to `.zip` first,
   *then* extract it normally.
3. **Copy the right subfolder, not the whole archive.** Inside the extracted folder, go into
   `lib\net45\` - that's the actual app (contains `claude.exe`, `vk_swiftshader.dll`, etc.).
   Copy everything *inside* `lib\net45\` (not the folder itself) into a fresh folder:
   `%LOCALAPPDATA%\AnthropicClaude\app-1.37937.3\` (matching whatever version you downloaded).
4. **Make a Desktop shortcut pointing at `claude.exe` inside that new folder**, so there's a
   normal double-click icon going forward instead of having to dig into AppData every time.
5. **Fully quit the old Claude Desktop before testing the new one.** Electron apps use a
   single-instance lock keyed to the app identity, not the install path - if the old MSIX
   build is still running (even minimized to the tray), launching the new build just silently
   hands off to the old one and exits instead of starting separately. Right-click the
   taskbar/tray icon → Quit (not just the window's X button), or use Task Manager and End
   Task on every process named "Claude" if there's no clean Quit option visible.
6. **Once the new build is confirmed working, uninstall the old one for real** - Settings →
   Apps → Installed apps → search "Claude" → Uninstall. Leaving both installed risks Windows
   Search/Start Menu surfacing the old broken tile by habit, and the old MSIX package can
   still silently auto-update itself in the background even while unused. This step doesn't
   need the original installer file (`Claude Setup.exe` / whatever `claude.com/download` gave
   you) - MSIX apps uninstall through Windows' own package system, not the original installer,
   so that file can be deleted independently, in either order, with zero risk of one blocking
   the other.
7. **Don't delete the extracted download folder until step 4's shortcut has been used at
   least once successfully.** If the app got launched by double-clicking `claude.exe` inside
   the *extracted download folder* itself (easy to do by accident, since that's the first
   place a person naturally clicks after extracting) rather than from the copied
   `%LOCALAPPDATA%` location, the running app is actually using that temporary folder as its
   real install - deleting it would pull the rug out from under a live session. Confirm the
   Desktop shortcut launches a fresh instance cleanly before cleaning up the download.
8. **One terminology trap worth calling out**: "Claude Desktop" (the Electron GUI app with a
   visible chat window - the one this entire bug affects) and "Claude Code" (the CLI engine,
   normally run in a plain terminal, unaffected by this specific GPU/rendering bug) are two
   different things that both show up as a process literally named `claude`/`claude.exe` in
   Task Manager. When following these steps, everything here is about Claude Desktop - don't
   quit a Claude Code terminal session by mistake thinking it's the same thing.
9. Optional, only if you skip step 6 (uninstalling the old one) for some reason: add
   `0.0.0.0 downloads.claude.ai` to your hosts file to stop the still-installed old MSIX build
   from auto-updating itself back over your fix. Not needed once step 6 is actually done -
   there's nothing left installed to auto-update.

## Requirements

Windows PowerShell 5.1+ (built in on any modern Windows install). No other dependencies.

## What's next, if/when this launches

Distribution channels already researched and working for fusebox (dev.to, Indie Hackers,
relevant subreddits/X threads about this exact error) apply directly here, since the
audience (Claude Code users) is more precisely targetable than fusebox's broader "solo
OpenAI API users." No monetization built in yet - this started as a free safety tool, and
whether it stays free-only or gets a paid tier (e.g. scheduled cloud backup) is a decision
for when it actually launches, not now.
