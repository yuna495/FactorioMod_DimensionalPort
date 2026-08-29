local names = require("prototypes.names")

local UPDATE_INTERVAL = 30
local MAX_ITEM_REQUESTS = 9
local REQUEST_STACKS = 5
local FLUID_PORT_CAPACITY = 25000
local DEFAULT_MODE = "supply"
local NORMAL_QUALITY = "normal"
local TRANSLATION_KIND_ITEM = "item"
local TRANSLATION_KIND_FLUID = "fluid"
local STORAGE_ENTRY_PREFIX = "dimensional_port_storage_entry_"
local STORAGE_SIGNATURE_SEPARATOR = "\31"

local function ensure_storage()
  storage.dimensional_storage = storage.dimensional_storage or {items = {}, fluids = {}}
  storage.dimensional_storage.items = storage.dimensional_storage.items or {}
  storage.dimensional_storage.fluids = storage.dimensional_storage.fluids or {}
  storage.item_ports = storage.item_ports or {}
  storage.fluid_ports = storage.fluid_ports or {}
  storage.players = storage.players or {}
  storage.destroy_registrations = storage.destroy_registrations or {}
  storage.distribution_offsets = storage.distribution_offsets or {items = {}, fluids = {}}
  storage.distribution_offsets.items = storage.distribution_offsets.items or {}
  storage.distribution_offsets.fluids = storage.distribution_offsets.fluids or {}
end

local function quality_name(quality)
  if type(quality) == "table" then
    return quality.name or NORMAL_QUALITY
  end
  return quality or NORMAL_QUALITY
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

local function add_fluid_to_storage(name, amount)
  if amount <= 0 then return end
  local key = fluid_key(name)
  storage.dimensional_storage.fluids[key] = (storage.dimensional_storage.fluids[key] or 0) + amount
end

local function remove_fluid_from_storage(name, amount)
  local key = fluid_key(name)
  local available = storage.dimensional_storage.fluids[key] or 0
  local removed = math.min(available, amount)
  if removed <= 0 then return 0 end
  local remaining = available - removed
  storage.dimensional_storage.fluids[key] = remaining > 0 and remaining or nil
  return removed
end

local function fluid_is_temperature_safe(fluid)
  if not (fluid and fluid.name and fluid.amount and fluid.amount > 0) then return false end
  if fluid.temperature == nil then return true end
  local prototype = prototypes.fluid[fluid.name]
  local default_temperature = prototype and prototype.default_temperature
  return default_temperature ~= nil and math.abs(fluid.temperature - default_temperature) < 0.001
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
  if port.mode ~= "request" then return end

  if inventory.supports_filters and inventory.supports_filters() then
    local slot = 1
    for index = 1, MAX_ITEM_REQUESTS do
      local request = port.requests and port.requests[index]
      if item_request_is_available(request) then
        for _ = 1, REQUEST_STACKS do
          if slot <= #inventory then
            inventory.set_filter(slot, {name = request.name, quality = quality_name(request.quality)})
            slot = slot + 1
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

local function return_unrequested_items(port)
  local inventory = get_main_inventory(port.entity)
  if not inventory then return end
  port.materialized = port.materialized or {}
  local requested = {}
  for index = 1, MAX_ITEM_REQUESTS do
    local request = port.requests and port.requests[index]
    if item_request_is_available(request) then
      requested[item_key(request.name, request.quality)] = true
    end
  end
  local contents = inventory.get_contents()
  local actual_counts = {}
  for _, stack in pairs(contents) do
    local quality = quality_name(stack.quality)
    local key = item_key(stack.name, quality)
    actual_counts[key] = stack.count
    if not requested[key] then
      local removed = inventory.remove(stack_definition(stack.name, quality, stack.count))
      add_item_to_storage(stack.name, quality, removed)
      port.materialized[key] = nil
    else
      local materialized = port.materialized[key] or 0
      if stack.count > materialized then
        local excess = stack.count - materialized
        local removed = inventory.remove(stack_definition(stack.name, quality, excess))
        add_item_to_storage(stack.name, quality, removed)
      elseif stack.count < materialized then
        port.materialized[key] = stack.count > 0 and stack.count or nil
      end
    end
  end
  for key in pairs(port.materialized) do
    if not actual_counts[key] then
      port.materialized[key] = nil
    end
  end
end

