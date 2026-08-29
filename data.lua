local names = require("prototypes.names")

local item_port_icon = "__DimensionalPort__/graphics/icons/dimensional-item-port.png"
local fluid_port_icon = "__DimensionalPort__/graphics/icons/dimensional-fluid-port.png"
local item_port_picture = "__DimensionalPort__/graphics/entity/dimensional-item-port/dimensional-item-port.png"
local item_port_shadow = "__DimensionalPort__/graphics/entity/dimensional-item-port/dimensional-item-port-shadow.png"
local fluid_port_overlay = "__DimensionalPort__/graphics/entity/dimensional-fluid-port/dimensional-fluid-port-overlay.png"
local fluid_port_shadow = "__DimensionalPort__/graphics/entity/dimensional-fluid-port/dimensional-fluid-port-shadow.png"

local function tint_sprite(sprite, tint)
  if type(sprite) ~= "table" then return end
  if sprite.filename and not sprite.draw_as_shadow then
    sprite.tint = tint
  end
  for _, value in pairs(sprite) do
    if type(value) == "table" then
      tint_sprite(value, tint)
    end
  end
end

local function fluid_port_overlay_sprite()
  return {
    filename = fluid_port_overlay,
    priority = "extra-high",
    width = 128,
    height = 128,
    shift = util.by_pixel(0, 8),
    scale = 0.28
  }
end

local function fluid_port_shadow_sprite()
  return {
    filename = fluid_port_shadow,
    priority = "extra-high",
    width = 128,
    height = 128,
    shift = util.by_pixel(2, 6),
    draw_as_shadow = true,
    scale = 0.42
  }
end

local function overlay_pipe_sprite(sprite)
  if type(sprite) ~= "table" then return sprite end

  local copy = table.deepcopy(sprite)
  if copy.layers then
    copy.layers[#copy.layers + 1] = fluid_port_shadow_sprite()
    copy.layers[#copy.layers + 1] = fluid_port_overlay_sprite()
    return copy
  end

  return {
    layers = {
      copy,
      fluid_port_shadow_sprite(),
      fluid_port_overlay_sprite()
    }
  }
end

local function overlay_pipe_pictures(pictures)
  local keys = {
    "straight_vertical_single",
    "straight_vertical",
    "straight_vertical_window",
    "straight_horizontal_window",
    "straight_horizontal",
    "corner_up_right",
    "corner_up_left",
    "corner_down_right",
    "corner_down_left",
    "t_up",
    "t_down",
    "t_right",
    "t_left",
    "cross",
    "ending_up",
    "ending_down",
    "ending_right",
    "ending_left"
  }

  for _, key in ipairs(keys) do
    if pictures[key] then
      pictures[key] = overlay_pipe_sprite(pictures[key])
    end
  end
end

local item_port = table.deepcopy(data.raw.container["steel-chest"])
item_port.name = names.item_port_entity
item_port.localised_name = {"entity-name.dimensional-item-port"}
item_port.localised_description = {"entity-description.dimensional-item-port"}
item_port.minable = {mining_time = 0.2, result = names.item_port_item}
item_port.icons = {
  {icon = item_port_icon, icon_size = 64}
}
item_port.icon = nil
item_port.inventory_type = "with_filters_and_bar"
item_port.circuit_connector = nil
item_port.circuit_wire_max_distance = nil
item_port.picture = {
  layers = {
    {
      filename = item_port_shadow,
      priority = "extra-high",
      width = 128,
      height = 128,
      shift = util.by_pixel(2, 6),
      draw_as_shadow = true,
      scale = 0.42
    },
    {
      filename = item_port_picture,
      priority = "extra-high",
      width = 128,
      height = 128,
      shift = util.by_pixel(0, 8),
      scale = 0.28
    }
  }
}

local fluid_port = table.deepcopy(data.raw.pipe["pipe"])
fluid_port.name = names.fluid_port_entity
fluid_port.localised_name = {"entity-name.dimensional-fluid-port"}
fluid_port.localised_description = {"entity-description.dimensional-fluid-port"}
fluid_port.minable = {mining_time = 0.1, result = names.fluid_port_item}
fluid_port.icons = {
  {icon = fluid_port_icon, icon_size = 64}
}
fluid_port.icon = nil
fluid_port.fluid_box.volume = 25000
tint_sprite(fluid_port.pictures, {r = 1, g = 0.25, b = 0.25, a = 1})
overlay_pipe_pictures(fluid_port.pictures)

local item_port_item = table.deepcopy(data.raw.item["steel-chest"])
item_port_item.name = names.item_port_item
item_port_item.localised_name = {"item-name.dimensional-item-port"}
item_port_item.localised_description = {"item-description.dimensional-item-port"}
item_port_item.icons = item_port.icons
item_port_item.icon = nil
item_port_item.place_result = names.item_port_entity
item_port_item.order = "a[items]-c[steel-chest]-d[dimensional-item-port]"

local fluid_port_item = table.deepcopy(data.raw.item["pipe"])
fluid_port_item.name = names.fluid_port_item
fluid_port_item.localised_name = {"item-name.dimensional-fluid-port"}
fluid_port_item.localised_description = {"item-description.dimensional-fluid-port"}
fluid_port_item.icons = fluid_port.icons
fluid_port_item.icon = nil
fluid_port_item.place_result = names.fluid_port_entity
fluid_port_item.order = "a[pipe]-a[pipe]-d[dimensional-fluid-port]"

data:extend({
  item_port,
  fluid_port,
  item_port_item,
  fluid_port_item,
  {
    type = "recipe",
    name = names.item_port_recipe,
    enabled = true,
    ingredients = {{type = "item", name = "iron-plate", amount = 5}},
    results = {{type = "item", name = names.item_port_item, amount = 1}}
  },
  {
    type = "recipe",
    name = names.fluid_port_recipe,
    enabled = true,
    ingredients = {{type = "item", name = "iron-plate", amount = 5}},
    results = {{type = "item", name = names.fluid_port_item, amount = 1}}
  }
})
