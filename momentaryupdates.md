# Macro Recorder: momentary updates

## 30.10.2026: from Lua to Swift
> "please convert the app open on the MacBook Display Recorder to a Swift app"

The app on the MacBook display is the Macro Recorder (macro.lua, script.lua, slots.lua, settings_page.lua,
editor_page.lua, find.py under Hammerspoon, page on :8829). It becomes "Macro Recorder (Mantra).app", one Swift
app with its own windows, signed "Mantra Apps"; the star row only opens or quits it. **Status:** done 30.10.2026. v1 installed; Marko recorded six clicks (⌃⌥⌘R) and played them (⌃⌥⌘P): "It's landed. It works."
Left: Screen Recording at the first FIND; the star's red/green tint; the Lua files out of the repo.

## 30.10.2026, 09:35: the star's colour, the permissions
> "yes, do that to the startup. Let it be red and open permissions for screen capture or whatever is missing"

The star turns red while a macro records (and green while one plays, as the Lua star did); the Screen Recording
permission (and anything else missing) is asked for. **Status:** done 30.10.2026. Star (Mantra) v7 listens to
`community.auroville.star.tint` (red / green / white, proven by capturing the star in each). Macro Recorder v2: a
PERMISSIONS section (Accessibility, Input Monitoring, Screen Recording, each with OPEN), Screen Recording asked at start;
System Settings opened on Screen & System Audio Recording for Marko's switch.

## 30.10.2026, 09:45: "Permissions" top right in every app, and the two "2.1"
> "permission is set, and please make this in every application that needs some permission. If permissions are not set, it needs to have text in the top right: "Permissions." Then I click on it, and it opens me directly to my settings page where I need to set permissions. Please open that setting for recording. You can confirm that I did the permission, but there are some things that are confusing you. You were doing something. There is 2.1, two times. What is that 2.1? Can we delete this"

**Status:** in progress.

## 31.10.2026: ON, OFF and TOP in every application

> "Please go to all the interface of my applications. Each needs to have the same user interface elements. On, off and top. Please build it in every application." (Marko, 31.10.2026)

The first row of the window as in MANTRA_MANIFEST swift-apps.md "The first row of every app: ON OFF … TOP ✕": ON, OFF, the name, TOP (always on top, remembered in UserDefaults `onTop`), ✕; each an Accessibility button (`off`, `top`, `close`).

**Status:** done, built v4 31.10.2026: TOP on the first row between the gap and PERMISSIONS/✕, green = the window floats above every other; it uses the app's own setting onTop in ~/.mantra_macro/settings.json (already there and applied at launch), so KEEP ON TOP in WINDOW AND FOLDER went (the same switch twice), and QUIT at the bottom went (swift-apps.md No QUIT; OFF quits, now after answering the press). Every word carries an Accessibility identifier (on, off, top, close, …). Checked at the minimum width 380 by a window capture (nothing cut or overlapping) and TOP pressed through AX twice (window layer 3, then 0). Relaunched: no REC/PLAY note on screen, v3 quit through its Quit menu item (AX), v4 opened with --login, window closed again

## 31.10.2026 (Elevate Media session)

> Please don't use Hammerspoon anymore. We have application called Macro Recorder. If it cannot do something, you need to improve it. And we are not using Hammerspoon because Macro Recorder is now your ally.

- v5: an inbox so Claude Code runs scripts and macros through the app (`macro run <name>`, `macro do <script>`), result written back. **Status:** done, installed and tested

> Please develop macro language. Copy macro language from AutoHotkey and build it inside this application. And then you need to write macros and this application will execute same as AutoHotkey.

- The language is already AutoHotkey v2 (docs/SCRIPT.md); v5 lets Claude hand it scripts. Next: whatever a real macro needs and the language lacks gets added (e.g. WinGetPos for window-relative clicks). **Status:** ongoing

## 31.10.2026 (evening)

> Macro Recorder should have a website. Let's try to get some donations going for this application, Mantra Macro Recorder.
> Please make a website, and please make a nice installation file. Then let people use it.
> It is not part of the Start menu anymore. It is now released as an independent release.

- Website https://mantramacrorecorder.pages.dev (bowl, counters, SEO), DMG v7, menu-bar icon, out of the star, card 16 on the bio. **Status:** done

## 1.11.2026, hub session (during Free Voice Convert): RECALIBRATE

> Please, in my macro recorder, also build a function called recalibrate.
>
> If some actions were recorded for a certain piece of software, recalibrate should take a screenshot of that software,
> so that all mouse actions land in the same places, corrected. The screen resolution may have changed, or the user may
> have moved the window somewhere else on the screen. The application needs to be intelligent enough to correct all the
> mouse coordinates.
>
> It should do this by comparing the current view with the stored view, then recalculating the same actions for the new
> view. When the macro fires, it will click the same positions, just by comparing the previous size to the new size and
> finding the differences. Please build that.

- v8: RECALIBRATE (button RECAL, `macro recalibrate`, `Recalibrate "name"`), the view stored at recording, VIEW, AUTO RECALIBRATE before play. **Status:** done 1.11.2026, tested on a throwaway window (moved, resized, shrunk, swapped targets, hidden patch refused).
