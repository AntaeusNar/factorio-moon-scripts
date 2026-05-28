-- production_planner.lua
-- Factorio Moon Script Circuit Mod
--
-- Reads a production order (items + quantities), recursively resolves all
-- sub-assembly recipes, and dispatches per-assembler item requests onto the
-- circuit network as virtual signals.
--
-- HOW TO USE
-- ----------
-- 1. Place this script inside the Moon Script circuit-network combinator.
-- 2. Edit the PRODUCTION_ORDER table below with the items you want to produce
--    and the desired quantity per minute (or per cycle – see CYCLE_TICKS).
-- 3. Wire the combinator's output to your assembler network.
--    Each assembler should be filtered so it only acts on its own item signal.
-- 4. Items that cannot be crafted (raw resources) are collected in the
--    `raw_materials` output table for separate handling.
--
-- SIGNAL LAYOUT
-- -------------
-- For every craftable intermediate the script emits a virtual-signal whose
--   name  = item prototype name  (e.g. "iron-gear-wheel")
--   count = assemblers required to sustain the requested throughput
--
-- Raw / uncraftable ingredients are emitted on a second "raw" combinator
-- output (wire colour configurable via RAW_OUTPUT_WIRE below).
--
-- LIMITATIONS
-- -----------
-- * Recipes with multiple outputs are supported; only the primary product is
--   followed when resolving sub-ingredients (set FOLLOW_BYPRODUCTS = true to
--   resolve all outputs of a recipe).
-- * Circular recipes (e.g. kovarex enrichment) are detected and skipped.
-- * Crafting speeds / productivity modules are NOT modelled by default;
--   set ASSEMBLER_SPEED and PRODUCTIVITY_BONUS to adjust.
-- ---------------------------------------------------------------------------

-- ============================================================
-- USER CONFIGURATION
-- ============================================================

--- Items to produce and their target rates (items / minute).
--- Adjust this table to match your production goals.
local PRODUCTION_ORDER = {
    ["electronic-circuit"]   = 60,
    ["iron-gear-wheel"]      = 30,
    ["automation-science-pack"] = 15,
}

--- Base crafting speed of the assemblers receiving orders (default: 1.25 for
--- Assembling Machine 2).  Increase for AM3 (1.25 → upgrade is same speed
--- but with module slots; set modules below).
local ASSEMBLER_SPEED = 1.25

--- Combined productivity bonus as a decimal (0.0 = none, 0.4 = 4 prod modules
--- at +10 % each = 40 % total bonus).
local PRODUCTIVITY_BONUS = 0.0

--- When true, byproducts of a recipe are also resolved recursively.
local FOLLOW_BYPRODUCTS = false

--- Maximum recursion depth when resolving sub-recipes (prevents infinite loops
--- in mods with unusual recipe graphs).
local MAX_DEPTH = 20

--- Ticks between each planning cycle.  Reduce for faster response at the cost
--- of UPS.  (300 ticks = 5 seconds at 60 UPS.)
local CYCLE_TICKS = 300

-- ============================================================
-- INTERNAL STATE  (do not edit)
-- ============================================================

local _tick_counter  = 0   -- counts ticks between planning cycles
local _last_plan     = {}  -- cached result from the previous cycle

-- ============================================================
-- RECIPE RESOLUTION UTILITIES
-- ============================================================

--- Returns the recipe prototype for `item_name`, or nil if none exists.
local function get_recipe(item_name)
    return game.recipe_prototypes[item_name]
end

--- Effective output quantity of a recipe, accounting for productivity.
--- @param recipe  RecipePrototype
--- @param product_name  string   name of the product we are interested in
--- @return number
local function effective_output(recipe, product_name)
    local amount = 0
    for _, product in ipairs(recipe.products) do
        local pname = product.name or (product[1])
        if pname == product_name then
            -- products can have an "amount" or "amount_min"/"amount_max"
            if product.amount then
                amount = product.amount
            else
                -- probabilistic: use midpoint
                amount = ((product.amount_min or 1) + (product.amount_max or 1)) / 2
            end
            break
        end
    end
    if amount == 0 then amount = 1 end
    return amount * (1 + PRODUCTIVITY_BONUS)
end

