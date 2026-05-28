-- production_planner.lua  v2.0
-- Factorio Moon Script Circuit Mod
--
-- HOW TO USE
-- ----------
-- RED WIRE INPUT:
--   Connect to a constant combinator (or any circuit source) listing the
--   items you want to produce and their desired rates in items / minute.
--   Any item signal with a positive count is treated as a production request.
--
-- GREEN WIRE INPUT:
--   Connect to the output of your raw-material suppliers (belts, chests,
--   miners, etc.).  Items present here are treated as externally provided —
--   the planner will NOT recurse into their recipes, it will only report
--   how much of each you need to supply.
--
-- OUTPUT (circuit network):
--   • One item signal per craftable recipe step:
--       signal name  = the item the recipe produces
--       signal value = target throughput (items / min, rounded up)
--   • One item signal per raw-material requirement:
--       signal name  = the raw item
--       signal value = NEGATIVE required rate (items / min, rounded up)
--   • Slot-beacon virtual signals  signal-1 … signal-8:
--       value = 1 when that slot is active, 0 when idle
--
-- ASSEMBLER WIRING:
--   Wire 8 assembling machines to this combinator (red or green wire).
--   The script discovers them by their unit_number (lowest first = slot 1).
--   If Moon Script can set recipes on connected entities it will do so
--   automatically.  Otherwise use the output signals to drive recipe-set
--   combinators in your own circuit logic.
--
-- SERIES vs PARALLEL:
--   • Recipes that need > 1 assembler are spread across consecutive slots
--     (PARALLEL — all those slots run the same recipe simultaneously).
--   • Recipes that need only 1 assembler each occupy a single slot
--     (SERIES — different recipes form an ingredient chain, slot 1 → slot 8).
--   • The planner automatically chooses based on throughput requirements.
--
-- LIMITATIONS:
--   • Only 8 recipe steps can be assigned at once.  Deep trees with more than
--     8 craftable intermediates will have the deepest deps assigned to slots
--     and shallower steps skipped (a warning is written to the Factorio log).
--   • Circular recipes (Kovarex, etc.) are detected and treated as raw.
--   • Crafting speed is uniform (set ASSEMBLER_SPEED).  Mixed-tier assembler
--     banks are not modelled.
-- ---------------------------------------------------------------------------

-- ============================================================
-- USER CONFIGURATION
-- ============================================================

--- Number of assembler slots managed by this planner.
local NUM_ASSEMBLERS = 8

--- Base crafting speed of the managed assemblers.
---   Assembling Machine 1 = 0.50
---   Assembling Machine 2 = 0.75
---   Assembling Machine 3 = 1.25  (default)
local ASSEMBLER_SPEED = 1.25

--- Combined productivity bonus as a decimal.
--- (0.0 = none;  0.4 = four Productivity Module 1s at +10 % each = 40 % total)
local PRODUCTIVITY_BONUS = 0.0

--- When true, byproducts of a recipe are also resolved recursively.
local FOLLOW_BYPRODUCTS = false

--- Maximum recursion depth when resolving sub-recipes.
local MAX_DEPTH = 20

--- Ticks between each planning cycle.  (300 ticks = 5 s at 60 UPS)
local CYCLE_TICKS = 300

-- ============================================================
-- INTERNAL STATE  (do not edit)
-- ============================================================

local _tick_counter = 0
local _last_slots   = {}   -- [slot_number] = {recipe, mode, rate, …}
local _last_raw     = {}   -- {[item] = items_per_min needed from supply}

-- ============================================================
-- WIRE READING
-- ============================================================

--- Read all signals from one wire colour.
--- Returns { [item_name] = count } for every signal with a positive count.
--- Uses the Moon Script 'entity' global (the combinator itself).
local function read_wire(wire_color)
    local result = {}
    local ok, signals = pcall(function()
        return entity.get_merged_signals(
            defines.circuit_connector_id.combinator_input,
            wire_color
        )
    end)
    if not ok or not signals then return result end
    for _, sig in ipairs(signals) do
        local name = sig.signal and sig.signal.name
        if name and sig.count > 0 then
            result[name] = (result[name] or 0) + sig.count
        end
    end
    return result
end

-- ============================================================
-- RECIPE RESOLUTION
-- ============================================================

--- Returns the recipe prototype for item_name, or nil.
local function get_recipe(item_name)
    return game.recipe_prototypes[item_name]
end

