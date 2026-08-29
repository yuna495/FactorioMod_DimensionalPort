local names = require("prototypes.names")

local UPDATE_INTERVAL = 30
local MAX_ITEM_REQUESTS = 9
local REQUEST_STACKS = 5
local FLUID_PORT_CAPACITY = 25000
local DEFAULT_MODE = "supply"
local NORMAL_QUALITY = "normal"
local TRANSLATION_KIND_ITEM = "item"
local TRANSLATION_KIND_FLUID = "fluid"

local function ensure_storage()
  storage.dimensional_storage = storage.dimensional_storage or {items = {}, fluids = {}}
  storage.dimensional_storage.items = storage.dimensional_storage.items or {}
  storage.dimensional_storage.fluids = storage.dimensional_storage.fluids or {}
  storage.item_ports = storage.item_ports or {}
  storage.fluid_ports = storage.fluid_ports or {}
  storage.players = storage.players or {}
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
    for _, request in ipairs(port.requests or {}) do
      for _ = 1, REQUEST_STACKS do
        if slot <= #inventory then
          inventory.set_filter(slot, {name = request.name, quality = quality_name(request.quality)})
          slot = slot + 1
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
  for _, request in ipairs(port.requests or {}) do
    requested[item_key(request.name, request.quality)] = true
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

local function register_item_port(entity)
  if not (entity and entity.valid) then return end
  storage.item_ports[entity.unit_number] = {
    entity = entity,
    mode = DEFAULT_MODE,
    requests = {},
    materialized = {}
  }
end

local function register_fluid_port(entity)
  if not (entity and entity.valid) then return end
  storage.fluid_ports[entity.unit_number] = {
    entity = entity,
    mode = DEFAULT_MODE,
    request = nil
  }
end

local function unregister_item_port(entity)
  if not (entity and entity.valid) then return end
  local port = storage.item_ports[entity.unit_number]
  if not port then return end
  if port.mode == "request" then
    absorb_inventory_to_storage(entity)
  end
  storage.item_ports[entity.unit_number] = nil
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
  storage.fluid_ports[entity.unit_number] = nil
end

local function rebuild_ports()
  storage.item_ports = {}
  storage.fluid_ports = {}
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = names.item_port_entity}) do
      register_item_port(entity)
    end
    for _, entity in pairs(surface.find_entities_filtered{name = names.fluid_port_entity}) do
      register_fluid_port(entity)
    end
  end
end

local function on_entity_created(entity)
  ensure_storage()
  if not (entity and entity.valid) then return end
  if entity.name == names.item_port_entity then
    register_item_port(entity)
  elseif entity.name == names.fluid_port_entity then
    register_fluid_port(entity)
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

