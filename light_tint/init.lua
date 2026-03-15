local modname = minetest.get_current_modname()
local S = minetest.settings

local function setting_raw(name)
	if S and S.get then
		return S:get(name)
	end
	if minetest.settings and minetest.settings.get then
		return minetest.settings:get(name)
	end
	if minetest.setting_get then
		return minetest.setting_get(name)
	end
	return nil
end

local function setting_bool(name, default)
	local v = setting_raw(name)
	if v == nil then
		return default
	end
	if type(v) == "boolean" then
		return v
	end
	if minetest.is_yes then
		return minetest.is_yes(v)
	end
	v = tostring(v):lower()
	return (v == "1" or v == "true" or v == "yes" or v == "on")
end

local function setting_number(name, default)
	local v = setting_raw(name)
	v = tonumber(v)
	if not v then
		return default
	end
	return v
end

local function setting_int(name, default)
	return math.floor(setting_number(name, default) + 0.5)
end

if not setting_bool("light_tint_enable", true) then
	minetest.log("action", "[light_tint] disabled by setting")
	return
end

local interval = setting_number("light_tint_interval", 0.7)
local scan_radius = setting_int("light_tint_scan_radius", 12)
local max_lights_per_player = setting_int("light_tint_max_lights_per_player", 24)
local max_tints_per_step = setting_int("light_tint_max_tints_per_step", 2600)
local tint_ttl = setting_number("light_tint_ttl", 1.5)
local max_effect_radius = setting_int("light_tint_max_effect_radius", 10)
local radius_bonus = setting_int("light_tint_radius_bonus", 0)
local tint_alpha = setting_int("light_tint_alpha", 38)
local max_registered_variants = setting_int("light_tint_max_registered_variants", 9000)
local include_furniture = setting_bool("light_tint_include_furniture", true)
local player_overlay_enabled = setting_bool("light_tint_player_overlay", true)
local player_overlay_max_alpha = setting_int("light_tint_player_overlay_max_alpha", 36)
local player_overlay_min_alpha = setting_int("light_tint_player_overlay_min_alpha", 8)
local only_exposed_nodes = setting_bool("light_tint_only_exposed_nodes", true)
local tint_any_node = setting_bool("light_tint_tint_any_node", true)

local COLOR_HEX = {
	red = "#ff6b6b",
	orange = "#ffb347",
	yellow = "#fff27a",
	green = "#82ff9e",
	blue = "#7ab8ff",
	cyan = "#7affff",
	purple = "#b39dff",
	pink = "#ff9ec9",
}

local COLOR_PATTERNS = {
	{"red", "red"},
	{"orange", "orange"},
	{"yellow", "yellow"},
	{"green", "green"},
	{"blue", "blue"},
	{"cyan", "cyan"},
	{"magenta", "purple"},
	{"violet", "purple"},
	{"purple", "purple"},
	{"pink", "pink"},
}

local OVERLAY_RGB = {
	red = {r = 145, g = 20, b = 20},
	orange = {r = 170, g = 95, b = 25},
	yellow = {r = 170, g = 160, b = 35},
	green = {r = 35, g = 140, b = 45},
	blue = {r = 35, g = 80, b = 150},
	cyan = {r = 35, g = 140, b = 150},
	purple = {r = 95, g = 55, b = 150},
	pink = {r = 160, g = 70, b = 120},
}

local function tint_modifier(color_hex)
	return "^[colorize:" .. color_hex .. ":" .. tint_alpha
end

local function pos_key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function copy_table(t)
	if minetest.table_copy then
		return minetest.table_copy(t)
	end
	local out = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			out[k] = copy_table(v)
		else
			out[k] = v
		end
	end
	return out
end

local function tint_tile(tile, color_hex)
	if type(tile) == "string" then
		return tile .. tint_modifier(color_hex)
	end
	if type(tile) == "table" then
		local out = copy_table(tile)
		if type(out.name) == "string" then
			out.name = out.name .. tint_modifier(color_hex)
		end
		return out
	end
	return tile
