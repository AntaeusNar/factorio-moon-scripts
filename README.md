# factorio-moon-scripts

Lua scripts for the [Moon Script](https://mods.factorio.com/mod/Moon_Script) circuit-network mod for Factorio.

---

## production_planner.lua

Reads live production requests from the **red wire**, uses the **green wire** to know what raw materials are already being supplied, recursively resolves all sub-assembly recipes, and dispatches assignments to **8 assembler slots** — automatically choosing series or parallel layout based on throughput needs.

### Features

- **Live wire input** — no hardcoded tables; plug in a constant combinator on the red wire and change your production goals at any time.
- **Green-wire supply awareness** — items present on the green wire are treated as externally provided; the planner skips their recipes and only reports how much you need to supply.
- **8-assembler dispatch** — slot assignments are computed every planning cycle and set directly on connected assembling machines via the Moon Script entity API.
- **Automatic series / parallel layout** — bottleneck steps (high assembler demand) get multiple parallel slots; simpler steps each get one slot in dependency order.
- **Recursive recipe resolution** — resolves the full ingredient tree down to raw materials.
- **Circular-recipe detection** — safely handles loops (e.g. Kovarex enrichment) without hanging.
- **Productivity-module support** — configurable bonus keeps assembler counts accurate.
- **Configurable cycle rate** — re-plans every N ticks (default 300 = 5 s).

### Wiring

```
[Constant combinator]  ── red  ──► [Moon Script combinator] ──► [8× Assembling machines]
[Raw-material supply]  ── green ──►                          └──► [Circuit monitoring]
```

| Wire | Carries |
|---|---|
| Red | Item signals: name = item to produce, count = desired items / min |
| Green | Item signals: name = raw material, count = supply rate (items / min) |
| Output | Recipe-rate signals, raw-shortfall signals, slot-beacon virtual signals |

### Output signal layout

| Signal name | Value | Meaning |
|---|---|---|
| `<recipe item>` | positive integer | Target throughput for that recipe (items / min) |
| `<raw item>` | negative integer | Unsatisfied raw-material demand (items / min) |
| `signal-1` … `signal-8` | 1 or 0 | Slot-beacon: 1 = slot active, 0 = idle |

### Series vs parallel

| Mode | When | How |
|---|---|---|
| **Parallel** | A recipe needs > 1 assembler to hit the target rate | Multiple consecutive slots get the **same** recipe |
| **Series** | Each step needs only 1 assembler | Each slot gets a **different** recipe in dependency order (slot 1 = deepest ingredient, slot 8 = final product) |

### Assembler identification

The script discovers connected assemblers through the circuit network and sorts them by `unit_number` (lowest = slot 1, highest = slot 8). Wire all 8 assemblers to the Moon Script combinator before starting so slot numbering is stable.

### Quick start

1. Paste the entire script into the Moon Script combinator in-game.
2. Adjust `ASSEMBLER_SPEED` (`0.50` AM1 / `0.75` AM2 / `1.25` AM3, default) and `PRODUCTIVITY_BONUS` if needed.
3. Wire a **constant combinator** to the **red wire** and set the items + rates you want.
4. Wire your **raw-material suppliers** to the **green wire**.
5. Wire **8 assembling machines** to the combinator (red or green wire).
6. The script will set recipes and enable/disable assemblers automatically each cycle.

### Debugging

Set `DEBUG = true` in the configuration section at the top of the script.  The planner will then write slot assignments and raw-material shortfall to the Factorio log after every planning cycle.