--- Recursively resolve ingredients for `item_name` at a rate of
--- `items_per_minute`, writing results into `plan` and `raw`.
---
--- @param item_name       string   prototype name of the item
--- @param items_per_min   number   desired throughput (items / minute)
--- @param plan            table    { [item_name] = assemblers_needed }
--- @param raw             table    { [item_name] = items_per_min }
--- @param visiting        table    set of names currently on the call stack
--- @param depth           number   current recursion depth
local function resolve(item_name, items_per_min, plan, raw, visiting, depth)
    if depth > MAX_DEPTH then return end
    if visiting[item_name] then
        -- circular dependency – treat as raw
        raw[item_name] = (raw[item_name] or 0) + items_per_min
        return
    end

    local recipe = get_recipe(item_name)
    if not recipe or not recipe.enabled then
        -- no craftable recipe → raw material
        raw[item_name] = (raw[item_name] or 0) + items_per_min
        return
    end

    -- craft_time is in seconds; convert to per-minute rate
    local craft_time      = recipe.energy  -- seconds per craft
    local output_qty      = effective_output(recipe, item_name)
    local crafts_per_min  = items_per_min / output_qty
    local assemblers      = (crafts_per_min * craft_time / 60) / ASSEMBLER_SPEED

    plan[item_name] = (plan[item_name] or 0) + assemblers

    -- Recurse into ingredients
    visiting[item_name] = true
    for _, ingredient in ipairs(recipe.ingredients) do
        local ing_name   = ingredient.name  or ingredient[1]
        local ing_amount = ingredient.amount or ingredient[2] or 1
        local ing_rate   = crafts_per_min * ing_amount  -- items / minute needed

        resolve(ing_name, ing_rate, plan, raw, visiting, depth + 1)
    end

    -- Optionally follow byproducts
    if FOLLOW_BYPRODUCTS then
        for _, product in ipairs(recipe.products) do
            local pname = product.name or product[1]
            if pname ~= item_name then
                resolve(pname, 0, plan, raw, visiting, depth + 1)
            end
        end
    end

    visiting[item_name] = nil
end

-- ============================================================
-- PLAN EXECUTION  –  builds the full plan from PRODUCTION_ORDER
-- ============================================================

--- Builds the production plan.
--- @return plan table  { [item_name] = assemblers_needed }
--- @return raw  table  { [item_name] = items_per_min }
local function build_plan()
    local plan     = {}
    local raw      = {}
    local visiting = {}

    for item_name, rate in pairs(PRODUCTION_ORDER) do
        resolve(item_name, rate, plan, raw, visiting, 0)
    end

    return plan, raw
end

-- ============================================================
-- SIGNAL OUTPUT HELPERS
-- ============================================================

--- Rounds a number to the nearest integer, minimum 1.
local function to_signal_count(n)
    return math.max(1, math.floor(n + 0.5))
end

--- Emits `signals` (table of {signal={type,name}, count}) onto the circuit
--- network.  In the Moon Script environment the combinator exposes
--- `output_signal(name, type, count)`.  Adjust the call below if your mod
--- version uses a different API.
local function emit_signals(signals)
    -- Clear previous outputs
    if output then output({}) end  -- Moon Script API to clear all signals

    for _, sig in ipairs(signals) do
        -- Moon Script API: set_signal(signal_name, value)
        -- Adjust the function name to match your mod version.
        if output_signal then
            output_signal(sig.name, sig.count)
        elseif set_output then
            set_output(sig.name, sig.count)
        end
    end
end

-- ============================================================
-- MAIN LOOP  –  called every tick by Moon Script
-- ============================================================

--- Called by the Moon Script runtime on every game tick.
function on_tick()
    _tick_counter = _tick_counter + 1
    if _tick_counter < CYCLE_TICKS then return end
    _tick_counter = 0

    local plan, raw = build_plan()
    _last_plan = { craftable = plan, raw = raw }

    -- Build signal list for craftable intermediates
    local signals = {}
    for item_name, assemblers in pairs(plan) do
        table.insert(signals, {
            name  = item_name,
            count = to_signal_count(assemblers),
        })
    end

    -- Append raw material signals (negative count so they are visually distinct)
    for item_name, rate in pairs(raw) do
        table.insert(signals, {
            name  = item_name,
            count = -to_signal_count(rate),
        })
    end

    emit_signals(signals)
end

-- ============================================================
-- OPTIONAL: EXPOSE PLAN FOR DEBUGGING IN MOON SCRIPT CONSOLE
-- ============================================================

--- Call get_plan() from the Moon Script console to inspect the current plan.
function get_plan()
    return _last_plan
end

--- Pretty-print the current plan to the Factorio log / console.
function print_plan()
    local plan, raw = build_plan()
    log("=== Production Plan ===")
    for item, n in pairs(plan) do
        log(string.format("  %-40s  %.2f assemblers", item, n))
    end
    log("=== Raw Materials (items/min) ===")
    for item, rate in pairs(raw) do
        log(string.format("  %-40s  %.2f / min", item, rate))
    end
end