local function target_count_for_request(request)
  local prototype = prototypes.item[request.name]
  if not prototype then return 0 end
  return prototype.stack_size * REQUEST_STACKS
end

local function normalise_fluid_materialized(materialized, request)
  if type(materialized) == "table" then
    materialized.amount = materialized.amount or 0
    materialized.name = materialized.name or request
    return materialized
  elseif type(materialized) == "number" then
    return {name = request, amount = materialized}
  end
  return {name = request, amount = 0}
end

local function normalise_item_port_state(port, entity)
  port = port or {}
  port.entity = entity
  port.mode = port.mode or DEFAULT_MODE
  port.requests = port.requests or {}
  port.materialized = port.materialized or {}
  return port
end

local function normalise_fluid_port_state(port, entity)
  port = port or {}
  port.entity = entity
  port.mode = port.mode or DEFAULT_MODE
  port.materialized = normalise_fluid_materialized(port.materialized, port.request)
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

local function return_materialized_fluid_to_storage(port)
  port.materialized = normalise_fluid_materialized(port.materialized, port.request)
  if port.materialized.name and port.materialized.amount and port.materialized.amount > 0 then
    add_fluid_to_storage(port.materialized.name, port.materialized.amount)
  end
  port.materialized = {name = port.request, amount = 0}
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
end

local function unregister_item_port(entity)
  if not (entity and entity.valid) then return end
  local port = storage.item_ports[entity.unit_number]
  if not port then return end
  local affected_keys = item_port_request_keys and item_port_request_keys(port) or {}
  if port.mode == "request" then
    absorb_inventory_to_storage(entity)
  end
  clear_destroy_registration(port)
  storage.item_ports[entity.unit_number] = nil
  if port.mode == "request" then
    rebalance_item_request_keys(affected_keys)
  end
end

local function unregister_fluid_port(entity)
  if not (entity and entity.valid) then return end
  local port = storage.fluid_ports[entity.unit_number]
  if not port then return end
  if port.mode == "request" then
    local fluid = entity.fluidbox and entity.fluidbox[1]
    if fluid_is_temperature_safe(fluid) then
      add_fluid_to_storage(fluid.name, fluid.amount)
      entity.fluidbox[1] = nil
    end
  end
  clear_destroy_registration(port)
  storage.fluid_ports[entity.unit_number] = nil
end

local function unregister_lost_item_port(unit_number, port)
  local affected_keys = item_port_request_keys and item_port_request_keys(port) or {}
  if port.mode == "request" then
    return_materialized_items_to_storage(port)
  end
  clear_destroy_registration(port)
  storage.item_ports[unit_number] = nil
  if port.mode == "request" then
    rebalance_item_request_keys(affected_keys)
  end
end

local function unregister_lost_fluid_port(unit_number, port)
  if port.mode == "request" then
    return_materialized_fluid_to_storage(port)
  end
  clear_destroy_registration(port)
  storage.fluid_ports[unit_number] = nil
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

local function draw_vortex(entity)
  rendering.draw_animation{
    animation = "dimensional-port-vortex",
    target = {
      entity = entity,
      offset = {0, -0.37}
    },
    surface = entity.surface,
    x_scale = 0.14,
    y_scale = 0.15
  }
end

local function on_entity_created(entity)
  ensure_storage()
  if not (entity and entity.valid) then return end
  if entity.name == names.item_port_entity then
    register_item_port(entity)
    draw_vortex(entity)
  elseif entity.name == names.fluid_port_entity then
    register_fluid_port(entity)
    draw_vortex(entity)
  end
end

local function on_entity_removed(entity)
  ensure_storage()
  if not (entity and entity.valid) then return end
  if entity.name == names.item_port_entity then
    unregister_item_port(entity)
  elseif entity.name == names.fluid_port_entity then
    unregister_fluid_port(entity)
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
      if port.mode == "request" then
        return_materialized_items_to_storage(port)
      end
      storage.item_ports[registration.unit_number] = nil
      if port.mode == "request" then
        rebalance_item_request_keys(affected_keys)
      end
    end
  elseif registration.port_type == "fluid" then
    local port = storage.fluid_ports[registration.unit_number]
    if port then
      if port.mode == "request" then
        return_materialized_fluid_to_storage(port)
      end
      storage.fluid_ports[registration.unit_number] = nil
    end
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

  local actual = inventory_count(inventory, name, quality)
  if actual < materialized then
    materialized = actual
    port.materialized[key] = materialized > 0 and materialized or nil
  end
  return materialized
