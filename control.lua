local names = require("prototypes.names")

local UPDATE_INTERVAL = 30
local MAX_ITEM_REQUESTS = 8
local REQUEST_STACKS = 5
local REFILL_THRESHOLD_STACKS = 4
local REQUEST_BUFFER_SLOTS = MAX_ITEM_REQUESTS * REQUEST_STACKS
local STORAGE_LIST_COLUMNS = 10
local FLUID_PORT_CAPACITY = 25000
local FLUID_REQUEST_TARGET = 20000
local FLUID_STORAGE_TEMPERATURE_VERSION = 1
local NORMAL_QUALITY = "normal"
local TRANSLATION_KIND_ITEM = "item"
local TRANSLATION_KIND_FLUID = "fluid"
local STORAGE_ENTRY_PREFIX = "dimensional_port_storage_entry_"
local STORAGE_SIGNATURE_SEPARATOR = "\31"
local CIRCUIT_SIGNAL_MAX = 2147483647
local COMBINATOR_REGISTRY_VERSION = 1
local VORTEX_RENDERING_CLEANUP_VERSION = 3

local migrate_fluid_storage_temperature

local function cleanup_old_vortex_renderings()
  if storage.vortex_rendering_cleanup_version == VORTEX_RENDERING_CLEANUP_VERSION then return end
  rendering.clear(script.mod_name)
  storage.vortex_renderings = nil
  storage.vortex_rendering_version = nil
  storage.vortex_rendering_cleanup_version = VORTEX_RENDERING_CLEANUP_VERSION
end

local function fluid_default_temperature(name)
  local prototype = prototypes.fluid and prototypes.fluid[name]
  return prototype and prototype.default_temperature
end

local function normalise_fluid_temperature(name, temperature)
  if type(temperature) == "number" then
    return temperature
  end
  return fluid_default_temperature(name)
end

local function fluid_storage_amount(entry)
  if type(entry) == "table" then
    return entry.amount or 0
  elseif type(entry) == "number" then
    return entry
  end
  return 0
end

local function fluid_storage_temperature(name, entry)
  if type(entry) == "table" then
    return normalise_fluid_temperature(name, entry.temperature)
  end
  return normalise_fluid_temperature(name, nil)
end

local function normalise_fluid_storage_entry(name, entry)
  local amount = fluid_storage_amount(entry)
  if amount <= 0 then return nil end
  return {
    amount = amount,
    temperature = fluid_storage_temperature(name, entry)
  }
end

local function ensure_storage()
  storage.dimensional_storage = storage.dimensional_storage or {items = {}, fluids = {}}
  storage.dimensional_storage.items = storage.dimensional_storage.items or {}
  storage.dimensional_storage.fluids = storage.dimensional_storage.fluids or {}
  storage.item_ports = storage.item_ports or {}
  storage.fluid_ports = storage.fluid_ports or {}
  storage.dimensional_combinators = storage.dimensional_combinators or {}
  storage.players = storage.players or {}
  storage.destroy_registrations = storage.destroy_registrations or {}
  storage.distribution_offsets = storage.distribution_offsets or {items = {}, fluids = {}}
  storage.distribution_offsets.items = storage.distribution_offsets.items or {}
  storage.distribution_offsets.fluids = storage.distribution_offsets.fluids or {}
  if storage.fluid_temperature_storage_version ~= FLUID_STORAGE_TEMPERATURE_VERSION and migrate_fluid_storage_temperature then
    migrate_fluid_storage_temperature()
  end
  cleanup_old_vortex_renderings()
end

local function quality_name(quality)
  if quality == nil then
    return NORMAL_QUALITY
  end
  if type(quality) == "string" then
    return quality
  end
  if type(quality) == "table" then
    return quality.name or NORMAL_QUALITY
  end
  local ok, name = pcall(function() return quality.name end)
  if ok and type(name) == "string" and name ~= "" then
    return name
  end
  return NORMAL_QUALITY
end

local function item_key(name, quality)
  return name .. "\n" .. quality_name(quality)
end

local function split_item_key(key)
  local name, quality = key:match("^(.-)\n(.+)$")
  return name, quality or NORMAL_QUALITY
end

local function fluid_key(name)
  return name
end

local function quality_is_available(quality)
  local name = quality_name(quality)
  return prototypes.quality == nil or prototypes.quality[name] ~= nil
end

local function item_request_is_available(request)
  return request and request.name and prototypes.item[request.name] and quality_is_available(request.quality)
end

local function fluid_is_available(name)
  return name and prototypes.fluid[name] ~= nil
end

local function add_item_to_storage(name, quality, count)
  if count <= 0 then return end
  local key = item_key(name, quality)
  storage.dimensional_storage.items[key] = (storage.dimensional_storage.items[key] or 0) + count
end

local function remove_item_from_storage(name, quality, count)
  local key = item_key(name, quality)
  local available = storage.dimensional_storage.items[key] or 0
  local removed = math.min(available, count)
  if removed <= 0 then return 0 end
  local remaining = available - removed
  storage.dimensional_storage.items[key] = remaining > 0 and remaining or nil
  return removed
end

local function add_fluid_to_storage(name, amount, temperature)
  if amount <= 0 then return end
  local key = fluid_key(name)
  local entry = normalise_fluid_storage_entry(name, storage.dimensional_storage.fluids[key])
  local added_temperature = normalise_fluid_temperature(name, temperature)
  if not entry then
    storage.dimensional_storage.fluids[key] = {amount = amount, temperature = added_temperature}
    return
  end

  local existing_amount = entry.amount
  local new_amount = existing_amount + amount
  if type(entry.temperature) == "number" and type(added_temperature) == "number" then
    entry.temperature = ((existing_amount * entry.temperature) + (amount * added_temperature)) / new_amount
  elseif type(added_temperature) == "number" then
    entry.temperature = added_temperature
  end
  entry.amount = new_amount
  storage.dimensional_storage.fluids[key] = entry
end

local function remove_fluid_from_storage(name, amount)
  local key = fluid_key(name)
  local entry = normalise_fluid_storage_entry(name, storage.dimensional_storage.fluids[key])
  local available = entry and entry.amount or 0
  local removed = math.min(available, amount)
  if removed <= 0 then return 0, entry and entry.temperature or nil end
  local remaining = available - removed
  if remaining > 0 then
    entry.amount = remaining
    storage.dimensional_storage.fluids[key] = entry
  else
    storage.dimensional_storage.fluids[key] = nil
  end
  return removed, entry.temperature
end

local function fluid_is_storable(fluid)
  return fluid and fluid.name and fluid.amount and fluid.amount > 0 and fluid_is_available(fluid.name)
end

local function add_fluid_stack_to_storage(fluid)
  if not fluid_is_storable(fluid) then return false end
  add_fluid_to_storage(fluid.name, fluid.amount, fluid.temperature)
  return true
end

local function get_main_inventory(entity)
  if not (entity and entity.valid) then return nil end
  return entity.get_inventory(defines.inventory.chest)
end

local function stack_definition(name, quality, count)
  return {name = name, quality = quality_name(quality), count = count}
end

local function inventory_count(inventory, name, quality)
  if not (inventory and inventory.valid) then return 0 end
  return inventory.get_item_count({name = name, quality = quality_name(quality)})
end

local function stack_matches(stack, name, quality)
  return stack and stack.valid_for_read and stack.name == name and quality_name(stack.quality) == quality_name(quality)
end

local function request_slot_range(index)
  local first = ((index - 1) * REQUEST_STACKS) + 1
  return first, math.min(first + REQUEST_STACKS - 1, REQUEST_BUFFER_SLOTS)
end

local function request_index_for_slot(slot)
  if slot < 1 or slot > REQUEST_BUFFER_SLOTS then return nil end
  return math.floor((slot - 1) / REQUEST_STACKS) + 1
end

local function slot_is_active_request_buffer(port, slot)
  local request_index = request_index_for_slot(slot)
  if not request_index then return false end
  return item_request_is_available(port.requests and port.requests[request_index])
end

