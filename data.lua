local names = require("prototypes.names")

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

local item_port = table.deepcopy(data.raw.container["steel-chest"])
item_port.name = names.item_port_entity
item_port.localised_name = {"entity-name.dimensional-item-port"}
item_port.localised_description = {"entity-description.dimensional-item-port"}
item_port.minable = {mining_time = 0.2, result = names.item_port_item}
item_port.icons = {
  {icon = "__base__/graphics/icons/steel-chest.png", tint = {r = 1, g = 0.25, b = 0.25, a = 1}}
}
item_port.icon = nil
item_port.circuit_connector = nil
item_port.circuit_wire_max_distance = nil
tint_sprite(item_port.picture, {r = 1, g = 0.25, b = 0.25, a = 1})

local fluid_port = table.deepcopy(data.raw.pipe["pipe"])
fluid_port.name = names.fluid_port_entity
fluid_port.localised_name = {"entity-name.dimensional-fluid-port"}
fluid_port.localised_description = {"entity-description.dimensional-fluid-port"}
fluid_port.minable = {mining_time = 0.1, result = names.fluid_port_item}
fluid_port.icons = {
  {icon = "__base__/graphics/icons/pipe.png", tint = {r = 1, g = 0.25, b = 0.25, a = 1}}
}
fluid_port.icon = nil
fluid_port.fluid_box.volume = 25000
tint_sprite(fluid_port.pictures, {r = 1, g = 0.25, b = 0.25, a = 1})

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