--- Effective output quantity of one craft for product_name, with productivity.
local function effective_output(recipe, product_name)
    local amount = 0
    for _, product in ipairs(recipe.products) do
        local pname = product.name or product[1]
        if pname == product_name then
            if product.amount then
                amount = product.amount
            else
                amount = ((product.amount_min or 1) + (product.amount_max or 1)) / 2
            end
            break
        end
    end
    if amount == 0 then amount = 1 end
    return amount * (1 + PRODUCTIVITY_BONUS)
end

--- Recursively resolve the recipe tree for item_name.
---
--- @param item_name     string  prototype name of the item to produce
--- @param items_per_min number  desired throughput (items / minute)
--- @param supply        table   items on the green wire (treated as raw)
--- @param plan          table   accumulates { [item] = assemblers_needed }
--- @param rates         table   accumulates { [item] = items_per_min }
--- @param raw           table   accumulates { [item] = items_per_min } (uncraftable)
--- @param deps          table   dependency graph { [item] = {dep, dep, …} }
--- @param visiting      table   DFS stack for cycle detection
--- @param depth         number  current recursion depth
local function resolve(item_name, items_per_min, supply,
                       plan, rates, raw, deps, visiting, depth)
    if depth > MAX_DEPTH then return end

    -- Cycle detection: treat as raw if already on the stack
    if visiting[item_name] then
        raw[item_name] = (raw[item_name] or 0) + items_per_min
        return
    end

    -- Items present on the green wire are externally supplied → raw
    if supply[item_name] then
        raw[item_name] = (raw[item_name] or 0) + items_per_min
        return
    end

    local recipe = get_recipe(item_name)
    if not recipe or not recipe.enabled then
        raw[item_name] = (raw[item_name] or 0) + items_per_min
        return
    end

    local craft_time     = recipe.energy          -- seconds per craft
    local output_qty     = effective_output(recipe, item_name)
    local crafts_per_min = items_per_min / output_qty
    local assemblers     = (crafts_per_min * craft_time / 60) / ASSEMBLER_SPEED

    plan[item_name]  = (plan[item_name]  or 0) + assemblers
    rates[item_name] = (rates[item_name] or 0) + items_per_min

    if not deps[item_name] then deps[item_name] = {} end

    -- Recurse into ingredients
    visiting[item_name] = true
    for _, ingredient in ipairs(recipe.ingredients) do
        local ing_name   = ingredient.name   or ingredient[1]
        local ing_amount = ingredient.amount or ingredient[2] or 1
        local ing_rate   = crafts_per_min * ing_amount

        resolve(ing_name, ing_rate, supply, plan, rates, raw, deps, visiting, depth + 1)

        -- Record craftable dependency (skip raw ingredients)
        if plan[ing_name] then
            local already = false
            for _, d in ipairs(deps[item_name]) do
                if d == ing_name then already = true; break end
            end
            if not already then
                table.insert(deps[item_name], ing_name)
            end
        end
    end

    -- Optionally resolve byproducts
    if FOLLOW_BYPRODUCTS then
        for _, product in ipairs(recipe.products) do
            local pname = product.name or product[1]
            if pname ~= item_name then
                local by_qty  = product.amount
                             or (((product.amount_min or 1) + (product.amount_max or 1)) / 2)
                resolve(pname, crafts_per_min * by_qty, supply,
                        plan, rates, raw, deps, visiting, depth + 1)
            end
        end
    end

    visiting[item_name] = nil
end

-- ============================================================
-- TOPOLOGICAL SORT
-- ============================================================

--- Topological sort of the dependency graph (DFS, post-order).
--- Returns items in dependency-first order: deepest ingredients at index 1,
--- final products at the end.
--- @param graph  table  { [item] = {dep1, dep2, …} }
--- @return list  table  ordered item names
local function topo_sort(graph)
    local visited = {}
    local order   = {}

    local function visit(node)
        if visited[node] then return end
        visited[node] = true
        for _, dep in ipairs(graph[node] or {}) do
            visit(dep)
        end
        table.insert(order, node)
    end

    for node in pairs(graph) do
        visit(node)
    end

    return order
end

-- ============================================================
-- SLOT ASSIGNMENT
-- ============================================================