local function distribute_amount(total, requests)
  local active = {}
  for _, request in ipairs(requests) do
    if request.missing > 0 then
      active[#active + 1] = request
    end
  end
  local remaining = total
  while remaining > 0 and #active > 0 do
    local share = math.max(1, math.floor(remaining / #active))
    local next_active = {}
    local changed = false
    for _, request in ipairs(active) do
      if remaining <= 0 then break end
      local amount = math.min(request.missing - request.assigned, share, remaining)
      if amount > 0 then
        request.assigned = request.assigned + amount
        remaining = remaining - amount
        changed = true
      end
      if request.assigned < request.missing then
        next_active[#next_active + 1] = request
      end
    end
    if not changed then break end
    active = next_active
  end
end

local function process_item_ports()
  for unit_number, port in pairs(storage.item_ports) do
    if not (port.entity and port.entity.valid) then
      storage.item_ports[unit_number] = nil
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
        for _, request in ipairs(port.requests or {}) do
          local target = target_count_for_request(request)
          local current = inventory_count(inventory, request.name, request.quality)
          local missing = target - current
          if missing > 0 then
            local key = item_key(request.name, request.quality)
            grouped[key] = grouped[key] or {}
            grouped[key][#grouped[key] + 1] = {
              port = port,
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

  for key, requests in pairs(grouped) do
    distribute_amount(storage.dimensional_storage.items[key] or 0, requests)
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

local function process_fluid_ports()
  for unit_number, port in pairs(storage.fluid_ports) do
    if not (port.entity and port.entity.valid) then
      storage.fluid_ports[unit_number] = nil
    elseif port.mode == "supply" then
      local fluid = port.entity.fluidbox and port.entity.fluidbox[1]
      if fluid_is_temperature_safe(fluid) then
        add_fluid_to_storage(fluid.name, fluid.amount)
        port.entity.fluidbox[1] = nil
      end
    end
  end

  local grouped = {}
  for _, port in pairs(storage.fluid_ports) do
    if port.entity and port.entity.valid and port.mode == "request" and port.request then
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
          name = port.request,
          missing = missing,
          assigned = 0
        }
      end
    end
  end

  for key, requests in pairs(grouped) do
    distribute_amount(storage.dimensional_storage.fluids[key] or 0, requests)
    for _, request in ipairs(requests) do
      if request.assigned > 0 then
        local removed = remove_fluid_from_storage(request.name, request.assigned)
        local inserted = request.port.entity.insert_fluid{name = request.name, amount = removed}
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
    local request = port.requests[index]
    request_table.add{
      type = "choose-elem-button",
      elem_type = "signal",
      style = "slot_button",
      signal = request and {type = "item", name = request.name, quality = quality_name(request.quality)} or nil,
      tags = {action = "item-request", index = index}
    }
  end
end

local function add_fluid_request(parent, port)
  local request_frame = parent.add{type = "frame", direction = "vertical", caption = {"dimensional-port.request-fluid"}}
  request_frame.add{
    type = "choose-elem-button",
    elem_type = "fluid",
    fluid = port.request,
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

local function add_storage_table(parent, player, search)
  local state = player_state(player.index)
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
  for key, count in pairs(displayed_item_counts()) do
    local name, quality = split_item_key(key)
    local prototype = prototypes.item[name]
    local local_name = prototype and prototype.localised_name or name
    request_localised_name(player, TRANSLATION_KIND_ITEM, name, local_name)
    if count > 0 and matches_search(state, TRANSLATION_KIND_ITEM, name, quality, search) then
      local tooltip = {"dimensional-port.item-tooltip", local_name, quality, count}
      local icon = table_element.add{
        type = "sprite-button",
        sprite = "item/" .. name,
        number = count,
        tooltip = tooltip
      }
      if quality_name(quality) ~= NORMAL_QUALITY then
        icon.quality = quality_name(quality)
      end
    end
  end
  for name, amount in pairs(storage.dimensional_storage.fluids) do
    local prototype = prototypes.fluid[name]
    local local_name = prototype and prototype.localised_name or name
    request_localised_name(player, TRANSLATION_KIND_FLUID, name, local_name)
    if amount > 0 and matches_search(state, TRANSLATION_KIND_FLUID, name, nil, search) then
      local tooltip = {"dimensional-port.fluid-tooltip", local_name, amount}
      table_element.add{
        type = "sprite-button",
        sprite = "fluid/" .. name,
        number = amount,
        tooltip = tooltip
      }
    end
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

local function refresh_storage_list(player)
  local frame = player.gui.screen.dimensional_port_frame
  if not frame then return end
  local storage_frame = frame.dimensional_port_storage_frame
  if not storage_frame then return end
  local old_scroll = storage_frame.dimensional_port_storage_scroll
  if old_scroll then old_scroll.destroy() end
  local state = player_state(player.index)
  add_storage_table(storage_frame, player, state.search)
end

local function build_gui(player, port, port_type)
  destroy_gui(player)
  local state = player_state(player.index)
  state.port_type = port_type
  state.unit_number = port.entity.unit_number
  state.search = state.search or ""

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
end

local function set_fluid_port_mode(port, mode)
  if port.mode == mode then return end
  local fluid = port.entity.fluidbox and port.entity.fluidbox[1]
  if fluid and fluid_is_temperature_safe(fluid) then
    add_fluid_to_storage(fluid.name, fluid.amount)
    port.entity.fluidbox[1] = nil
  end
  port.mode = mode
  if mode == "supply" then
    port.request = nil
  end
end

local function normalize_item_request(selection)
  if type(selection) == "table" and selection.name and (selection.type == nil or selection.type == "item") then
    return selection.name, quality_name(selection.quality)
  elseif type(selection) == "string" then
    return selection, NORMAL_QUALITY
  end
  return nil, nil
end

local function set_item_request(port, index, selection)
  port.materialized = port.materialized or {}
  local old = port.requests[index]
  if old then
    local inventory = get_main_inventory(port.entity)
    if inventory then
      local count = inventory_count(inventory, old.name, old.quality)
      if count > 0 then
        local removed = inventory.remove(stack_definition(old.name, old.quality, count))
        add_item_to_storage(old.name, old.quality, removed)
      end
    end
    port.materialized[item_key(old.name, old.quality)] = nil
  end
  local name, quality = normalize_item_request(selection)
  if name then
    for other_index, request in pairs(port.requests) do
      if other_index ~= index and request.name == name and quality_name(request.quality) == quality_name(quality) then
        set_item_request(port, other_index, nil)
      end
    end
    port.requests[index] = {name = name, quality = quality}
  else
    port.requests[index] = nil
  end
  apply_request_filters(port)
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
    refresh_storage_list(player)
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
    port.request = element.elem_value
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
  refresh_storage_list(player)
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
    refresh_storage_list(player)
  end
end)

script.on_event(defines.events.on_player_locale_changed, function(event)
  ensure_storage()
  local state = player_state(event.player_index)
  state.translations = {items = {}, fluids = {}}
  state.pending_translations = {}
  local player = game.get_player(event.player_index)
  if player then refresh_storage_list(player) end
end)
