local names = require("prototypes.names")

local item_port_icon = "__DimensionalPort__/graphics/icons/dimensional-item-port.png"
local fluid_port_icon = "__DimensionalPort__/graphics/icons/dimensional-fluid-port.png"
local combinator_icon = "__base__/graphics/icons/constant-combinator.png"
local item_port_base = "__DimensionalPort__/graphics/entity/dimensional-port-base.png"
local item_port_foreground = "__DimensionalPort__/graphics/entity/dimensional-port-foreground.png"
local item_port_shadow = "__DimensionalPort__/graphics/entity/dimensional-port-shadow.png"
local fluid_port_base = "__DimensionalPort__/graphics/entity/dimensional-fluid-port-base.png"
local fluid_port_foreground = "__DimensionalPort__/graphics/entity/dimensional-fluid-port-foreground.png"
local fluid_port_shadow = "__DimensionalPort__/graphics/entity/dimensional-port-shadow.png"
local vortex_animation = "__DimensionalPort__/graphics/entity/vortex.png"

local combinator_tint = {r = 0.72, g = 0.32, b = 1.0, a = 1.0}

local function tint_sprite_definition(sprite)
  if type(sprite) ~= "table" then return end

  if sprite.layers then
    for _, layer in pairs(sprite.layers) do
      tint_sprite_definition(layer)
    end
  end

  if sprite.sheets then
    for _, sheet in pairs(sprite.sheets) do
      tint_sprite_definition(sheet)
    end
  end

  for _, direction in pairs({"north", "east", "south", "west"}) do
    tint_sprite_definition(sprite[direction])
  end

  if sprite.hr_version then
    tint_sprite_definition(sprite.hr_version)
  end

  if sprite.filename and not sprite.draw_as_shadow then
    sprite.tint = combinator_tint
  end
end


local function port_sprite(filename)
  return {
    filename = filename,
    priority = "extra-high",
    width = 128,
    height = 135,
    shift = util.by_pixel(0, -2),
    scale = 0.3
  }
end

local function fluid_port_shadow_sprite()
  return {
    filename = fluid_port_shadow,
    priority = "extra-high",
    width = 110,
    height = 50,
    shift = util.by_pixel(16, 6),
    draw_as_shadow = true,
    scale = 0.55
  }
end

local function vortex_visualisation()
  return {
    {
      count = 1,
      render_layer = "object",
      animation = {
        layers = {
          {
            filename = item_port_foreground,
            priority = "extra-high",
            width = 128,
            height = 135,
            repeat_count = 14,
            animation_speed = 0.125,
            shift = util.by_pixel(0, -2),
            scale = 0.3
          },
          {
            filename = vortex_animation,
            priority = "extra-high",
            width = 128,
            height = 128,
            frame_count = 14,
            line_length = 4,
            shift = {0, -0.37},
            scale = 0.145
          }
        }
      }
    }
  }
end

local function item_port_picture()
  return {
    layers = {
      fluid_port_shadow_sprite(),
      port_sprite(item_port_base),
      port_sprite(item_port_foreground)
    }
  }
end

local function fluid_vortex_visualisation()
  local visualisation = vortex_visualisation()
  visualisation[1].animation.layers[1].filename = fluid_port_foreground
  return visualisation
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
item_port.picture = item_port_picture()
item_port.stateless_visualisation = vortex_visualisation()
item_port.draw_stateless_visualisation_under_building = false
item_port.draw_stateless_visualisations_in_ghost = true

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

local function fluid_port_picture()
  return {
    layers = {
      fluid_port_shadow_sprite(),
      port_sprite(fluid_port_base),
      port_sprite(fluid_port_foreground)
    }
  }
end

fluid_port.pictures = {
  straight_vertical_single = fluid_port_picture(),
  straight_vertical = fluid_port_picture(),
  straight_vertical_window = fluid_port_picture(),
  straight_horizontal_window = fluid_port_picture(),
  straight_horizontal = fluid_port_picture(),

  corner_up_right = fluid_port_picture(),
  corner_up_left = fluid_port_picture(),
  corner_down_right = fluid_port_picture(),
  corner_down_left = fluid_port_picture(),

  t_up = fluid_port_picture(),
  t_down = fluid_port_picture(),
  t_right = fluid_port_picture(),
  t_left = fluid_port_picture(),

  cross = fluid_port_picture(),

  ending_up = fluid_port_picture(),
  ending_down = fluid_port_picture(),
  ending_right = fluid_port_picture(),
  ending_left = fluid_port_picture()
}
fluid_port.stateless_visualisation = fluid_vortex_visualisation()
fluid_port.draw_stateless_visualisation_under_building = false
fluid_port.draw_stateless_visualisations_in_ghost = true

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

local combinator = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
combinator.name = names.combinator_entity
combinator.localised_name = {"entity-name.dimensional-combinator"}
combinator.localised_description = {"entity-description.dimensional-combinator"}
combinator.minable = {mining_time = 0.1, result = names.combinator_item}
combinator.icons = {
  {icon = combinator_icon, icon_size = 64, tint = combinator_tint}
}
combinator.icon = nil
if combinator.sprites then tint_sprite_definition(combinator.sprites) end
if combinator.activity_led_sprites then tint_sprite_definition(combinator.activity_led_sprites) end

local combinator_item = table.deepcopy(data.raw.item["constant-combinator"])
combinator_item.name = names.combinator_item
combinator_item.localised_name = {"item-name.dimensional-combinator"}
combinator_item.localised_description = {"item-description.dimensional-combinator"}
combinator_item.icons = combinator.icons
combinator_item.icon = nil
combinator_item.place_result = names.combinator_entity
combinator_item.order = "b[combinators]-d[dimensional-combinator]"

data:extend({
  item_port,
  fluid_port,
  combinator,
  item_port_item,
  fluid_port_item,
  combinator_item,
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
  },
  {
    type = "recipe",
    name = names.combinator_recipe,
    enabled = true,
    ingredients = {{type = "item", name = "iron-plate", amount = 1}},
    results = {{type = "item", name = names.combinator_item, amount = 1}}
  }
})