end

local function collect_item_rebalance_requesters(key)
  local name, quality = split_item_key(key)
  if not (prototypes.item[name] and quality_is_available(quality)) then return {} end

  local requesters = {}
  for _, port in pairs(storage.item_ports) do
    if port.entity and port.entity.valid and port.mode == "request" and item_port_requests_key(port, key) then
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
      local removed = requester.inventory.remove(stack_definition(requester.name, requester.quality, excess))
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
        local inserted = requester.inventory.insert(stack_definition(requester.name, requester.quality, removed))
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
    elseif port.mode == "supply" then
      absorb_inventory_to_storage(port.entity)
    elseif port.mode == "request" then
      return_unrequested_items(port)
    end
  end

  local grouped = {}
  for _, port in pairs(storage.item_ports) do
    if port.entity and port.entity.valid and port.mode == "request" then
      local inventory = get_main_inventory(port.entity)
      if inventory then
        for index = 1, MAX_ITEM_REQUESTS do
          local request = port.requests and port.requests[index]
          if item_request_is_available(request) then
            local target = target_count_for_request(request)
            local current = inventory_count(inventory, request.name, request.quality)
            local missing = target - current
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
          local inserted = inventory.insert(stack_definition(request.name, request.quality, removed))
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

local function set_fluidbox_content(entity, name, amount)
  if amount and amount > 0 then
    entity.fluidbox[1] = {name = name, amount = amount}
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
    return true
  end
  if not fluid_is_temperature_safe(fluid) then return false end
  add_fluid_to_storage(fluid.name, fluid.amount)
  port.entity.fluidbox[1] = nil
  port.materialized = {name = port.request, amount = 0}
  return true
end

local function return_unrequested_fluid(port)
  if not (port.entity and port.entity.valid and port.entity.fluidbox) then return end
  port.materialized = normalise_fluid_materialized(port.materialized, port.request)
  local fluid = port.entity.fluidbox[1]
  if not (fluid and fluid.name and fluid.amount and fluid.amount > 0) then
    port.materialized.amount = 0
    port.materialized.name = port.request
    return
  end
  if not fluid_is_temperature_safe(fluid) then return end

  if port.mode ~= "request" or fluid.name ~= port.request then
    add_fluid_to_storage(fluid.name, fluid.amount)
    port.entity.fluidbox[1] = nil
    port.materialized = {name = port.request, amount = 0}
    return
  end

  if port.materialized.name ~= fluid.name then
    port.materialized = {name = fluid.name, amount = 0}
  end

  if fluid.amount > port.materialized.amount then
    local excess = fluid.amount - port.materialized.amount
    add_fluid_to_storage(fluid.name, excess)
    set_fluidbox_content(port.entity, fluid.name, port.materialized.amount)
  elseif fluid.amount < port.materialized.amount then
    port.materialized.amount = fluid.amount
  end
end

local function process_fluid_ports()
  for unit_number, port in pairs(storage.fluid_ports) do
    if not (port.entity and port.entity.valid) then
      unregister_lost_fluid_port(unit_number, port)
    elseif port.mode == "supply" then
      local fluid = port.entity.fluidbox and port.entity.fluidbox[1]
      if fluid_is_temperature_safe(fluid) then
        add_fluid_to_storage(fluid.name, fluid.amount)
        port.entity.fluidbox[1] = nil
      end
    elseif port.mode == "request" then
      return_unrequested_fluid(port)
    end
  end

  local grouped = {}
  for _, port in pairs(storage.fluid_ports) do
    if port.entity and port.entity.valid and port.mode == "request" and fluid_is_available(port.request) then
      local fluid = port.entity.fluidbox and port.entity.fluidbox[1]
      local current = 0
      if fluid and fluid.name == port.request and fluid_is_temperature_safe(fluid) then
        current = fluid.amount
      elseif fluid and fluid.amount and fluid.amount > 0 then
        current = FLUID_PORT_CAPACITY
      end
      local missing = FLUID_PORT_CAPACITY - current
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
    distribute_fluid_amount(storage.dimensional_storage.fluids[key] or 0, requests)
    for _, request in ipairs(requests) do
      if request.assigned > 0 then
        local removed = remove_fluid_from_storage(request.name, request.assigned)
        local inserted = request.port.entity.insert_fluid{name = request.name, amount = removed}
        if inserted > 0 then
          request.port.materialized = normalise_fluid_materialized(request.port.materialized, request.name)
          request.port.materialized.name = request.name
          request.port.materialized.amount = request.port.materialized.amount + inserted
        end
        if inserted < removed then
          add_fluid_to_storage(request.name, removed - inserted)
        end
      end
    end
  end
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
    storage.players[player.index].storage_gui = {signature = "", dirty = true}
  end
