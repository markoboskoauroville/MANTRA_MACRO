# MANTRA SCRIPT: AutoHotkey on the Mac

Every macro is a text file, `~/.mantra_macro/macros/<name>.ahk`, written in the syntax of
AutoHotkey v2. A recording becomes one of these files; you can also write one from nothing.
What you learn here is AutoHotkey: the same script, with `#` meaning the Windows key instead of
Command, runs on a Windows machine with AutoHotkey installed.

One command per line. Arguments are separated by commas. Text goes in double quotes.
A line that starts with `;` is a comment.

```
; my first macro
Click 640, 400
Sleep 300
Send "Hello, world{Enter}"
```

## The mouse

- `Click x, y` moves the mouse to x, y and clicks. `Click x, y, 2` double-clicks.
  `Click x, y, "Right"` right-clicks. `Click` alone clicks where the mouse is.
- `MouseMove x, y` moves the mouse without clicking.
- `MouseClick "Left", x, y` and `MouseClick "Right", x, y` are the same as Click.
- `MouseClickDrag "Left", x1, y1, x2, y2` presses at x1, y1, drags to x2, y2 and lets go.
- `MouseGetPos &x, &y` puts the mouse position into the variables x and y.
- `Send "{WheelDown 3}"` scrolls down three notches. `{WheelUp 3}`, `{WheelLeft 1}`, `{WheelRight 1}`.

Coordinates are points on the screen, the same numbers the recorder writes. On a second screen
they continue past the first one's edge.

## The keyboard

`Send` types text and presses keys. Inside its text four characters mean a modifier for the
key that follows:

- `^` Control, `!` Option (Alt), `+` Shift, `#` Command (the Windows key in AutoHotkey).
- `Send "^c"` is Control+C. `Send "#v"` is Command+V. `Send "^!{Del}"` is Control+Option+Delete.

Keys that are not a letter go in braces: `{Enter}` `{Tab}` `{Esc}` `{Space}` `{BS}` (backspace)
`{Del}` `{Up}` `{Down}` `{Left}` `{Right}` `{Home}` `{End}` `{PgUp}` `{PgDn}` `{F1}` to `{F20}`.

- `{Enter 3}` presses Enter three times.
- `{Ctrl down}` holds Control until `{Ctrl up}`. Also `{Alt down}`, `{Shift down}`, `{Cmd down}`.
- `{!}` `{^}` `{+}` `{#}` `{{}` `{}}` type those characters themselves.
- `SendText "any text"` types the text exactly, with no special meaning for any character.
- To put a double quote inside quotes, write it twice: `Send "say ""hi"""`.
  A backtick escapes: `` `n `` is a new line, `` `t `` a tab.

## Waiting

`Sleep 500` waits half a second (the number is milliseconds). The recorder writes a Sleep
between every two actions with the time you took. The player's speed setting divides every
Sleep, so 2x runs the macro twice as fast.

## Pictures on the screen

Cut a picture of the button on the settings page ("Snap button", then drag over it on the
screen). It is saved under `~/.mantra_macro/images/`. Then:

- `ClickImage "button.png"` finds the picture on the screen and clicks its centre. Returns 1
  when it clicked, 0 when the picture is not on screen. `ClickImage "button.png", 10` keeps
  looking for up to ten seconds.
- `WaitImage "button.png", 10` waits up to ten seconds for the picture to appear.
- `ImageSearch &x, &y, 0, 0, 0, 0, "button.png"` is the AutoHotkey form: 1 when found, and x, y
  are its top left corner. The four zeros mean the whole screen; give x1, y1, x2, y2 to search
  a part of it.
- `FindImage("button.png")` gives the centre as `[x, y]`, or 0.
- `ImageExist("button.png")` is 1 when the picture is on the screen right now.
- `PixelGetColor(x, y)` is the colour at a point, as `"0xRRGGBB"`.

```
if ClickImage("generate.png", 5) {
    WaitImage "done.png", 60
    Send "#s"
} else {
    MsgBox "no Generate button on screen"
}
```

A picture is found when the screen looks at least 85% like it. Cut it tight around the button,
with a little of the background. A picture cut on a Retina screen is tried at half and double size
too, so it still works on the other monitor.

**The search zone.** On the settings page each picture either searches every screen, or a zone you
draw: press "zone" and drag the rectangle with the same cross-hair that snaps a
button, over where the button appears. A zone is faster (only that
rectangle is looked at) and safer (nothing that looks similar elsewhere can be matched by mistake).
"Snap & set zone" does both steps at once: snap the button, then draw its zone. "all" on a picture
puts it back to searching every screen. The zone is remembered with the picture.

While the recorder is looking, a small spinner sits at the bottom middle of the screen with the words
"searching for a pattern", and goes when the search ends. Every status line of the recorder shows there.