--- Assign NUM_ASSEMBLERS physical slots to the sorted recipe steps.
---
--- - Steps needing more than 1 assembler receive multiple consecutive slots
---   (PARALLEL — all those slots run the same recipe simultaneously).
--- - Steps needing only 1 assembler each get one slot
---   (SERIES — different recipes chain through consecutive slots).
--- - Slots are allocated proportionally to assembler demand; every step gets
---   at least 1 slot.
---
--- @param sorted_steps  list   [{name, assemblers, rate}, …]  deps-first order
--- @return assignments  table  [slot_number] = {recipe, mode, rate,
---                                               assemblers_allocated}
local function assign_slots(sorted_steps)
    local assignments = {}
    if #sorted_steps == 0 then return assignments end

    -- If the tree has more steps than slots, keep the first NUM_ASSEMBLERS
    -- (deepest dependencies) and log a warning about the truncated steps.
    if #sorted_steps > NUM_ASSEMBLERS then
        log(string.format(
            "[production_planner] Warning: %d craftable steps but only %d "
            .. "assembler slots.  The %d shallowest steps will not be assigned "
            .. "— handle them externally or increase NUM_ASSEMBLERS.",
            #sorted_steps, NUM_ASSEMBLERS, #sorted_steps - NUM_ASSEMBLERS
        ))
    end

    local n = math.min(#sorted_steps, NUM_ASSEMBLERS)
    local steps = {}
    for i = 1, n do steps[i] = sorted_steps[i] end

    -- Sum fractional assembler needs for proportional distribution
    local total_frac = 0
    for _, s in ipairs(steps) do
        total_frac = total_frac + math.max(1, s.assemblers)
    end

    local slot = 1
    for i, step in ipairs(steps) do
        if slot > NUM_ASSEMBLERS then break end

        local remaining_steps = n - i + 1
        local remaining_slots = NUM_ASSEMBLERS - slot + 1

        -- Reserve at least 1 slot per remaining step after this one
        local max_for_step = math.max(1, remaining_slots - (remaining_steps - 1))

        -- Ideal: proportional share of total slots
        local fraction    = (total_frac > 0) and (math.max(1, step.assemblers) / total_frac)
                            or (1 / n)
        local ideal       = math.max(1, math.floor(fraction * NUM_ASSEMBLERS + 0.5))
        local slots_count = math.min(max_for_step, ideal)

        local mode = (slots_count > 1) and "parallel" or "series"

        for s = slot, slot + slots_count - 1 do
            assignments[s] = {
                recipe               = step.name,
                mode                 = mode,
                rate                 = step.rate,
                assemblers_needed    = step.assemblers,
                assemblers_allocated = slots_count,
            }
        end
        slot = slot + slots_count
    end

    return assignments
end

-- ============================================================
-- ASSEMBLER DISPATCH  (direct entity control via Moon Script)
-- ============================================================

--- Collect all assembling-machine entities reachable on the circuit network.
--- Returns them sorted by unit_number (lowest = slot 1).
local function find_connected_assemblers()
    local seen = {}
    local list = {}

    local function collect(entities)
        if not entities then return end
        for _, ent in ipairs(entities) do
            if ent.valid
               and ent.type == "assembling-machine"
               and not seen[ent.unit_number]
            then
                seen[ent.unit_number] = true
                table.insert(list, ent)
            end
        end
    end

    local ok, connected = pcall(function()
        return entity.circuit_connected_entities
    end)
    if ok and connected then
        collect(connected.red)
        collect(connected.green)
    end

    table.sort(list, function(a, b) return a.unit_number < b.unit_number end)
    return list
end

--- Set recipes on the physical assembler entities and enable / disable them.
--- @param assignments  table  [slot] = {recipe, mode, rate, …}
local function dispatch_to_assemblers(assignments)
    local assemblers = find_connected_assemblers()
    if #assemblers == 0 then return end

    for slot = 1, NUM_ASSEMBLERS do
        local asm = assemblers[slot]
        if asm and asm.valid then
            local a = assignments[slot]
            if a then
                -- Update recipe only when it has changed (avoids resetting progress)
                local current = asm.get_recipe()
                if not current or current.name ~= a.recipe then
                    pcall(function() asm.set_recipe(a.recipe) end)
                end
                if asm.active ~= nil then asm.active = true end
            else
                -- Slot has no assignment → idle the assembler
                if asm.active ~= nil then asm.active = false end
            end
        end
    end
end

-- ============================================================
-- SIGNAL OUTPUT
-- ============================================================

--- Low-level signal emitter — tries both known Moon Script API variants.
local function out(name, count)
    if output_signal then
        output_signal(name, count)
    elseif set_output then
        set_output(name, count)
    end
end

--- Emit circuit-network signals for the current plan.
---
--- Signal scheme:
---   Craftable recipe → item signal, value = target rate (items/min, ≥ 1)
---   Raw material     → item signal, value = -(required rate, ≥ 1)
---   Active slot N    → virtual signal-N, value = 1  (idle = 0)
local function emit_signals(assignments, raw)
    -- Clear previous cycle's outputs
    if clear_output then
        clear_output()
    elseif output then
        output({})
    end

    -- One signal per unique recipe (deduplicated across parallel slots)
    local emitted = {}
    for _, a in pairs(assignments) do
        if a and not emitted[a.recipe] then
            emitted[a.recipe] = true
            out(a.recipe, math.max(1, math.ceil(a.rate or 1)))
        end
    end

    -- Raw material demands (negative so they are visually distinct)
    for item, rate in pairs(raw) do
        if rate > 0 then
            out(item, -math.max(1, math.ceil(rate)))
        end
    end

    -- Slot-beacon virtual signals  signal-1 … signal-8
    local virtual_names = {
        "signal-1", "signal-2", "signal-3", "signal-4",
        "signal-5", "signal-6", "signal-7", "signal-8",
    }
    for slot = 1, NUM_ASSEMBLERS do
        local vname = virtual_names[slot]
        if vname then
            out(vname, assignments[slot] and 1 or 0)
        end
    end
end

-- ============================================================
-- BUILD PLAN  (top-level orchestration)
-- ============================================================

--- Read both wires, resolve recipes, sort and assign slots.
--- @return assignments  table  [slot_number] = {recipe, mode, rate, …}
--- @return raw          table  {[item] = items_per_min still needed from supply}
local function build_plan()
    -- Red wire  → what to produce and at what rate
    local demand = read_wire(defines.wire_type.red)
    -- Green wire → what raw materials are being provided externally
    local supply = read_wire(defines.wire_type.green)

    if next(demand) == nil then
        return {}, {}   -- nothing requested
    end

    local plan     = {}   -- { [item] = assemblers_needed }
    local rates    = {}   -- { [item] = items_per_min }
    local raw      = {}   -- { [item] = items_per_min }  (uncraftable / supplied)
    local deps     = {}   -- dependency graph for topological sort
    local visiting = {}

    for item_name, qty in pairs(demand) do
        resolve(item_name, qty, supply, plan, rates, raw, deps, visiting, 0)
    end

    -- Subtract supplied quantities from raw demand so the output correctly
    -- shows only the unsatisfied shortfall.
    for item, supplied_rate in pairs(supply) do
        if raw[item] then
            raw[item] = math.max(0, raw[item] - supplied_rate)
            if raw[item] == 0 then raw[item] = nil end
        end
    end

    -- Topological sort → dependency-first order for series slot assignment
    local sorted_names = topo_sort(deps)

    -- Build the sorted_steps list
    local sorted_steps = {}
    for _, name in ipairs(sorted_names) do
        if plan[name] then
            table.insert(sorted_steps, {
                name       = name,
                assemblers = plan[name],
                rate       = rates[name] or 0,
            })
        end
    end

    local assignments = assign_slots(sorted_steps)
    return assignments, raw
end

-- ============================================================
-- MAIN LOOP  –  called every tick by Moon Script
-- ============================================================

--- Called by the Moon Script runtime on every game tick.
function on_tick()
    _tick_counter = _tick_counter + 1
    if _tick_counter < CYCLE_TICKS then return end
    _tick_counter = 0

    local assignments, raw = build_plan()
    _last_slots = assignments
    _last_raw   = raw

    -- Direct assembler dispatch (sets recipes on connected entities)
    dispatch_to_assemblers(assignments)

    -- Emit signals for circuit-network monitoring / manual control
    emit_signals(assignments, raw)
end

-- ============================================================
-- DEBUG HELPERS
-- ============================================================

--- Returns the last computed slot assignments and raw-material table.
function get_plan()
    return { slots = _last_slots, raw = _last_raw }
end

--- Pretty-print the current slot assignments to the Factorio log.
function print_plan()
    log("=== Assembler Slot Assignments ===")
    for slot = 1, NUM_ASSEMBLERS do
        local a = _last_slots[slot]
        if a then
            log(string.format(
                "  Slot %d  [%-8s]  recipe: %-35s  rate: %6.1f /min  "
                .. "(%.2f asm needed, %d allocated)",
                slot, a.mode, a.recipe, a.rate or 0,
                a.assemblers_needed or 0, a.assemblers_allocated or 1
            ))
        else
            log(string.format("  Slot %d  [idle]", slot))
        end
    end
    log("=== Raw Material Shortfall ===")
    if next(_last_raw) then
        for item, rate in pairs(_last_raw) do
            log(string.format("  %-40s  %6.1f /min", item, rate))
        end
    else
        log("  (none — all raw materials satisfied by green-wire supply)")
    end
end