end

local function tint_tiles(tiles, color_hex)
	if type(tiles) ~= "table" then
		return tiles
	end
	local out = {}
	for i = 1, #tiles do
		out[i] = tint_tile(tiles[i], color_hex)
	end
	return out
end

local tinted_node_for = {}

local ALLOWED_DRAWTYPES = {
	normal = true,
	nodebox = true,
	glasslike = true,
	glasslike_framed = true,
	glasslike_framed_optional = true,
	allfaces_optional = true,
	allfaces = true,
}

local function is_natural_group_node(def)
	local g = def and def.groups or {}
	if (g.stone or 0) > 0 then return true end
	if (g.cracky or 0) > 0 then return true end
	if (g.crumbly or 0) > 0 then return true end
	if (g.snowy or 0) > 0 then return true end
	if (g.soil or 0) > 0 then return true end
	if (g.sand or 0) > 0 then return true end
	return false
end

local function stable_tinted_name(base_name, color_name)
	local safe = base_name:gsub("[^%w]", "_")
	if #safe > 40 then
		safe = safe:sub(1, 40)
	end
	return ":" .. modname .. ":tint_" .. color_name .. "_" .. safe
end

local is_tinted_node
local is_def_tintable

local function is_furniture_candidate(base_name, def)
	if not include_furniture then
		return false
	end
	local g = def and def.groups or {}
	if (g.wood or 0) <= 0 and (g.choppy or 0) <= 0 and (g.flammable or 0) <= 0 then
		return false
	end
	local lname = base_name:lower()
	if lname:find("chair", 1, true) or lname:find("sofa", 1, true) or lname:find("bench", 1, true)
		or lname:find("stool", 1, true) or lname:find("table", 1, true) then
		return true
	end
	return false
end

local function is_structural_candidate(base_name)
	local lname = base_name:lower()
	if lname:find("stair", 1, true) or lname:find("slab", 1, true) or lname:find("panel", 1, true)
		or lname:find("micro", 1, true) or lname:find("brick", 1, true) or lname:find("block", 1, true)
		or lname:find("plank", 1, true) or lname:find("wood", 1, true) or lname:find("stone", 1, true) then
		return true
	end
	return false
end

local function is_excluded_name(lname)
	if lname:find("fence", 1, true) or lname:find("gate", 1, true)
		or lname:find("door", 1, true) or lname:find("trapdoor", 1, true) or lname:find("rail", 1, true)
		or lname:find("torch", 1, true) or lname:find("lamp", 1, true) or lname:find("light", 1, true) then
		return true
	end
	return false
end

local function should_preregister_base_node(base_name, def)
	if not def or not is_def_tintable(def) then
		return false
	end
	if is_tinted_node(base_name) then
		return false
	end

	local lname = base_name:lower()
	local draw = def.drawtype or "normal"
	local modprefix = base_name:match("^([^:]+):") or ""
	local include_mod = (modprefix == "moreores" or modprefix == "moreblocks")

	if is_excluded_name(lname) then
		return false
	end

	if tint_any_node then
		if draw == "airlike" then
			return false
		end
		return true
	end

	if draw == "nodebox" then
		if include_mod or lname:find("snow", 1, true) or is_furniture_candidate(base_name, def) or is_structural_candidate(base_name) then
			return true
		end
		return false
	end

	if draw ~= "normal" and draw ~= "glasslike" and draw ~= "allfaces" and draw ~= "allfaces_optional" then
		return false
	end

	return include_mod or is_natural_group_node(def) or is_structural_candidate(base_name) or is_furniture_candidate(base_name, def)
end

