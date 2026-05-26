---
name: anaiis-termchart
description: Quick exploratory ASCII/ANSI charts in the terminal (bars, lines, sparklines, histograms, grouped bars). Auto-triggers when the user asks to visualize, chart, plot, graph, compare, or show a distribution of data inline in the terminal, or requests a sparkline.
user-invocable: true
trigger: hybrid
version: 0.1.0
---

# Terminal Chart

Render quick exploratory charts directly in the terminal using ANSI color escapes and Unicode block characters. Zero dependencies.

## When to activate

| Request shape | Chart type |
|---|---|
| "bar chart of X", "compare these values" | Horizontal bar |
| "Q1 vs Q2 by region", "two series side by side" | Grouped bar |
| "trend over time", "line graph", "plot X" | Line graph |
| "sparkline of …", inline trend | Sparkline |
| "distribution of …", "how is X spread" | Horizontal histogram |

**Do not use** for stakeholder deliverables (→ `anaiis-dashboard`), knowledge graphs (→ `graphify`), or any request that needs a saved image file.

## Building blocks

Unicode: `▁▂▃▄▅▆▇█` (vertical density), `░▒▓█` (shading), `─│┌┐└┘├┤┬┴┼` (frames), `╭╮╯╰` (smooth corners).

ANSI escapes (terminal only — fall back to shading or emoji squares in markdown):

- `\033[31m` red … `\033[36m` cyan; bright variants `\033[9Xm`; reset `\033[0m`
- 256-color: `\033[38;5;Nm` (N = 0–255); background `\033[48;5;Nm`

Pair color with shape or density — never use color alone to carry meaning.

## Recipes

**Horizontal bar** (label · bar · value):

```
Engineering  ████████████████████░░░░  82
Sales        ███████████████████░░░░░  78
Marketing    █████████████████░░░░░░░  71
Support      ██████████████░░░░░░░░░░  58
HR           ████████████░░░░░░░░░░░░  49
             └────┴────┴────┴────┴────
             0   25   50   75   100
```

**Grouped bar** (two series per category):

```
North   Q1 ██████████████░░░░░░  $42k
        Q2 ████████████████░░░░  $51k
South   Q1 ████████░░░░░░░░░░░░  $24k
        Q2 ███████████░░░░░░░░░  $33k
```

**Line graph**:

```
50 ┤                         ╭───
40 ┤             ╭─────╯
30 ┤   ╭────╯
20 ┤───╯
   └────┬────┬────┬────┬────┬────
       Jan  Feb  Mar  Apr  May  Jun
```

**Sparkline** (inline trend):

```
Daily logins (14d)   ▂▃▅▆▇█▇▅▃▂▃▅▇█   +18%
Error rate           ▁▁▂▁▁▃█▄▂▁▁▁▁▁   spike day 7
```

**Horizontal histogram**:

```
0-50ms     ████████████░░░░░░░░░░░░░░░░░░   142
50-100ms   ██████████████████████████░░░░   318  ← mode
100-200ms  ████████████████████████░░░░░░   287
200-500ms  ████████░░░░░░░░░░░░░░░░░░░░░░    94
500ms+     ██░░░░░░░░░░░░░░░░░░░░░░░░░░░░    23
```

**Colored bar via printf** (terminal-only, for live output):

```bash
printf "\033[36mEngineering  \033[32m"; printf "█%.0s" {1..20}; printf "\033[0m  82\n"
```

## Guardrails

- Default rendering width: 60 chars. Honor explicit user overrides.
- Max ~12 categories per chart; otherwise summarize, group, or split.
- Always print numeric labels next to bars — visuals alone are not enough.
- No pie charts, no 3D — the text medium cannot render them faithfully.
- Color is decorative. Keep meaning encoded in shape or density too, so output stays readable outside an ANSI-capable terminal.

## Upgrade path

For datasets above ~50 points or richer plot types, offer to switch to Python `plotext` (`pip install plotext`). Not a dependency of this skill.
