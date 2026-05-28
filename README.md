# factorio-moon-scripts

Lua scripts for the [Moon Script](https://mods.factorio.com/mod/Moon_Script) circuit-network mod for Factorio.

---

## production_planner.lua

Reads a production order (items + quantities per minute), recursively resolves every sub-assembly recipe, and emits circuit-network signals that tell your assemblers how many machines are needed to sustain the desired throughput.

### Features

- **Recursive recipe resolution** – follows ingredients all the way down to raw materials.
- **Circular-recipe detection** – safely skips loops (e.g. Kovarex enrichment) instead of hanging.
- **Productivity-module support** – configurable bonus so assembler counts stay accurate.
- **Raw-material reporting** – items with no craftable recipe are emitted as negative signals so you can route them separately.
- **Configurable cycle rate** – re-plans every N ticks (default 300 = 5 s) to stay responsive without wasting UPS.

### Quick start

1. Open `production_planner.lua` and edit the `PRODUCTION_ORDER` table at the top:

   ```lua
   local PRODUCTION_ORDER = {
       ["electronic-circuit"]      = 60,   -- 60 / min
       ["iron-gear-wheel"]         = 30,
       ["automation-science-pack"] = 15,
   }
   ```

2. Adjust `ASSEMBLER_SPEED` (default `1.25` for AM2) and `PRODUCTIVITY_BONUS` (e.g. `0.4` for four Productivity Module 1s).

3. Paste the entire script into the Moon Script combinator in-game.

4. Wire the combinator's output to your assembler network.  
   Each assembler should be circuit-filtered to act only on its own item signal.

### Signal layout

| Signal name | Value | Meaning |
|---|---|---|
| `<item-name>` | positive integer | Number of assemblers required |
| `<item-name>` | negative integer | Raw-material demand (items / min) |

### Debugging

Open the Moon Script console and call:

```lua
print_plan()   -- logs the full plan to the Factorio log file
get_plan()     -- returns the raw plan tables for inspection
```