local function prereg_priority(base_name, def)
	local score = 0
	local lname = base_name:lower()
	local modprefix = base_name:match("^([^:]+):") or ""
	local g = def and def.groups or {}

	if modprefix == "default" then score = score + 200 end
	if modprefix == "ethereal" then score = score + 100 end
	if modprefix == "moreores" then score = score + 80 end
	if modprefix == "moreblocks" then score = score + 110 end
	if tint_any_node then score = score + 20 end

	if lname:find("stone", 1, true) then score = score + 90 end
	if lname:find("cobble", 1, true) then score = score + 80 end
	if lname:find("sand", 1, true) then score = score + 80 end
	if lname:find("dirt", 1, true) then score = score + 80 end
	if lname:find("snow", 1, true) then score = score + 80 end
	if lname:find("gravel", 1, true) then score = score + 70 end
	if lname:find("clay", 1, true) then score = score + 60 end

	if (g.stone or 0) > 0 then score = score + 40 end
	if (g.sand or 0) > 0 then score = score + 35 end
	if (g.soil or 0) > 0 then score = score + 35 end
	if (g.crumbly or 0) > 0 then score = score + 25 end
	if (g.snowy or 0) > 0 then score = score + 25 end
	if is_structural_candidate(base_name) then score = score + 35 end
	if is_furniture_candidate(base_name, def) then score = score + 25 end

	return score
end

local function is_forced_moreores_node(base_name, def)
	if not base_name:find("^moreores:") then
		return false
	end
	if not is_def_tintable(def) then
		return false
	end
	local lname = base_name:lower()
	if is_excluded_name(lname) then
		return false
	end
	if lname:find("mineral_", 1, true) or lname:find("_block", 1, true) then
		return true
	end
	local g = def.groups or {}
	if (g.cracky or 0) > 0 then
		return true
	end
	return false
end

local FORCED_CORE_NODES = {
	["default:cobble"] = true,
	["default:mossycobble"] = true,
	["default:stone"] = true,
	["default:stonebrick"] = true,
	["default:stone_block"] = true,
}

local function is_forced_core_node(base_name, def)
	if not FORCED_CORE_NODES[base_name] then
		return false
	end
	if not is_def_tintable(def) then
		return false
	end
	return true
end


is_tinted_node = function(name)
	local def = minetest.registered_nodes[name]
	return def and def._light_tint_original
end

is_def_tintable = function(def)
	if not def then
		return false
	end
	if def.drawtype and not ALLOWED_DRAWTYPES[def.drawtype] then
		return false
	end
	if def.walkable == false then
		return false
	end
	if def.liquidtype and def.liquidtype ~= "none" then
		return false
	end
	if (def.light_source or 0) > 0 then
		return false
	end
	if type(def.paramtype2) == "string" and def.paramtype2:find("^color") then
		return false
	end

	local g = def.groups or {}
	if (g.attached_node or 0) > 0 then
		return false
	end

	if (def.on_construct or def.after_place_node or def.on_destruct or def.on_timer) and not (is_natural_group_node(def) or tint_any_node) then
		return false
	end
	if (def.on_receive_fields or def.on_rightclick or def.can_dig) and not (is_natural_group_node(def) or tint_any_node) then
		return false
	end
	if def.allow_metadata_inventory_put or def.allow_metadata_inventory_take or def.allow_metadata_inventory_move then
		return false
	end

	return true
end

local function is_tintable_node(pos, name)
	if not name or name == "air" or name == "ignore" then
		return false
	end
	if is_tinted_node(name) then
		return true
	end

	local def = minetest.registered_nodes[name]
	if not def then
		return false
	end
	if not is_def_tintable(def) then
		return false
	end

	local meta = minetest.get_meta(pos):to_table()
	if next(meta.fields) ~= nil then
		return false
	end
	if meta.inventory then
		for _, list in pairs(meta.inventory) do
			if type(list) == "table" and #list > 0 then
				return false
			end
		end
	end

	return true
end