end

local function add_mode_buttons(parent, port)
  local flow = parent.add{type = "flow", direction = "horizontal"}
  flow.add{
    type = "button",
    name = "dimensional_port_supply_mode",
    caption = {"dimensional-port.mode-supply"},
    tags = {action = "mode", mode = "supply"}
  }
  flow.add{
    type = "button",
    name = "dimensional_port_request_mode",
    caption = {"dimensional-port.mode-request"},
    tags = {action = "mode", mode = "request"}
  }
  flow.add{type = "label", caption = {"dimensional-port.current-mode", {"dimensional-port.mode-" .. port.mode}}}
end

local function add_item_requests(parent, port)
  local request_frame = parent.add{type = "frame", direction = "vertical", caption = {"dimensional-port.request-items"}}
  local request_table = request_frame.add{type = "table", column_count = 9}
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

  for name, amount in pairs(storage.dimensional_storage.fluids) do
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
            tooltip = {"dimensional-port.fluid-tooltip", local_name, amount},
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

local function add_storage_entry(parent, entry, index)
  local icon = parent.add{
    type = "sprite-button",
    name = storage_entry_element_name(index),
    sprite = entry.sprite,
    number = entry.amount,
    tooltip = entry.tooltip,
    style = "slot_button"
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
    column_count = 9
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
  add_mode_buttons(frame, port)
  if port.mode == "request" then
    if port_type == "item" then
      add_item_requests(frame, port)
    else
      add_fluid_request(frame, port)
    end
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

local function set_item_port_mode(port, mode)
  if port.mode == mode then return end
  local affected_keys = port.mode == "request" and item_port_request_keys(port) or {}
  absorb_inventory_to_storage(port.entity)
  port.mode = mode
  if mode == "supply" then
    port.requests = {}
    port.materialized = {}
  else
    port.requests = port.requests or {}
    port.materialized = port.materialized or {}
  end
  apply_request_filters(port)
  if mode == "supply" then
    rebalance_item_request_keys(affected_keys)
  end
end

local function set_fluid_port_mode(port, mode)
  if port.mode == mode then return end
  if not return_fluidbox_to_storage(port) then return end
  port.mode = mode
  if mode == "supply" then
    port.request = nil
    port.materialized = {name = nil, amount = 0}
  else
    port.materialized = {name = port.request, amount = 0}
  end
end

local function set_fluid_request(port, selection)
  local new_request = fluid_is_available(selection) and selection or nil
  if port.request == new_request then return end
  if not return_fluidbox_to_storage(port) then return end
  port.request = new_request
  port.materialized = {name = new_request, amount = 0}
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
    if item_request_is_available(old) then
      local inventory = get_main_inventory(port.entity)
      if inventory then
        local count = inventory_count(inventory, old.name, old.quality)
        if count > 0 then
          local removed = inventory.remove(stack_definition(old.name, old.quality, count))
          add_item_to_storage(old.name, old.quality, removed)
        end
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

script.on_init(function()
  ensure_storage()
  rebuild_ports()
end)

script.on_configuration_changed(function()
  ensure_storage()
  rebuild_ports()
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

script.on_nth_tick(UPDATE_INTERVAL, function()
  ensure_storage()
  process_item_ports()
  process_fluid_ports()
  for _, player in pairs(game.connected_players) do
    refresh_storage_list(player)
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
  if tags.action == "mode" then
    if port_type == "item" then
      set_item_port_mode(port, tags.mode)
    else
      set_fluid_port_mode(port, tags.mode)
    end
    refresh_gui(player)
  elseif tags.action == "clear-search" then
    local state = player_state(player.index)
    state.search = ""
    local search = element.parent and element.parent.valid and element.parent.dimensional_port_search
    if search then search.text = "" end
    refresh_storage_list(player, true)
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