local function count_item_in_slots(inventory, first_slot, last_slot, name, quality)
  if not (inventory and inventory.valid) then return 0 end
  local count = 0
  for slot = first_slot, math.min(last_slot, #inventory) do
    local stack = inventory[slot]
    if stack_matches(stack, name, quality) then
      count = count + stack.count
    end
  end
  return count
end

local function remove_item_from_slots(inventory, first_slot, last_slot, name, quality, count)
  if not (inventory and inventory.valid) then return 0 end
  local remaining = count
  local removed = 0
  for slot = first_slot, math.min(last_slot, #inventory) do
    if remaining <= 0 then break end
    local stack = inventory[slot]
    if stack_matches(stack, name, quality) then
      local amount = math.min(stack.count, remaining)
      stack.count = stack.count - amount
      remaining = remaining - amount
      removed = removed + amount
    end
  end
  return removed
end

local function insert_item_into_slots(inventory, first_slot, last_slot, name, quality, count)
  if not (inventory and inventory.valid) then return 0 end
  local prototype = prototypes.item[name]
  if not (prototype and quality_is_available(quality)) then return 0 end
  local stack_size = prototype.stack_size
  local remaining = count
  for pass = 1, 2 do
    for slot = first_slot, math.min(last_slot, #inventory) do
      if remaining <= 0 then return count end
      local stack = inventory[slot]
      local can_insert = (pass == 1 and stack_matches(stack, name, quality)) or (pass == 2 and stack and not stack.valid_for_read)
      if can_insert then
        local before = stack.valid_for_read and stack.count or 0
        local amount = math.min(remaining, stack_size - before)
        if amount > 0 then
          if stack.valid_for_read then
            stack.count = stack.count + amount
          elseif stack.set_stack(stack_definition(name, quality, amount)) then
            amount = stack_matches(stack, name, quality) and stack.count or 0
          else
            amount = 0
          end
        end
        local after = stack.valid_for_read and stack.count or 0
        remaining = remaining - math.max(0, after - before)
      end
    end
  end
  return count - remaining
end

local function return_slot_range_to_storage(inventory, first_slot, last_slot)
  if not (inventory and inventory.valid) then return {} end
  local returned = {}
  for slot = first_slot, math.min(last_slot, #inventory) do
    local stack = inventory[slot]
    if stack and stack.valid_for_read then
      local name = stack.name
      local quality = quality_name(stack.quality)
      local count = stack.count
      stack.count = 0
      add_item_to_storage(name, quality, count)
      local key = item_key(name, quality)
      returned[key] = (returned[key] or 0) + count
    end
  end
  return returned
end

local function request_buffer_count(inventory, request_index, request)
  if not item_request_is_available(request) then return 0 end
  local first_slot, last_slot = request_slot_range(request_index)
  return count_item_in_slots(inventory, first_slot, last_slot, request.name, request.quality)
end

local function request_refill_threshold(request)
  local prototype = prototypes.item[request.name]
  if not prototype then return 0 end
  return prototype.stack_size * REFILL_THRESHOLD_STACKS
end

local function clear_inventory_filters(inventory)
  if not (inventory and inventory.valid and inventory.supports_filters and inventory.supports_filters()) then
    return
  end
  for index = 1, #inventory do
    inventory.set_filter(index, nil)
  end
end

local function apply_request_filters(port)
  local inventory = get_main_inventory(port.entity)
  if not inventory then return end
  clear_inventory_filters(inventory)

  if inventory.supports_filters and inventory.supports_filters() then
    for index = 1, MAX_ITEM_REQUESTS do
      local request = port.requests and port.requests[index]
      if item_request_is_available(request) then
        local first_slot, last_slot = request_slot_range(index)
        for slot = first_slot, last_slot do
          if slot <= #inventory then
            local stack = inventory[slot]
            if not (stack and stack.valid_for_read) or stack_matches(stack, request.name, request.quality) then
              inventory.set_filter(slot, {name = request.name, quality = quality_name(request.quality)})
            end
          end
        end
      end
    end
  end
end

local function absorb_inventory_to_storage(entity)
  local inventory = get_main_inventory(entity)
  if not inventory then return end
  local contents = inventory.get_contents()
  for _, stack in pairs(contents) do
    local quality = quality_name(stack.quality)
    local removed = inventory.remove(stack_definition(stack.name, quality, stack.count))
    add_item_to_storage(stack.name, quality, removed)
  end
end

local target_count_for_request

local function request_for_item(port, name, quality)
  for index = 1, MAX_ITEM_REQUESTS do
    local request = port.requests and port.requests[index]
    if item_request_is_available(request) and request.name == name and quality_name(request.quality) == quality_name(quality) then
      return request, index
    end
  end
  return nil, nil
end

local function move_ingress_stack_to_request_buffer(port, inventory, stack, slot)
  local quality = quality_name(stack.quality)
  local request, request_index = request_for_item(port, stack.name, quality)
  if not request then return 0 end

  local target = target_count_for_request(request)
  local current = request_buffer_count(inventory, request_index, request)
  local space = target - current
  if space <= 0 then return 0 end

  local amount = math.min(stack.count, space)
  local first_slot, last_slot = request_slot_range(request_index)
  local inserted = insert_item_into_slots(inventory, first_slot, last_slot, stack.name, quality, amount)
  if inserted > 0 then
    local ingress_stack = inventory[slot]
    if stack_matches(ingress_stack, stack.name, quality) then
      ingress_stack.count = ingress_stack.count - inserted
    else
      inventory.remove(stack_definition(stack.name, quality, inserted))
    end
  end
  return inserted
end

local function process_request_buffers(port)
  local inventory = get_main_inventory(port.entity)
  if not inventory then return {} end
  port.materialized = port.materialized or {}
  local actual_counts = {}

  for index = 1, MAX_ITEM_REQUESTS do
    local request = port.requests and port.requests[index]
    local first_slot, last_slot = request_slot_range(index)
    if item_request_is_available(request) then
      local key = item_key(request.name, request.quality)
      local target = target_count_for_request(request)
      local request_count = 0
      for slot = first_slot, math.min(last_slot, #inventory) do
        local stack = inventory[slot]
        if stack and stack.valid_for_read then
          local quality = quality_name(stack.quality)
          if stack.name == request.name and quality == quality_name(request.quality) then
            request_count = request_count + stack.count
          else
            local removed_count = stack.count
            local removed_name = stack.name
            local removed_quality = quality
            stack.count = 0
            add_item_to_storage(removed_name, removed_quality, removed_count)
          end
        end
      end
      if request_count > target then
        local excess = request_count - target
        local removed = remove_item_from_slots(inventory, first_slot, last_slot, request.name, request.quality, excess)
        add_item_to_storage(request.name, request.quality, removed)
        request_count = request_count - removed
      end
      actual_counts[key] = request_count
    end
  end

  for key in pairs(port.materialized) do
    if not actual_counts[key] then
      local name, quality = split_item_key(key)
      local count = port.materialized[key]
      if count and count > 0 and not (prototypes.item[name] and quality_is_available(quality)) then
        add_item_to_storage(name, quality, count)
      end
      port.materialized[key] = nil
    end
  end
  for key, count in pairs(actual_counts) do
    port.materialized[key] = count > 0 and count or nil
  end

  return actual_counts
end

local function process_ingress_buffer(port)
  local inventory = get_main_inventory(port.entity)
  if not inventory then return end

  for slot = 1, #inventory do
    if not slot_is_active_request_buffer(port, slot) then
      local stack = inventory[slot]
      if stack and stack.valid_for_read then
        local name = stack.name
        local quality = quality_name(stack.quality)
        move_ingress_stack_to_request_buffer(port, inventory, stack, slot)
        local remaining_stack = inventory[slot]
        if stack_matches(remaining_stack, name, quality) then
          local count = remaining_stack.count
          remaining_stack.count = 0
          add_item_to_storage(name, quality, count)
        end
      end
    end
  end
end

target_count_for_request = function(request)
  local prototype = prototypes.item[request.name]
  if not prototype then return 0 end
  return prototype.stack_size * REQUEST_STACKS
end

local function normalise_fluid_materialized(materialized, request, observed_fluid)
  if fluid_is_storable(observed_fluid) then
    return {
      name = observed_fluid.name,
      amount = observed_fluid.amount,
      temperature = normalise_fluid_temperature(observed_fluid.name, observed_fluid.temperature)
    }
  end

  if type(materialized) == "table" then
    materialized.amount = materialized.amount or 0
    materialized.name = materialized.name or request
    materialized.temperature = normalise_fluid_temperature(materialized.name, materialized.temperature)
    return materialized
  elseif type(materialized) == "number" then
    return {
      name = request,
      amount = materialized,
      temperature = normalise_fluid_temperature(request, nil)
    }
  end
  return {
    name = request,
    amount = 0,
    temperature = normalise_fluid_temperature(request, nil)
  }
end

migrate_fluid_storage_temperature = function()
  for name, entry in pairs(storage.dimensional_storage.fluids or {}) do
    storage.dimensional_storage.fluids[name] = normalise_fluid_storage_entry(name, entry)
  end

  for _, port in pairs(storage.fluid_ports or {}) do
    local fluid = port.entity and port.entity.valid and port.entity.fluidbox and port.entity.fluidbox[1] or nil
    port.materialized = normalise_fluid_materialized(port.materialized, port.request, fluid)
  end

  storage.fluid_temperature_storage_version = FLUID_STORAGE_TEMPERATURE_VERSION
end

local function migrate_removed_item_requests(port, old_max_requests)
  local inventory = get_main_inventory(port.entity)
  for index = MAX_ITEM_REQUESTS + 1, old_max_requests do
    local request = port.requests and port.requests[index]
    if request then
      local key = item_key(request.name, request.quality)
      if inventory and item_request_is_available(request) then
        local first_slot = ((index - 1) * REQUEST_STACKS) + 1
        local last_slot = math.min(first_slot + REQUEST_STACKS - 1, #inventory)
        local count = count_item_in_slots(inventory, first_slot, last_slot, request.name, request.quality)
        if count > 0 then
          local removed = remove_item_from_slots(inventory, first_slot, last_slot, request.name, request.quality, count)
          add_item_to_storage(request.name, request.quality, removed)
        end
      elseif port.materialized and port.materialized[key] and port.materialized[key] > 0 then
        add_item_to_storage(request.name, request.quality, port.materialized[key])
      end
      if port.materialized then port.materialized[key] = nil end
      port.requests[index] = nil
    end
  end
end

local function normalise_item_port_state(port, entity)
  port = port or {}
  port.entity = entity
  port.requests = port.requests or {}
  port.materialized = port.materialized or {}
  if port.mode == "supply" then
    port.requests = {}
    port.materialized = {}
  else
    migrate_removed_item_requests(port, 9)
  end
  port.mode = nil
  return port
end

local function normalise_fluid_port_state(port, entity)
  port = port or {}
  port.entity = entity
  if port.mode == "supply" then
    port.request = nil
  end
  port.mode = nil
  local fluid = entity and entity.valid and entity.fluidbox and entity.fluidbox[1] or nil
  port.materialized = normalise_fluid_materialized(port.materialized, port.request, fluid)
  return port
end

local item_port_request_keys
local rebalance_item_request_keys

local function clear_destroy_registration(port)
  if port and port.destroy_registration then
    storage.destroy_registrations[port.destroy_registration] = nil
    port.destroy_registration = nil
  end
end

local function register_destroy_watch(port, entity, port_type)
  if port.destroy_registration and storage.destroy_registrations[port.destroy_registration] then return end
  port.destroy_registration = nil
  local registration_number = script.register_on_object_destroyed(entity)
  port.destroy_registration = registration_number
  storage.destroy_registrations[registration_number] = {
    port_type = port_type,
    unit_number = entity.unit_number
  }
end

local function return_materialized_items_to_storage(port)
  for key, count in pairs(port.materialized or {}) do
    if count and count > 0 then
      local name, quality = split_item_key(key)
      add_item_to_storage(name, quality, count)
    end
  end
  port.materialized = {}
end

local function return_orphan_materialized_items_to_storage(port)
  for key, count in pairs(port.materialized or {}) do
    local name, quality = split_item_key(key)
    if count and count > 0 and not (prototypes.item[name] and quality_is_available(quality)) then
      add_item_to_storage(name, quality, count)
    end
  end
end

local function return_materialized_fluid_to_storage(port)
  port.materialized = normalise_fluid_materialized(port.materialized, port.request)
  if port.materialized.name and port.materialized.amount and port.materialized.amount > 0 then
    add_fluid_to_storage(port.materialized.name, port.materialized.amount, port.materialized.temperature)
  end
  port.materialized = {name = port.request, amount = 0, temperature = normalise_fluid_temperature(port.request, nil)}
end

local function set_fluidbox_filter(entity, fluid)
  if not (entity and entity.valid and entity.fluidbox) then return false end
  local filter = fluid_is_available(fluid) and fluid or nil
  local call_ok, result = pcall(function() return entity.fluidbox.set_filter(1, filter) end)
  return call_ok and result ~= false
end

local function apply_fluid_request_filter(port)
  if not (port and port.entity and port.entity.valid) then return false end
  local filter = fluid_is_available(port.request) and port.request or nil
  return set_fluidbox_filter(port.entity, filter)
end

local function register_item_port(entity)
  if not (entity and entity.valid) then return end
  local port = normalise_item_port_state(storage.item_ports[entity.unit_number], entity)
  storage.item_ports[entity.unit_number] = port
  register_destroy_watch(port, entity, "item")
  apply_request_filters(port)
end

local function register_fluid_port(entity)
  if not (entity and entity.valid) then return end
  local port = normalise_fluid_port_state(storage.fluid_ports[entity.unit_number], entity)
  storage.fluid_ports[entity.unit_number] = port
  register_destroy_watch(port, entity, "fluid")
  apply_fluid_request_filter(port)
end

local function register_dimensional_combinator(entity)
  if not (entity and entity.valid) then return end
  local combinator = storage.dimensional_combinators[entity.unit_number] or {}
  combinator.entity = entity
  combinator.signature = nil
  storage.dimensional_combinators[entity.unit_number] = combinator
  register_destroy_watch(combinator, entity, "combinator")
end

local function unregister_item_port(entity)
  if not (entity and entity.valid) then return end
  local port = storage.item_ports[entity.unit_number]
  if not port then return end
  local affected_keys = item_port_request_keys and item_port_request_keys(port) or {}
  return_orphan_materialized_items_to_storage(port)
  absorb_inventory_to_storage(entity)
  port.materialized = {}
  clear_destroy_registration(port)
  storage.item_ports[entity.unit_number] = nil
  rebalance_item_request_keys(affected_keys)
end

local function unregister_fluid_port(entity)
  if not (entity and entity.valid) then return end
  local port = storage.fluid_ports[entity.unit_number]
  if not port then return end
  set_fluidbox_filter(entity, nil)
  local fluid = entity.fluidbox and entity.fluidbox[1]
  if add_fluid_stack_to_storage(fluid) then
    entity.fluidbox[1] = nil
  end
  clear_destroy_registration(port)
  storage.fluid_ports[entity.unit_number] = nil
end

local function unregister_dimensional_combinator(entity)
  if not (entity and entity.valid) then return end
  local combinator = storage.dimensional_combinators[entity.unit_number]
  if not combinator then return end
  clear_destroy_registration(combinator)
  storage.dimensional_combinators[entity.unit_number] = nil
end

local function unregister_lost_item_port(unit_number, port)
  local affected_keys = item_port_request_keys and item_port_request_keys(port) or {}
  return_materialized_items_to_storage(port)
  clear_destroy_registration(port)
  storage.item_ports[unit_number] = nil
  rebalance_item_request_keys(affected_keys)
end

local function unregister_lost_fluid_port(unit_number, port)
  return_materialized_fluid_to_storage(port)
  clear_destroy_registration(port)
  storage.fluid_ports[unit_number] = nil
end

local function unregister_lost_dimensional_combinator(unit_number, combinator)
  clear_destroy_registration(combinator)
  storage.dimensional_combinators[unit_number] = nil
end

local function rebuild_dimensional_combinators()
  local previous = storage.dimensional_combinators or {}
  local rebuilt = {}

  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = names.combinator_entity}) do
      local combinator = previous[entity.unit_number] or {}
      combinator.entity = entity
      combinator.signature = nil
      rebuilt[entity.unit_number] = combinator
      register_destroy_watch(combinator, entity, "combinator")
    end
  end

  for unit_number, combinator in pairs(previous) do
    if not rebuilt[unit_number] then
      unregister_lost_dimensional_combinator(unit_number, combinator)
    end
  end

  storage.dimensional_combinators = rebuilt
  storage.dimensional_combinator_registry_version = COMBINATOR_REGISTRY_VERSION
end

local function rebuild_ports()
  local previous_item_ports = storage.item_ports or {}
  local previous_fluid_ports = storage.fluid_ports or {}
  local rebuilt_item_ports = {}
  local rebuilt_fluid_ports = {}

  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = names.item_port_entity}) do
      local port = normalise_item_port_state(previous_item_ports[entity.unit_number], entity)
      rebuilt_item_ports[entity.unit_number] = port
      register_destroy_watch(port, entity, "item")
      apply_request_filters(port)
    end
    for _, entity in pairs(surface.find_entities_filtered{name = names.fluid_port_entity}) do
      local port = normalise_fluid_port_state(previous_fluid_ports[entity.unit_number], entity)
      rebuilt_fluid_ports[entity.unit_number] = port
      register_destroy_watch(port, entity, "fluid")
      apply_fluid_request_filter(port)
    end
  end

  for unit_number, port in pairs(previous_item_ports) do
    if not rebuilt_item_ports[unit_number] then
      unregister_lost_item_port(unit_number, port)
    end
  end
  for unit_number, port in pairs(previous_fluid_ports) do
    if not rebuilt_fluid_ports[unit_number] then
      unregister_lost_fluid_port(unit_number, port)
    end
  end

  storage.item_ports = rebuilt_item_ports
  storage.fluid_ports = rebuilt_fluid_ports
end

local function on_entity_created(entity)
  ensure_storage()
  if not (entity and entity.valid) then return end
  if entity.name == names.item_port_entity then
    register_item_port(entity)
  elseif entity.name == names.fluid_port_entity then
    register_fluid_port(entity)
  elseif entity.name == names.combinator_entity then
    register_dimensional_combinator(entity)
  end
end

local function on_entity_removed(entity)
  ensure_storage()
  if not (entity and entity.valid) then return end
  if entity.name == names.item_port_entity then
    unregister_item_port(entity)
  elseif entity.name == names.fluid_port_entity then
    unregister_fluid_port(entity)
  elseif entity.name == names.combinator_entity then
    unregister_dimensional_combinator(entity)
  end
end

local function clear_cloned_item_port_inventory(entity)
  local inventory = get_main_inventory(entity)
  if inventory then inventory.clear() end
end

local function clear_cloned_fluid_port_fluidbox(entity)
  if entity and entity.valid and entity.fluidbox then
    entity.fluidbox[1] = nil
  end
end

local function on_entity_cloned(event)
  ensure_storage()
  local entity = event.destination
  if not (entity and entity.valid) then return end
  if entity.name == names.item_port_entity then
    clear_cloned_item_port_inventory(entity)
    register_item_port(entity)
  elseif entity.name == names.fluid_port_entity then
    clear_cloned_fluid_port_fluidbox(entity)
    register_fluid_port(entity)
  elseif entity.name == names.combinator_entity then
    register_dimensional_combinator(entity)
  end
end

local function on_registered_object_destroyed(event)
  ensure_storage()
  local registration = storage.destroy_registrations[event.registration_number]
  if not registration then return end
  storage.destroy_registrations[event.registration_number] = nil

  if registration.port_type == "item" then
    local port = storage.item_ports[registration.unit_number]
    if port then
      local affected_keys = item_port_request_keys and item_port_request_keys(port) or {}
      return_materialized_items_to_storage(port)
      storage.item_ports[registration.unit_number] = nil
      rebalance_item_request_keys(affected_keys)
    end
  elseif registration.port_type == "fluid" then
    local port = storage.fluid_ports[registration.unit_number]
    if port then
      return_materialized_fluid_to_storage(port)
      storage.fluid_ports[registration.unit_number] = nil
    end
  elseif registration.port_type == "combinator" then
    storage.dimensional_combinators[registration.unit_number] = nil
  end
end

local function request_sort_less(left, right)
  return (left.unit_number or 0) < (right.unit_number or 0)
end

local function active_requests(requests)
  local active = {}
  for _, request in ipairs(requests) do
    if request.missing - request.assigned > 0 then
      active[#active + 1] = request
    end
  end
  table.sort(active, request_sort_less)
  return active
end

local function distribute_item_amount(total, requests, key)
  local remaining = math.floor(total)
  if remaining <= 0 then return end

  local active = active_requests(requests)
  if #active == 0 then return end

  local initial_active_count = #active
  local total_assigned = 0
  local start = ((storage.distribution_offsets.items[key] or 0) % #active) + 1

  while remaining > 0 and #active > 0 do
    local base_share = math.floor(remaining / #active)
    local remainder = remaining % #active
    local assigned_this_round = 0
    local next_active = {}

    for step = 0, #active - 1 do
      if remaining <= 0 then break end
      local request = active[((start + step - 1) % #active) + 1]
      local share = base_share
      if remainder > 0 then
        share = share + 1
        remainder = remainder - 1
      end
      if share <= 0 then share = 1 end
      local amount = math.min(request.missing - request.assigned, share, remaining)
      if amount > 0 then
        request.assigned = request.assigned + amount
        remaining = remaining - amount
        assigned_this_round = assigned_this_round + amount
        total_assigned = total_assigned + amount
      end
    end

    for _, request in ipairs(active) do
      if request.assigned < request.missing then
        next_active[#next_active + 1] = request
      end
    end
    if assigned_this_round == 0 then break end
    active = next_active
    if #active > 0 then
      start = ((start - 1) % #active) + 1
    end
  end

  if total_assigned > 0 then
    storage.distribution_offsets.items[key] = ((storage.distribution_offsets.items[key] or 0) + total_assigned) % initial_active_count
  end
end

local function distribute_fluid_amount(total, requests)
  local remaining = total
  if remaining <= 0 then return end

  local active = active_requests(requests)
  while remaining > 0.000001 and #active > 0 do
    local share = remaining / #active
    local next_active = {}
    local assigned_this_round = 0

    for _, request in ipairs(active) do
      local amount = math.min(request.missing - request.assigned, share)
      if amount > 0 then
        request.assigned = request.assigned + amount
        remaining = remaining - amount
        assigned_this_round = assigned_this_round + amount
      end
      if request.assigned < request.missing then
        next_active[#next_active + 1] = request
      end
    end

    if assigned_this_round <= 0.000001 then break end
    active = next_active
  end
end

local function item_port_requests_key(port, key)
  for index = 1, MAX_ITEM_REQUESTS do
    local request = port.requests and port.requests[index]
    if item_request_is_available(request) and item_key(request.name, request.quality) == key then
      return true
    end
  end
  return false
end

item_port_request_keys = function(port)
  local keys = {}
  for index = 1, MAX_ITEM_REQUESTS do
    local request = port.requests and port.requests[index]
    if item_request_is_available(request) then
      keys[item_key(request.name, request.quality)] = true
    end
  end
  return keys
end

local function sync_materialized_item_count(port, key)
  port.materialized = port.materialized or {}
  local materialized = port.materialized[key] or 0
  if materialized <= 0 then return 0 end

  local name, quality = split_item_key(key)
  local inventory = get_main_inventory(port.entity)
  if not inventory then
    port.materialized[key] = nil
    return 0
  end

  local actual = 0
  for index = 1, MAX_ITEM_REQUESTS do
    local request = port.requests and port.requests[index]
    if item_request_is_available(request) and item_key(request.name, request.quality) == key then
      local first_slot, last_slot = request_slot_range(index)
      actual = actual + count_item_in_slots(inventory, first_slot, last_slot, name, quality)
    end
  end
  if actual < materialized then
    materialized = actual
    port.materialized[key] = materialized > 0 and materialized or nil
  elseif actual > materialized then
    materialized = actual
    port.materialized[key] = materialized
  end
  return materialized
end

local function collect_item_rebalance_requesters(key)
  local name, quality = split_item_key(key)
  if not (prototypes.item[name] and quality_is_available(quality)) then return {} end

  local requesters = {}
  for _, port in pairs(storage.item_ports) do
    if port.entity and port.entity.valid and item_port_requests_key(port, key) then
      local inventory = get_main_inventory(port.entity)
      if inventory then
        requesters[#requesters + 1] = {
          port = port,
          inventory = inventory,
          unit_number = port.entity.unit_number,
          name = name,
          quality = quality,
          current = sync_materialized_item_count(port, key),
          capacity = target_count_for_request{name = name, quality = quality},
          assigned = 0
        }
      end
    end
  end
  table.sort(requesters, request_sort_less)
  return requesters
end

local function calculate_rebalance_allocations(total, requesters, key)
  local allocation_requests = {}
  for index, requester in ipairs(requesters) do
    allocation_requests[index] = {
      unit_number = requester.unit_number,
      missing = requester.capacity,
      assigned = 0
    }
  end

  distribute_item_amount(total, allocation_requests, key)

  local allocations = {}
  for index, requester in ipairs(requesters) do
    allocations[requester.unit_number] = allocation_requests[index].assigned
  end
  return allocations
end

local function rebalance_item_request_key(key)
  local requesters = collect_item_rebalance_requesters(key)
  if #requesters < 2 then return end

  local total = storage.dimensional_storage.items[key] or 0
  for _, requester in ipairs(requesters) do
    total = total + requester.current
  end

  local allocations = calculate_rebalance_allocations(total, requesters, key)

  for _, requester in ipairs(requesters) do
    local desired = allocations[requester.unit_number] or 0
    if requester.current > desired then
      local excess = requester.current - desired
      local removed = 0
      for index = 1, MAX_ITEM_REQUESTS do
        local port_request = requester.port.requests and requester.port.requests[index]
        if item_request_is_available(port_request) and item_key(port_request.name, port_request.quality) == key then
          local first_slot, last_slot = request_slot_range(index)
          removed = remove_item_from_slots(requester.inventory, first_slot, last_slot, requester.name, requester.quality, excess)
          break
        end
      end
      if removed > 0 then
        add_item_to_storage(requester.name, requester.quality, removed)
        requester.current = requester.current - removed
        requester.port.materialized[key] = requester.current > 0 and requester.current or nil
      end
    end
  end

  for _, requester in ipairs(requesters) do
    local desired = allocations[requester.unit_number] or 0
    if requester.current < desired then
      local needed = desired - requester.current
      local removed = remove_item_from_storage(requester.name, requester.quality, needed)
      if removed > 0 then
        local inserted = 0
        for index = 1, MAX_ITEM_REQUESTS do
          local port_request = requester.port.requests and requester.port.requests[index]
          if item_request_is_available(port_request) and item_key(port_request.name, port_request.quality) == key then
            local first_slot, last_slot = request_slot_range(index)
            inserted = insert_item_into_slots(requester.inventory, first_slot, last_slot, requester.name, requester.quality, removed)
            break
          end
        end
        if inserted > 0 then
          requester.current = requester.current + inserted
          requester.port.materialized[key] = (requester.port.materialized[key] or 0) + inserted
        end
        if inserted < removed then
          add_item_to_storage(requester.name, requester.quality, removed - inserted)
        end
      end
    end
  end
end

rebalance_item_request_keys = function(keys)
  for key in pairs(keys or {}) do
    rebalance_item_request_key(key)
  end
end

local function process_item_ports()
  for unit_number, port in pairs(storage.item_ports) do
    if not (port.entity and port.entity.valid) then
      unregister_lost_item_port(unit_number, port)
    elseif not next(item_port_request_keys(port)) then
      return_orphan_materialized_items_to_storage(port)
      absorb_inventory_to_storage(port.entity)
      port.materialized = {}
      apply_request_filters(port)
    else
      process_request_buffers(port)
      process_ingress_buffer(port)
      process_request_buffers(port)
    end
  end

  local grouped = {}
  for _, port in pairs(storage.item_ports) do
    if port.entity and port.entity.valid then
      local inventory = get_main_inventory(port.entity)
      if inventory then
        for index = 1, MAX_ITEM_REQUESTS do
          local request = port.requests and port.requests[index]
          if item_request_is_available(request) then
            local target = target_count_for_request(request)
            local current = request_buffer_count(inventory, index, request)
            local missing = current < request_refill_threshold(request) and (target - current) or 0
            if missing > 0 then
              local key = item_key(request.name, request.quality)
              grouped[key] = grouped[key] or {}
              grouped[key][#grouped[key] + 1] = {
                port = port,
                unit_number = port.entity.unit_number,
                name = request.name,
                quality = quality_name(request.quality),
                missing = missing,
                assigned = 0
              }
            end
          end
        end
      end
    end
  end

  for key, requests in pairs(grouped) do
    distribute_item_amount(storage.dimensional_storage.items[key] or 0, requests, key)
    for _, request in ipairs(requests) do
      if request.assigned > 0 then
        local inventory = get_main_inventory(request.port.entity)
        if inventory then
          local removed = remove_item_from_storage(request.name, request.quality, request.assigned)
          local inserted = 0
          for index = 1, MAX_ITEM_REQUESTS do
            local port_request = request.port.requests and request.port.requests[index]
            if item_request_is_available(port_request) and port_request.name == request.name and quality_name(port_request.quality) == quality_name(request.quality) then
              local first_slot, last_slot = request_slot_range(index)
              inserted = insert_item_into_slots(inventory, first_slot, last_slot, request.name, request.quality, removed)
              break
            end
          end
          if inserted > 0 then
            local key = item_key(request.name, request.quality)
            request.port.materialized = request.port.materialized or {}
            request.port.materialized[key] = (request.port.materialized[key] or 0) + inserted
          end
          if inserted < removed then
            add_item_to_storage(request.name, request.quality, removed - inserted)
          end
        end
      end
    end
  end
end

local function set_fluidbox_content(entity, name, amount, temperature)
  if amount and amount > 0 then
    entity.fluidbox[1] = {name = name, amount = amount, temperature = normalise_fluid_temperature(name, temperature)}
  else
    entity.fluidbox[1] = nil
  end
end

local function return_fluidbox_to_storage(port)
  if not (port.entity and port.entity.valid and port.entity.fluidbox) then return false end
  local fluid = port.entity.fluidbox[1]
  if not (fluid and fluid.name and fluid.amount and fluid.amount > 0) then
    port.materialized = normalise_fluid_materialized(port.materialized, port.request)
    port.materialized.amount = 0
    port.materialized.name = port.request
    port.materialized.temperature = normalise_fluid_temperature(port.request, nil)
    return true
  end
  if not add_fluid_stack_to_storage(fluid) then return false end
  port.entity.fluidbox[1] = nil
  port.materialized = {name = port.request, amount = 0, temperature = normalise_fluid_temperature(port.request, nil)}
  return true
end

local function clear_mismatched_fluid_request(port)
  if not (port and fluid_is_available(port.request) and port.entity and port.entity.valid and port.entity.fluidbox) then
    return false
  end

  local fluid = port.entity.fluidbox[1]
  if not (fluid and fluid.name and fluid.amount and fluid.amount > 0 and fluid.name ~= port.request) then
    return false
  end

  port.request = nil
  port.materialized = {name = nil, amount = 0, temperature = nil}
  apply_fluid_request_filter(port)

  if add_fluid_stack_to_storage(fluid) then
    port.entity.fluidbox[1] = nil
  end

  return true
end

local function return_unrequested_fluid(port)
  if not (port.entity and port.entity.valid and port.entity.fluidbox) then return end
  port.materialized = normalise_fluid_materialized(port.materialized, port.request)
  local fluid = port.entity.fluidbox[1]
  if not (fluid and fluid.name and fluid.amount and fluid.amount > 0) then
    port.materialized.amount = 0
    port.materialized.name = port.request
    port.materialized.temperature = normalise_fluid_temperature(port.request, nil)
    return
  end

  if clear_mismatched_fluid_request(port) then
    return
  end

  if not fluid_is_available(port.request) then
    add_fluid_stack_to_storage(fluid)
    port.entity.fluidbox[1] = nil
    port.materialized = {name = nil, amount = 0, temperature = nil}
    apply_fluid_request_filter(port)
    return
  end

  if port.materialized.name ~= fluid.name then
    port.materialized = {name = fluid.name, amount = 0, temperature = normalise_fluid_temperature(fluid.name, fluid.temperature)}
  end

  if fluid.amount > FLUID_REQUEST_TARGET then
    local before_amount = fluid.amount
    local temperature = normalise_fluid_temperature(fluid.name, fluid.temperature)
    set_fluidbox_content(port.entity, fluid.name, FLUID_REQUEST_TARGET, temperature)
    fluid = port.entity.fluidbox and port.entity.fluidbox[1]
    local after_amount = (fluid and fluid.name == port.request and fluid.amount) or 0
    local removed = before_amount - after_amount
    if removed > 0 then
      add_fluid_to_storage(port.request, removed, temperature)
    end
  end

  if not (fluid and fluid.name == port.request and fluid.amount and fluid.amount > 0) then
    port.materialized.amount = 0
    port.materialized.temperature = normalise_fluid_temperature(port.request, nil)
    return
  end

  port.materialized.amount = fluid.amount
  port.materialized.temperature = normalise_fluid_temperature(fluid.name, fluid.temperature)
end

local function process_fluid_ports()
  local changed_requests = {}
  for unit_number, port in pairs(storage.fluid_ports) do
    if not (port.entity and port.entity.valid) then
      unregister_lost_fluid_port(unit_number, port)
    elseif clear_mismatched_fluid_request(port) then
      changed_requests[unit_number] = true
    elseif not fluid_is_available(port.request) then
      local fluid = port.entity.fluidbox and port.entity.fluidbox[1]
      if add_fluid_stack_to_storage(fluid) then
        port.entity.fluidbox[1] = nil
      end
      port.materialized = {name = nil, amount = 0, temperature = nil}
    else
      return_unrequested_fluid(port)
    end
  end

  local grouped = {}
  for _, port in pairs(storage.fluid_ports) do
    if port.entity and port.entity.valid and fluid_is_available(port.request) then
      local fluid = port.entity.fluidbox and port.entity.fluidbox[1]
      local current = 0
      if fluid and fluid.name == port.request then
        current = fluid.amount
      elseif fluid and fluid.amount and fluid.amount > 0 then
        current = FLUID_REQUEST_TARGET
      end
      local missing = FLUID_REQUEST_TARGET - current
      if missing > 0 then
        local key = fluid_key(port.request)
        grouped[key] = grouped[key] or {}
        grouped[key][#grouped[key] + 1] = {
          port = port,
          unit_number = port.entity.unit_number,
          name = port.request,
          missing = missing,
          assigned = 0
        }
      end
    end
  end

  for key, requests in pairs(grouped) do
    local storage_entry = normalise_fluid_storage_entry(key, storage.dimensional_storage.fluids[key])
    distribute_fluid_amount(storage_entry and storage_entry.amount or 0, requests)
    for _, request in ipairs(requests) do
      if request.assigned > 0 then
        local removed, temperature = remove_fluid_from_storage(request.name, request.assigned)
        if removed > 0 then
          local inserted = request.port.entity.insert_fluid{
            name = request.name,
            amount = removed,
            temperature = normalise_fluid_temperature(request.name, temperature)
          }
          if inserted > 0 then
            local fluid = request.port.entity.fluidbox and request.port.entity.fluidbox[1]
            request.port.materialized = normalise_fluid_materialized(request.port.materialized, request.name, fluid)
          end
          if inserted < removed then
            add_fluid_to_storage(request.name, removed - inserted, temperature)
          end
        end
      end
    end
  end

  return changed_requests
end

local function player_state(player_index)
  storage.players[player_index] = storage.players[player_index] or {search = ""}
  local state = storage.players[player_index]
  state.search = state.search or ""
  state.translations = state.translations or {items = {}, fluids = {}}
  state.translations.items = state.translations.items or {}
  state.translations.fluids = state.translations.fluids or {}
  state.pending_translations = state.pending_translations or {}
  state.storage_gui = state.storage_gui or {}
  state.storage_gui.signature = state.storage_gui.signature or ""
  state.storage_gui.dirty = state.storage_gui.dirty or false
  return state
end

local function translation_cache_for(state, kind)
  return kind == TRANSLATION_KIND_FLUID and state.translations.fluids or state.translations.items
end

local function request_localised_name(player, kind, name, localised_name)
  if not (player and player.valid and player.connected) then return end
  local state = player_state(player.index)
  local cache = translation_cache_for(state, kind)
  if cache[name] ~= nil then return end
  local request_id = player.request_translation(localised_name or name)
  if not request_id then return end
  cache[name] = false
  state.pending_translations[request_id] = {kind = kind, name = name}
end

local function localised_search_text(state, kind, name)
  local translated = translation_cache_for(state, kind)[name]
  if type(translated) == "string" then
    return translated
  end
  return ""
end

local function matches_search(state, kind, name, quality, search)
  local lowered = string.lower(search or "")
  if lowered == "" then return true end
  local prototype_text = string.lower(name .. " " .. (quality or ""))
  if prototype_text:find(lowered, 1, true) then return true end
  return localised_search_text(state, kind, name):find(lowered, 1, true) ~= nil
end

local function get_open_port(player)
  local state = player_state(player.index)
  if state.port_type == "item" then
    return storage.item_ports[state.unit_number], "item"
  elseif state.port_type == "fluid" then
    return storage.fluid_ports[state.unit_number], "fluid"
  end
  return nil, nil
end

local function destroy_gui(player)
  local root = player.gui.screen.dimensional_port_frame
  if root then root.destroy() end
  if storage.players and storage.players[player.index] then
    local state = storage.players[player.index]
    state.port_type = nil
    state.unit_number = nil
    state.storage_gui = {signature = "", dirty = true}
  end
end

local function add_item_requests(parent, port)
  local request_frame = parent.add{type = "frame", direction = "vertical", caption = {"dimensional-port.request-items"}}
  local request_table = request_frame.add{type = "table", column_count = MAX_ITEM_REQUESTS}
  for index = 1, MAX_ITEM_REQUESTS do
    local request = item_request_is_available(port.requests[index]) and port.requests[index] or nil
    request_table.add{
      type = "choose-elem-button",
      elem_type = "item-with-quality",
      style = "slot_button",
      ["item-with-quality"] = request and {
        name = request.name,
        quality = quality_name(request.quality)
      } or nil,
      tags = {action = "item-request", index = index}
    }
  end
end

local function add_fluid_request(parent, port)
  local request_frame = parent.add{type = "frame", direction = "vertical", caption = {"dimensional-port.request-fluid"}}
  request_frame.add{
    type = "choose-elem-button",
    elem_type = "fluid",
    fluid = fluid_is_available(port.request) and port.request or nil,
    tags = {action = "fluid-request"}
  }
end

local function add_display_count(counts, key, amount)
  if amount and amount > 0 then
    counts[key] = (counts[key] or 0) + amount
  end
end

local function displayed_item_counts()
  local counts = {}
  for key, count in pairs(storage.dimensional_storage.items) do
    add_display_count(counts, key, count)
  end
  for _, port in pairs(storage.item_ports) do
    for key, count in pairs(port.materialized or {}) do
      add_display_count(counts, key, count)
    end
  end
  return counts
end

local function safe_property(object, property)
  if not object then return nil end
  local ok, value = pcall(function() return object[property] end)
  if ok then return value end
  return nil
end

local function prototype_sort_parts(prototype)
  local subgroup = safe_property(prototype, "subgroup")
  local group = safe_property(prototype, "group") or safe_property(subgroup, "group")
  return {
    safe_property(group, "order") or "",
    safe_property(subgroup, "order") or "",
    safe_property(prototype, "order") or "",
    safe_property(prototype, "name") or ""
  }
end

local function quality_level(quality)
  local quality_prototype = prototypes.quality and prototypes.quality[quality_name(quality)]
  return (quality_prototype and quality_prototype.level) or 0
end

local function quality_localised_name(quality)
  local name = quality_name(quality)
  local quality_prototype = prototypes.quality and prototypes.quality[name]
  return (quality_prototype and quality_prototype.localised_name) or name
end

local function format_temperature(temperature)
  if type(temperature) == "number" then
    return string.format("%.1f", temperature)
  end
  return "?"
end

local function storage_entry_element_name(index)
  return STORAGE_ENTRY_PREFIX .. index
end

local function storage_entry_signature(entries)
  local parts = {}
  for index, entry in ipairs(entries) do
    parts[index] = entry.kind .. ":" .. entry.key
  end
  return table.concat(parts, STORAGE_SIGNATURE_SEPARATOR)
end

local function storage_entry_less(left, right)
  for index = 1, #left.sort_parts do
    if left.sort_parts[index] ~= right.sort_parts[index] then
      return left.sort_parts[index] < right.sort_parts[index]
    end
  end
  if left.kind ~= right.kind then return left.kind < right.kind end
  if left.quality_level ~= right.quality_level then return left.quality_level < right.quality_level end
  return left.key < right.key
end

local function collect_storage_entries(player, search)
  local state = player_state(player.index)
  local entries = {}

  for key, count in pairs(displayed_item_counts()) do
    if count > 0 then
      local name, quality = split_item_key(key)
      local prototype = prototypes.item[name]
      local normalised_quality = quality_name(quality)
      if prototype and quality_is_available(normalised_quality) then
        local local_name = prototype.localised_name
        request_localised_name(player, TRANSLATION_KIND_ITEM, name, local_name)
        if matches_search(state, TRANSLATION_KIND_ITEM, name, normalised_quality, search) then
          entries[#entries + 1] = {
            kind = "item",
            key = key,
            name = name,
            quality = normalised_quality,
            amount = count,
            sprite = "item/" .. name,
            tooltip = {"dimensional-port.item-tooltip", local_name, quality_localised_name(normalised_quality), count},
            sort_parts = prototype_sort_parts(prototype),
            quality_level = quality_level(normalised_quality)
          }
        end
      end
    end
  end

  for name, stored_fluid in pairs(storage.dimensional_storage.fluids) do
    local fluid_entry = normalise_fluid_storage_entry(name, stored_fluid)
    local amount = fluid_entry and fluid_entry.amount or 0
    if amount > 0 then
      local prototype = prototypes.fluid[name]
      if prototype then
        local local_name = prototype.localised_name
        request_localised_name(player, TRANSLATION_KIND_FLUID, name, local_name)
        if matches_search(state, TRANSLATION_KIND_FLUID, name, nil, search) then
          entries[#entries + 1] = {
            kind = "fluid",
            key = fluid_key(name),
            name = name,
            amount = amount,
            sprite = "fluid/" .. name,
            tooltip = {"dimensional-port.fluid-tooltip", local_name, amount, format_temperature(fluid_entry.temperature)},
            sort_parts = prototype_sort_parts(prototype),
            quality_level = 0
          }
        end
      end
    end
  end

  table.sort(entries, storage_entry_less)
  return entries
end

local function circuit_signal_count(amount)
  local count = math.floor(amount or 0)
  if count <= 0 then return nil end
  return math.min(count, CIRCUIT_SIGNAL_MAX)
end

local function collect_circuit_signal_entries()
  local entries = {}

  for key, count in pairs(displayed_item_counts()) do
    local signal_count = circuit_signal_count(count)
    if signal_count then
      local name, quality = split_item_key(key)
      local normalised_quality = quality_name(quality)
      local prototype = prototypes.item[name]
      if prototype and quality_is_available(normalised_quality) then
        entries[#entries + 1] = {
          kind = "item",
          key = key,
          signal = {type = "item", name = name, quality = normalised_quality},
          count = signal_count,
          sort_parts = prototype_sort_parts(prototype),
          quality_level = quality_level(normalised_quality)
        }
      end
    end
  end

  for name, stored_fluid in pairs(storage.dimensional_storage.fluids) do
    local fluid_entry = normalise_fluid_storage_entry(name, stored_fluid)
    local signal_count = circuit_signal_count(fluid_entry and fluid_entry.amount or 0)
    local prototype = prototypes.fluid[name]
    if signal_count and prototype then
      entries[#entries + 1] = {
        kind = "fluid",
        key = fluid_key(name),
        signal = {type = "fluid", name = name, quality = NORMAL_QUALITY},
        count = signal_count,
        sort_parts = prototype_sort_parts(prototype),
        quality_level = 0
      }
    end
  end

  table.sort(entries, storage_entry_less)
  return entries
end

local function circuit_signal_signature(entries)
  local parts = {}
  for index, entry in ipairs(entries) do
    local signal = entry.signal
    parts[index] = (signal.type or "item") .. ":" .. signal.name .. ":" .. (signal.quality or NORMAL_QUALITY) .. ":" .. entry.count
  end
  return table.concat(parts, STORAGE_SIGNATURE_SEPARATOR)
end

local function sync_combinator_sections(entity, entries)
  if not (entity and entity.valid) then return false end
  local behavior = entity.get_control_behavior()
  if not behavior then return false end
  behavior.enabled = true

  local filters_per_section = prototypes.utility_constants.max_logistic_filter_count
  if type(filters_per_section) ~= "number" or filters_per_section <= 0 then return false end
  local needed_sections = math.max(1, math.ceil(#entries / filters_per_section))

  while behavior.sections_count < needed_sections do
    if not behavior.add_section() then return false end
  end
  while behavior.sections_count > needed_sections do
    if not behavior.remove_section(behavior.sections_count) then return false end
  end

  for section_index = 1, needed_sections do
    local section = behavior.get_section(section_index)
    if not (section and section.valid and section.is_manual) then return false end
    local filters = {}
    local first = ((section_index - 1) * filters_per_section) + 1
    local last = math.min(section_index * filters_per_section, #entries)
    for entry_index = first, last do
      local entry = entries[entry_index]
      filters[#filters + 1] = {value = entry.signal, min = entry.count}
    end
    section.filters = filters
    section.active = true
    section.multiplier = 1
  end
  return true
end

local function sync_dimensional_combinator(combinator, entries, signature, force)
  if not (combinator and combinator.entity and combinator.entity.valid) then return end
  entries = entries or collect_circuit_signal_entries()
  signature = signature or circuit_signal_signature(entries)
  if not force and combinator.signature == signature then return end
  if sync_combinator_sections(combinator.entity, entries) then combinator.signature = signature end
end

local function sync_dimensional_combinators(force)
  if storage.dimensional_combinator_registry_version ~= COMBINATOR_REGISTRY_VERSION then
    rebuild_dimensional_combinators()
  end
  local entries = collect_circuit_signal_entries()
  local signature = circuit_signal_signature(entries)
  for unit_number, combinator in pairs(storage.dimensional_combinators) do
    if combinator.entity and combinator.entity.valid then
      sync_dimensional_combinator(combinator, entries, signature, force)
    else
      storage.dimensional_combinators[unit_number] = nil
    end
  end
end

local function add_storage_entry(parent, entry, index)
  local icon = parent.add{
    type = "sprite-button",
    name = storage_entry_element_name(index),
    sprite = entry.sprite,
    number = entry.amount,
    tooltip = entry.tooltip,
    style = "slot_button",
    tags = {
      action = "storage-entry",
      kind = entry.kind,
      name = entry.name,
      quality = entry.quality
    }
  }
  if entry.kind == "item" and entry.quality ~= NORMAL_QUALITY then
    icon.quality = entry.quality
  end
end

local function rebuild_storage_table(parent, player, entries, signature)
  local old_scroll = parent.dimensional_port_storage_scroll
  if old_scroll then old_scroll.destroy() end

  local scroll_pane = parent.add{
    type = "scroll-pane",
    name = "dimensional_port_storage_scroll",
    vertical_scroll_policy = "auto",
    horizontal_scroll_policy = "never"
  }
  scroll_pane.style.maximal_height = 420
  local table_element = scroll_pane.add{
    type = "table",
    name = "dimensional_port_storage_table",
    column_count = STORAGE_LIST_COLUMNS
  }

  for index, entry in ipairs(entries) do
    add_storage_entry(table_element, entry, index)
  end

  local state = player_state(player.index)
  state.storage_gui.signature = signature
  state.storage_gui.dirty = false
end

local function update_storage_table(parent, entries)
  local scroll_pane = parent.dimensional_port_storage_scroll
  local table_element = scroll_pane and scroll_pane.dimensional_port_storage_table
  if not table_element then return false end

  for index, entry in ipairs(entries) do
    local icon = table_element[storage_entry_element_name(index)]
    if not icon then return false end
    icon.number = entry.amount
    icon.tooltip = entry.tooltip
  end

  return true
end

local function add_storage_table(parent, player, search)
  local entries = collect_storage_entries(player, search)
  rebuild_storage_table(parent, player, entries, storage_entry_signature(entries))
end

local function refresh_storage_list(player, force_rebuild)
  local frame = player.gui.screen.dimensional_port_frame
  if not frame then return end
  local storage_frame = frame.dimensional_port_storage_frame
  if not storage_frame then return end
  local state = player_state(player.index)
  local entries = collect_storage_entries(player, state.search)
  local signature = storage_entry_signature(entries)

  if force_rebuild or state.storage_gui.dirty or state.storage_gui.signature ~= signature then
    rebuild_storage_table(storage_frame, player, entries, signature)
    return
  end

  if not update_storage_table(storage_frame, entries) then
    rebuild_storage_table(storage_frame, player, entries, signature)
  else
    state.storage_gui.dirty = false
  end
end

local function add_storage_list(parent, player, search)
  local storage_frame = parent.add{
    type = "frame",
    name = "dimensional_port_storage_frame",
    direction = "vertical",
    caption = {"dimensional-port.storage"}
  }
  local search_flow = storage_frame.add{
    type = "flow",
    name = "dimensional_port_search_flow",
    direction = "horizontal"
  }
  search_flow.add{
    type = "label",
    caption = {"dimensional-port.search-caption"},
    tooltip = {"dimensional-port.search-tooltip"}
  }
  search_flow.add{
    type = "textfield",
    name = "dimensional_port_search",
    text = search or "",
    tooltip = {"dimensional-port.search-tooltip"},
    tags = {action = "search"}
  }
  search_flow.add{
    type = "sprite-button",
    sprite = "utility/close",
    tooltip = {"dimensional-port.clear-search"},
    tags = {action = "clear-search"}
  }
  add_storage_table(storage_frame, player, search)
end

local function build_gui(player, port, port_type)
  destroy_gui(player)
  local state = player_state(player.index)
  state.port_type = port_type
  state.unit_number = port.entity.unit_number
  state.search = state.search or ""
  state.storage_gui = {signature = "", dirty = true}

  local frame = player.gui.screen.add{
    type = "frame",
    name = "dimensional_port_frame",
    direction = "vertical"
  }
  frame.auto_center = true
  local title_flow = frame.add{type = "flow", direction = "horizontal"}
  title_flow.drag_target = frame
  title_flow.add{
    type = "label",
    caption = {"dimensional-port.title"},
    style = "frame_title"
  }
  local title_spacer = title_flow.add{type = "empty-widget"}
  title_spacer.style.horizontally_stretchable = true
  title_spacer.style.height = 24
  title_spacer.drag_target = frame
  title_flow.add{
    type = "sprite-button",
    name = "dimensional_port_close",
    sprite = "utility/close",
    style = "frame_action_button",
    tags = {action = "close"}
  }
  if port_type == "item" then
    add_item_requests(frame, port)
  else
    add_fluid_request(frame, port)
  end
  add_storage_list(frame, player, state.search)
  player.opened = frame
end

local function refresh_gui(player)
  local port, port_type = get_open_port(player)
  if port and port.entity and port.entity.valid then
    build_gui(player, port, port_type)
  else
    destroy_gui(player)
  end
end

local function set_fluid_request(port, selection)
  local new_request = fluid_is_available(selection) and selection or nil
  if port.request == new_request then return end
  if not return_fluidbox_to_storage(port) then return end
  port.request = new_request
  port.materialized = {
    name = new_request,
    amount = 0,
    temperature = normalise_fluid_temperature(new_request, nil)
  }
  apply_fluid_request_filter(port)
end

local function normalize_item_request(selection)
  if type(selection) == "table" and selection.name and (selection.type == nil or selection.type == "item") and prototypes.item[selection.name] and quality_is_available(selection.quality) then
    return selection.name, quality_name(selection.quality)
  elseif type(selection) == "string" and prototypes.item[selection] then
    return selection, NORMAL_QUALITY
  end
  return nil, nil
end

local function set_item_request(port, index, selection, affected_keys)
  local run_rebalance = affected_keys == nil
  affected_keys = affected_keys or {}
  port.materialized = port.materialized or {}
  local old = port.requests[index]
  local old_key = old and item_key(old.name, old.quality) or nil
  local name, quality = normalize_item_request(selection)
  local new_key = name and item_key(name, quality) or nil

  if old_key == new_key then return end

  if old then
    affected_keys[old_key] = true
  end

  local inventory = get_main_inventory(port.entity)
  local first_slot, last_slot = request_slot_range(index)
  local returned = inventory and return_slot_range_to_storage(inventory, first_slot, last_slot) or {}

  if old then
    if item_request_is_available(old) then
      local materialized = port.materialized[old_key] or 0
      local observed = returned[old_key] or 0
      if materialized > observed and not inventory then
        add_item_to_storage(old.name, old.quality, materialized)
      end
    elseif port.materialized[old_key] and port.materialized[old_key] > 0 then
      add_item_to_storage(old.name, old.quality, port.materialized[old_key])
    end
    port.materialized[old_key] = nil
  end

  if name then
    for other_index = 1, MAX_ITEM_REQUESTS do
      local request = port.requests[other_index]
      if other_index ~= index and item_request_is_available(request) and request.name == name and quality_name(request.quality) == quality_name(quality) then
        set_item_request(port, other_index, nil, affected_keys)
      end
    end
    port.requests[index] = {name = name, quality = quality}
    affected_keys[new_key] = true
  else
    port.requests[index] = nil
  end
  apply_request_filters(port)

  if run_rebalance then
    for key in pairs(affected_keys) do
      rebalance_item_request_key(key)
    end
  end
end

local function add_storage_entry_to_request(player, port, port_type, tags)
  if port_type == "item" then
    if tags.kind ~= "item" then return false end
    local name, quality = normalize_item_request{name = tags.name, quality = tags.quality}
    if not name then return false end
    port.requests = port.requests or {}

    for index = 1, MAX_ITEM_REQUESTS do
      local request = port.requests[index]
      if item_request_is_available(request) and request.name == name and quality_name(request.quality) == quality then
        return false
      end
    end

    for index = 1, MAX_ITEM_REQUESTS do
      if not port.requests[index] then
        set_item_request(port, index, {name = name, quality = quality})
        refresh_gui(player)
        return true
      end
    end

    return false
  end

  if port_type == "fluid" then
    if tags.kind ~= "fluid" or not fluid_is_available(tags.name) then return false end
    set_fluid_request(port, tags.name)
    refresh_gui(player)
    return true
  end

  return false
end

script.on_init(function()
  ensure_storage()
  rebuild_ports()
  rebuild_dimensional_combinators()
end)

script.on_configuration_changed(function()
  ensure_storage()
  rebuild_ports()
  rebuild_dimensional_combinators()
end)

script.on_event({
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive
}, function(event)
  on_entity_created(event.entity or event.created_entity)
end)

local pre_remove_events = {}
if defines.events.on_pre_player_mined_item then pre_remove_events[#pre_remove_events + 1] = defines.events.on_pre_player_mined_item end
if defines.events.on_robot_pre_mined then pre_remove_events[#pre_remove_events + 1] = defines.events.on_robot_pre_mined end
if defines.events.on_entity_died then pre_remove_events[#pre_remove_events + 1] = defines.events.on_entity_died end
if defines.events.script_raised_destroy then pre_remove_events[#pre_remove_events + 1] = defines.events.script_raised_destroy end
script.on_event(pre_remove_events, function(event)
  on_entity_removed(event.entity)
end)

if defines.events.on_entity_cloned then
  script.on_event(defines.events.on_entity_cloned, on_entity_cloned)
end

if defines.events.on_object_destroyed then
  script.on_event(defines.events.on_object_destroyed, on_registered_object_destroyed)
end

if defines.events.on_entity_settings_pasted then
  script.on_event(defines.events.on_entity_settings_pasted, function(event)
    ensure_storage()
    local entity = event.destination
    if entity and entity.valid and entity.name == names.combinator_entity then
      register_dimensional_combinator(entity)
    end
  end)
end

script.on_nth_tick(UPDATE_INTERVAL, function()
  ensure_storage()
  process_item_ports()
  local changed_fluid_requests = process_fluid_ports()
  sync_dimensional_combinators(false)
  for _, player in pairs(game.connected_players) do
    local state = storage.players and storage.players[player.index]
    local frame = player.gui.screen.dimensional_port_frame
    if frame and state and state.port_type == "fluid" and changed_fluid_requests[state.unit_number] then
      refresh_gui(player)
    else
      refresh_storage_list(player)
    end
  end
end)

script.on_event(defines.events.on_gui_opened, function(event)
  ensure_storage()
  local player = game.get_player(event.player_index)
  if not player then return end
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name == names.item_port_entity then
    player.opened = nil
    local port = storage.item_ports[entity.unit_number]
    if port then build_gui(player, port, "item") end
  elseif entity.name == names.fluid_port_entity then
    player.opened = nil
    local port = storage.fluid_ports[entity.unit_number]
    if port then build_gui(player, port, "fluid") end
  elseif entity.name == names.combinator_entity then
    player.opened = nil
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  if event.element and event.element.valid and event.element.name == "dimensional_port_frame" then
    destroy_gui(player)
  end
end)

script.on_event(defines.events.on_gui_click, function(event)
  ensure_storage()
  local element = event.element
  if not (element and element.valid and element.tags) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local tags = element.tags
  if tags.action == "close" then
    destroy_gui(player)
    return
  end
  local port, port_type = get_open_port(player)
  if not (port and port.entity and port.entity.valid) then return end
  if tags.action == "clear-search" then
    local state = player_state(player.index)
    state.search = ""
    local search = element.parent and element.parent.valid and element.parent.dimensional_port_search
    if search then search.text = "" end
    refresh_storage_list(player, true)
  elseif tags.action == "storage-entry" then
    if event.button and event.button ~= defines.mouse_button_type.left then return end
    add_storage_entry_to_request(player, port, port_type, tags)
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  ensure_storage()
  local element = event.element
  if not (element and element.valid and element.tags) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local port, port_type = get_open_port(player)
  if not (port and port.entity and port.entity.valid) then return end
  local tags = element.tags
  if tags.action == "item-request" and port_type == "item" then
    set_item_request(port, tags.index, element.elem_value)
    refresh_gui(player)
  elseif tags.action == "fluid-request" and port_type == "fluid" then
    set_fluid_request(port, element.elem_value)
    refresh_gui(player)
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  ensure_storage()
  local element = event.element
  if not (element and element.valid and element.tags and element.tags.action == "search") then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local state = player_state(player.index)
  state.search = element.text
  refresh_storage_list(player, true)
end)

script.on_event(defines.events.on_string_translated, function(event)
  ensure_storage()
  local player = game.get_player(event.player_index)
  if not player then return end
  local state = player_state(player.index)
  local pending = state.pending_translations[event.id]
  if not pending then return end
  state.pending_translations[event.id] = nil
  if event.translated then
    translation_cache_for(state, pending.kind)[pending.name] = string.lower(event.result or "")
    if state.search ~= "" then
      state.storage_gui.dirty = true
    end
  end
end)

script.on_event(defines.events.on_player_locale_changed, function(event)
  ensure_storage()
  local state = player_state(event.player_index)
  state.translations = {items = {}, fluids = {}}
  state.pending_translations = {}
  local player = game.get_player(event.player_index)
  if player then
    state.storage_gui = {signature = "", dirty = true}
  end
end)