local function register_tinted_variant(base_name, color_name)
	local key = base_name .. "|" .. color_name
	if tinted_node_for[key] then
		return tinted_node_for[key]
	end

	local base = minetest.registered_nodes[base_name]
	if not base then
		return nil
	end

	local color_hex = COLOR_HEX[color_name]
	if not color_hex then
		return nil
	end

	local def = copy_table(base)
	def.description = (base.description or base_name) .. " (Tinted)"
	def.tiles = tint_tiles(base.tiles, color_hex)
	def.overlay_tiles = tint_tiles(base.overlay_tiles, color_hex)
	def.special_tiles = tint_tiles(base.special_tiles, color_hex)
	if type(base.inventory_image) == "string" and base.inventory_image ~= "" then
		def.inventory_image = base.inventory_image .. tint_modifier(color_hex)
	end
	if type(base.wield_image) == "string" and base.wield_image ~= "" then
		def.wield_image = base.wield_image .. tint_modifier(color_hex)
	end

	def.drop = base_name
	def._light_tint_original = base_name
	def._light_tint_color = color_name
	def.groups = copy_table(base.groups or {})
	def.groups.not_in_creative_inventory = 1

	local new_name = stable_tinted_name(base_name, color_name)
	if minetest.registered_nodes[new_name:sub(2)] then
		tinted_node_for[key] = new_name:sub(2)
		return new_name:sub(2)
	end
	minetest.register_node(new_name, def)
	local registered_name = new_name:sub(2)
	tinted_node_for[key] = registered_name
	return registered_name
end

local function get_tinted_variant(base_name, color_name)
	return tinted_node_for[base_name .. "|" .. color_name]
end

local function detect_color_from_name(name)
	local lname = name:lower()
	for i = 1, #COLOR_PATTERNS do
		local p = COLOR_PATTERNS[i]
		if lname:find(p[1], 1, true) then
			return p[2]
		end
	end
	return nil
end

local colored_light_nodes = {}
local colored_light_list = {}
local colored_light_seen = {}