In a script, `ImageSearch &x, &y, x1, y1, x2, y2, "button.png"` searches the rectangle from
(x1, y1) to (x2, y2); four zeros mean the picture's own zone, or every screen if it has none.
`ClickImage`, `WaitImage`, `FindImage` and `ImageExist` all use the picture's zone.

## Variables and expressions

```
x := 10
name := "Marko"
x += 5
count++
text := "Hello " name       ; two values next to each other join
text := "Hello " . name     ; the dot joins too
```

- Numbers: `+ - * / ** ` and `//` for whole division. `Mod(a, b)` for the remainder.
- Comparison: `=` (ignores case), `==` (exact), `!=`, `<`, `>`, `<=`, `>=`.
- Logic: `and`, `or`, `not`, or `&&`, `||`, `!`.
- `a ? b : c` is b when a is true, else c.
- A variable that was never set is empty. `""`, `0` and empty count as false.

Built in: `A_Index` (the turn of the loop), `A_ScreenWidth`, `A_ScreenHeight`, `A_Clipboard`
(read it, or `A_Clipboard := "text"` to set it), `A_MouseX`, `A_MouseY`, `A_TickCount`
(milliseconds since the macro started), `A_Now`.

## If

```
if x > 10 {
    MsgBox "big"
} else if x > 3 {
    MsgBox "middle"
} else {
    MsgBox "small"
}

if x = 1
    MsgBox "one line needs no braces"
```

## Loops

```
Loop 5 {
    MsgBox "turn " A_Index
}

Loop {                      ; forever, until Break
    if ImageExist("done.png")
        Break
    Sleep 500
}

i := 0
While i < 10 {
    i++
    if i = 4
        Continue            ; skip to the next turn
}

Loop
    i--
Until i = 0
```

## Functions

```
Greet(name, times := 1) {
    Loop times
        MsgBox "hello " name
    return times
}

Swap(&a, &b) {
    t := a
    a := b
    b := t
}

Greet("Marko", 2)
Swap(&x, &y)
```

Variables inside a function are its own. To write to a script-wide variable from inside, say
`global name` first.

## Arrays and maps

```
list := [10, 20, 30]
list.Push(40)
MsgBox list.Length " " list[1] " " list[-1]
For i, v in list
    MsgBox i ": " v

m := Map("a", 1, "b", 2)
m["c"] := 3
if m.Has("b")
    MsgBox m["b"]
For key, value in m
    MsgBox key "=" value

o := {name: "Marko", city: "Auroville"}
MsgBox o["name"]
```

`StrSplit("a,b,c", ",")` makes an array from text.

## Text and numbers

`StrLen(s)` `SubStr(s, start, length)` `InStr(s, find)` `StrReplace(s, from, to)`
`StrUpper(s)` `StrLower(s)` `Trim(s)` `Format("{1} and {2}", a, b)`
`Round(x, 2)` `Floor(x)` `Ceil(x)` `Abs(x)` `Min(a, b)` `Max(a, b)` `Random(1, 6)` `Sqrt(x)`
`IsNumber(v)` `Type(v)` `Chr(65)` `Ord("A")`

## Apps, files, messages

- `WinActivate "Google Chrome"` brings the app to the front. `WinExist("Google Chrome")` is 1
  when it is open. `WinWaitActive "Google Chrome", , 10` brings it forward and waits up to ten seconds.
- `Run "https://example.com"` opens an address; `Run "Safari"` opens an app; `Run "/path/file"` a file.
- `MsgBox "text"` and `ToolTip "text"` show a line at the bottom middle of the screen, for a moment.
- `FileExist("/path")`, `FileRead("/path")`, `FileAppend "text", "/path"`.
- `ExitApp` stops the macro.

## What is different from AutoHotkey on Windows

- `#` is Command here, the Windows key there. `!` is Option here, Alt there.
- Hotkeys (`^r::`) are not written in a macro. The ten slots on the settings page are the hotkeys:
  Option+digit loads, Control+digit runs.
- `MsgBox` does not stop the macro and has no buttons; it is a line bottom right.
- `ClickImage`, `WaitImage`, `FindImage`, `ImageExist` are ours; AutoHotkey has only `ImageSearch`.
- Not here: `Loop Parse`, `Loop Files`, `Gui`, `Hotstrings`, `SetTimer`, `RegRead`, `DllCall`.
- Directives like `#Requires AutoHotkey v2.0` and `#SingleInstance` are read and ignored, so a
  script from a Windows machine runs as it is.

## Stopping

Press the stop key (⌃⌥⌘. as it comes) or the play key again. A macro that loops forever with
no Sleep can still be stopped: the player checks between statements.