local function add_colored_light_node(name, color_name, radius)
	local color_hex = COLOR_HEX[color_name]
	if not color_hex then
		return
	end
	local is_new = colored_light_nodes[name] == nil
	colored_light_nodes[name] = {
		color = color_name,
		radius = radius,
	}
	if is_new and not colored_light_seen[name] then
		colored_light_seen[name] = true
		colored_light_list[#colored_light_list + 1] = name
	end
end

function light_tint_register_colored_light(node_name, color_name, radius)
	local def = minetest.registered_nodes[node_name]
	if not def or not def.light_source or def.light_source < 2 then
		return
	end
	local effect_radius = radius or math.min(max_effect_radius, math.max(2, math.floor(def.light_source / 2) + 1 + radius_bonus))
	add_colored_light_node(node_name, color_name, effect_radius)
end

light_tint = {
	register_colored_light = light_tint_register_colored_light,
}

minetest.register_on_mods_loaded(function()
	local used_colors = {}

	for name, def in pairs(minetest.registered_nodes) do
		if def.light_source and def.light_source > 1 then
			local color_name = detect_color_from_name(name)
			if color_name then
				local radius = math.min(max_effect_radius, math.max(2, math.floor(def.light_source / 2) + 1 + radius_bonus))
				add_colored_light_node(name, color_name, radius)
				used_colors[color_name] = true
			end
		end
	end

	local current_registered = 0
	for _ in pairs(minetest.registered_nodes) do
		current_registered = current_registered + 1
	end
	local engine_budget = math.max(0, 32768 - current_registered - 200)
	local variant_budget = math.max(0, math.min(max_registered_variants, engine_budget))

	local candidates = {}
	for base_name, base_def in pairs(minetest.registered_nodes) do
		if should_preregister_base_node(base_name, base_def) then
			candidates[#candidates + 1] = {
				name = base_name,
				def = base_def,
				priority = prereg_priority(base_name, base_def),
			}
		end
	end
	table.sort(candidates, function(a, b)
		if a.priority == b.priority then
			return a.name < b.name
		end
		return a.priority > b.priority
	end)

	local pre_registered = 0
	local skipped_budget = 0
	local forced_seen = {}

	for base_name, base_def in pairs(minetest.registered_nodes) do
		if pre_registered >= variant_budget then
			break
		end
		if is_forced_moreores_node(base_name, base_def) or is_forced_core_node(base_name, base_def) then
			forced_seen[base_name] = true
			for color_name, _ in pairs(used_colors) do
				if pre_registered >= variant_budget then
					skipped_budget = skipped_budget + 1
					break
				end
				local variant = register_tinted_variant(base_name, color_name)
				if variant then
					pre_registered = pre_registered + 1
				end
			end
		end
	end

	for i = 1, #candidates do
		local base_name = candidates[i].name
		if forced_seen[base_name] then
			goto continue_candidate
		end
		for color_name, _ in pairs(used_colors) do
			if pre_registered >= variant_budget then
				skipped_budget = skipped_budget + 1
				break
			end
			local variant = register_tinted_variant(base_name, color_name)
			if variant then
				pre_registered = pre_registered + 1
			end
		end
		if pre_registered >= variant_budget then
			break
		end
		::continue_candidate::
	end

	minetest.log("action", "[light_tint] colored light nodes detected: " .. tostring(#colored_light_list))
	minetest.log("action", "[light_tint] pre-registered tint variants: " .. tostring(pre_registered) .. " (budget " .. tostring(variant_budget) .. ")")
	if pre_registered >= variant_budget or skipped_budget > 0 then
		minetest.log("warning", "[light_tint] tint variant registration budget reached; some node types were skipped")
	end
end)

local sphere_cache = {}

local function get_sphere_offsets(radius)
	local cached = sphere_cache[radius]
	if cached then
		return cached
	end

	local out = {}
	for x = -radius, radius do
		for y = -radius, radius do
			for z = -radius, radius do
				local dist = math.sqrt(x * x + y * y + z * z)
				if dist <= radius then
					out[#out + 1] = {x = x, y = y, z = z, dist = dist}
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.dist == b.dist then
			if a.x == b.x then
				if a.y == b.y then
					return a.z < b.z
				end
				return a.y < b.y
			end
			return a.x < b.x
		end
		return a.dist < b.dist
	end)
	sphere_cache[radius] = out
	return out
end

local active_tints = {}
local time_acc = 0
local player_overlay_hud = {}

local function clamp(v, mn, mx)
	if v < mn then return mn end
	if v > mx then return mx end
	return v
end

local function clear_player_overlay(player)
	if not player then
		return
	end
	local name = player:get_player_name()
	local rec = player_overlay_hud[name]
	if rec and rec.id then
		player:hud_remove(rec.id)
	end
	player_overlay_hud[name] = nil
end

local function update_player_overlay(player, color_name, strength)
	if not player_overlay_enabled then
		clear_player_overlay(player)
		return
	end
	if not color_name or not strength or strength <= 0 then
		clear_player_overlay(player)
		return
	end

	local rgb = OVERLAY_RGB[color_name]
	local color_hex = COLOR_HEX[color_name]
	if rgb then
		color_hex = string.format("#%02x%02x%02x", rgb.r, rgb.g, rgb.b)
	end
	if not color_hex then
		clear_player_overlay(player)
		return
	end

	local opacity = clamp(math.floor(strength * player_overlay_max_alpha + 0.5), player_overlay_min_alpha, player_overlay_max_alpha)
	if opacity <= 0 then
		clear_player_overlay(player)
		return
	end

	local text = "default_stone.png^[resize:4x4^[colorize:" .. color_hex .. ":255^[opacity:" .. opacity
	local name = player:get_player_name()
	local rec = player_overlay_hud[name]
	if rec and rec.id then
		player:hud_change(rec.id, "text", text)
		return
	end

	local id = player:hud_add({
		hud_elem_type = "image",
		position = {x = 0.5, y = 0.5},
		scale = {x = -100, y = -100},
		text = text,
		alignment = {x = 0, y = 0},
		offset = {x = 0, y = 0},
		z_index = -300,
	})
	player_overlay_hud[name] = {id = id}
end

minetest.register_on_leaveplayer(function(player)
	clear_player_overlay(player)
end)

local function set_node_tinted(pos, color_name, now)
	local key = pos_key(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then
		return false
	end

	local def = minetest.registered_nodes[node.name]
	if not def then
		return false
	end

	local base_name = def._light_tint_original or node.name
	if not is_tintable_node(pos, base_name) then
		return false
	end

	if only_exposed_nodes then
		local dirs = {
			{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0},
			{x = 0, y = 1, z = 0}, {x = 0, y = -1, z = 0},
			{x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1},
		}
		local exposed = false
		for i = 1, #dirs do
			local d = dirs[i]
			local np = {x = pos.x + d.x, y = pos.y + d.y, z = pos.z + d.z}
			local nn = minetest.get_node_or_nil(np)
			if not nn then
				exposed = true
				break
			end
			if nn.name == "air" then
				exposed = true
				break
			end
			local ndef = minetest.registered_nodes[nn.name]
			if not ndef then
				exposed = true
				break
			end
			if ndef.drawtype == "airlike" or ndef.walkable == false then
				exposed = true
				break
			end
			if ndef.liquidtype and ndef.liquidtype ~= "none" then
				exposed = true
				break
			end
		end
		if not exposed then
			return false
		end
	end

	local target_name = get_tinted_variant(base_name, color_name)
	if not target_name then
		return false
	end

	if node.name ~= target_name then
		minetest.swap_node(pos, {name = target_name, param1 = node.param1, param2 = node.param2})
	end

	active_tints[key] = {
		pos = {x = pos.x, y = pos.y, z = pos.z},
		expire = now + tint_ttl,
	}
	return true
end

local function restore_if_stale(now)
	for key, rec in pairs(active_tints) do
		if rec.expire < now then
			local node = minetest.get_node_or_nil(rec.pos)
			if node then
				local def = minetest.registered_nodes[node.name]
				if def and def._light_tint_original then
					minetest.swap_node(rec.pos, {name = def._light_tint_original, param1 = node.param1, param2 = node.param2})
				end
			end
			active_tints[key] = nil
		end
	end
end

minetest.register_globalstep(function(dtime)
	time_acc = time_acc + dtime
	if time_acc < interval then
		return
	end
	time_acc = 0

	if #colored_light_list == 0 then
		return
	end

	local now = minetest.get_us_time() / 1000000
	local ops = 0

	for _, player in ipairs(minetest.get_connected_players()) do
		local p = vector.round(player:get_pos())
		local p_exact = player:get_pos()
		local minp = vector.subtract(p, scan_radius)
		local maxp = vector.add(p, scan_radius)
		local lights = minetest.find_nodes_in_area(minp, maxp, colored_light_list)
		local best_color = nil
		local best_strength = 0

		local count = 0
		for i = 1, #lights do
			if count >= max_lights_per_player then
				break
			end
			count = count + 1

			local lpos = lights[i]
			local lnode = minetest.get_node_or_nil(lpos)
			if lnode then
				local linfo = colored_light_nodes[lnode.name]
				if linfo then
					local pdist = vector.distance(p_exact, lpos)
					local pstrength = 1 - (pdist / math.max(1, linfo.radius))
					if pstrength > best_strength then
						best_strength = pstrength
						best_color = linfo.color
					end

					if ops < max_tints_per_step then
						local offsets = get_sphere_offsets(linfo.radius)
						for j = 1, #offsets do
							if ops >= max_tints_per_step then
								break
							end
							local off = offsets[j]
							local tpos = {
								x = lpos.x + off.x,
								y = lpos.y + off.y,
								z = lpos.z + off.z,
							}
							if set_node_tinted(tpos, linfo.color, now) then
								ops = ops + 1
							end
						end
					end
				end
			end
		end
		update_player_overlay(player, best_color, best_strength)
	end

	restore_if_stale(now)
end)
