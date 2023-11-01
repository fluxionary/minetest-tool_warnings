futil.check_version({ year = 2023, month = 11, day = 1 }) -- is_player

local f = string.format
local S = tool_warnings.S
local s = tool_warnings.settings

local tool_break_sound
if minetest.get_modpath("default") then
	tool_break_sound = "default_tool_breaks"
end

-----------------------------------------------
-- general functions

local function get_break_sound(tool)
	return (tool:get_definition().sound or {}).breaks or tool_break_sound
end

local function get_remaining_uses(wear_after, wear_per_use)
	return math.ceil((65536 - wear_after) / wear_per_use)
end

local last_caution_by_name = {}
local last_urging_by_name = {}

local function caution_player(player, tool)
	local player_name = player:get_player_name()
	local now = os.time()
	local last = last_caution_by_name[player_name]

	if not last or now - last >= s.warning_cooldown then
		local description = futil.get_safe_short_description(tool)
		local msg = minetest.colorize("yellow", S("your @1 needs repair!", minetest.strip_colors(description)))
		tool_warnings.chat_send_player(player_name, msg)
		last_caution_by_name[player_name] = now
	end

	local sound = get_break_sound(tool)

	if sound then
		minetest.sound_play(sound, {
			to_player = player_name,
			gain = 1.0,
		})
	end
end

local function urge_player(player, tool)
	local player_name = player:get_player_name()
	local now = os.time()
	local last = last_urging_by_name[player_name]

	if not last or now - last >= s.warning_cooldown then
		local description = futil.get_safe_short_description(tool)
		local msg = minetest.colorize("red", S("your @1 needs repair urgently!", minetest.strip_colors(description)))
		tool_warnings.chat_send_player(player_name, msg)
		last_urging_by_name[player_name] = now
	end

	local sound = get_break_sound(tool)

	if sound then
		minetest.sound_play(sound, {
			to_player = player_name,
			gain = 2.0,
		})
	end

	tool_warnings.log("action", "%s's %q is about to break", player_name, tool:to_string())
end

local function get_dig_params(tool, node)
	local tool_capabilities = tool:get_definition().tool_capabilities
	local node_groups = (minetest.registered_nodes[node.name] or {}).groups
	local wear = tool:get_wear()

	if not (tool_capabilities and node_groups and wear) then
		return
	end

	return minetest.get_dig_params(node_groups, tool_capabilities, wear)
end

local function get_remaining_uses_and_time(dig_params, wear)
	if not wear or not dig_params.wear or dig_params.wear == 0 then
		return
	end

	local remaining_uses = get_remaining_uses(wear, dig_params.wear)

	if not dig_params.time or dig_params.time == 0 then
		return remaining_uses
	end

	return remaining_uses, (remaining_uses - 1) * dig_params.time
end

local function get_remaining_uses_and_time_after_use(original_item, used_item, dig_params)
	if original_item:get_name() ~= used_item:get_name() then
		return 1, 0
	end

	local original_wear = original_item:get_wear()
	local used_wear = used_item:get_wear()

	if original_wear >= used_wear then
		return math.huge, math.huge
	end

	local remaining_uses = get_remaining_uses(original_wear, used_wear - original_wear)

	if not dig_params.time or dig_params.time == 0 then
		return remaining_uses
	end

	return remaining_uses, (remaining_uses - 1) * dig_params.time
end

local function check_and_warn_time(player, tool, remaining, urgent, careful)
	if not (urgent and careful) then
		check_and_warn_time(player, tool, remaining, urgent or s.urgent_time, careful or s.careful_time)
		return
	end

	if remaining <= urgent then
		urge_player(player, tool)
	elseif remaining <= careful then
		caution_player(player, tool)
	end
end

local function check_and_warn_uses(player, tool, remaining, urgent, careful)
	if not (urgent and careful) then
		check_and_warn_uses(player, tool, remaining, urgent or s.urgent_uses, careful or s.careful_uses)
		return
	end

	if remaining <= urgent then
		urge_player(player, tool)
	elseif remaining <= careful then
		caution_player(player, tool)
	end
end

local function check_and_warn_wear(player, tool, wear, urgent, careful)
	if not (urgent and careful) then
		check_and_warn_wear(player, tool, wear, urgent or s.urgent_wear, careful or s.careful_wear)
		return
	end

	if wear > urgent then
		urge_player(player, tool)
	elseif wear > careful then
		caution_player(player, tool)
	end
end

-----------------------------------------------
-- check and warn on normal tool use

local function check_and_warn(pos, node, player, pointed_thing)
	local tool = player:get_wielded_item()
	local dig_params = get_dig_params(tool, node)

	if not (dig_params and dig_params.diggable) then
		return
	end

	local remaining_uses, remaining_time
	local item_def = tool:get_definition()
	if item_def.after_use then
		local item_after_use = item_def.after_use(ItemStack(tool), player, node, dig_params) or tool
		remaining_uses, remaining_time = get_remaining_uses_and_time_after_use(tool, item_after_use, dig_params)
	else
		remaining_uses, remaining_time = get_remaining_uses_and_time(dig_params, tool:get_wear())
	end

	if remaining_time then
		check_and_warn_time(player, tool, remaining_time)
	elseif remaining_uses then
		check_and_warn_uses(player, tool, remaining_uses)
	else
		local wear = tool:get_wear()
		check_and_warn_wear(player, tool, wear)
	end
end

minetest.register_on_punchnode(check_and_warn)

-----------------------------------------------
-- Overrides for tools with special logic not handled by the above

local function generate_on_use(old_on_use, careful_level, urgent_level)
	return function(tool, user, pointed_thing)
		local wear_before = tool:get_wear()
		local name_before = tool:get_name()
		local tool_after = old_on_use(tool, user, pointed_thing) or tool
		local name_after = tool:get_name()

		if name_before ~= name_after then
			return tool_after
		end

		local wear_after = tool_after:get_wear()
		local wear_per_use = wear_after - wear_before

		if wear_per_use > 0 then
			local remaining_uses = get_remaining_uses(wear_after, wear_per_use)
			check_and_warn_uses(user, tool, remaining_uses, urgent_level, careful_level)
		end

		return tool_after
	end
end

function tool_warnings.check_wear_on_use(itemname, careful_level, urgent_level)
	local def = minetest.registered_items[itemname]
	if not def then
		error(f("attempt to override unknown item %s", itemname))
	end
	local old_on_use = def.on_use
	if not old_on_use then
		error(f("attempt to override non-existent on_use for %s", itemname))
	end

	minetest.override_item(itemname, {
		on_use = generate_on_use(old_on_use, careful_level, urgent_level),
	})
end

function tool_warnings.check_wear_on_secondary_use(itemname, careful_level, urgent_level)
	local def = minetest.registered_items[itemname]
	if not def then
		error(f("attempt to override unknown item %s", itemname))
	end
	local old_on_secondary_use = def.on_secondary_use
	if not old_on_secondary_use then
		error(f("attempt to override non-existent on_secondary_use for %s", itemname))
	end

	minetest.override_item(itemname, {
		on_secondary_use = generate_on_use(old_on_secondary_use, careful_level, urgent_level),
	})
end

function tool_warnings.check_wear_on_place(itemname, careful_level, urgent_level)
	local def = minetest.registered_items[itemname]
	if not def then
		error(f("attempt to override unknown item %s", itemname))
	end
	local old_on_place = def.on_place
	if not old_on_place then
		error(f("attempt to override non-existent on_secondary_use for %s", itemname))
	end

	minetest.override_item(itemname, {
		on_place = generate_on_use(old_on_place, careful_level, urgent_level),
	})
end

-----------------------------------------------
-- try to log when a tool breaks

local old_node_dig = minetest.node_dig
function minetest.node_dig(pos, node, digger)
	local wielded = digger and digger:get_wielded_item()
	local wielded_string
	if wielded and not wielded:is_empty() then
		wielded_string = wielded:to_string()
	end
	local rv = old_node_dig(pos, node, digger)
	wielded = digger and digger:get_wielded_item()
	if wielded_string and wielded and wielded:is_empty() then
		tool_warnings.log(
			"action",
			"%s's %q broke after digging %s",
			digger:get_player_name(),
			wielded_string,
			node.name
		)
	end
	return rv
end

------------------------------------------------
-- handle mobs

minetest.register_on_mods_loaded(function()
	for name, def in pairs(minetest.registered_entities) do
		if def.on_punch then
			local old_on_punch = def.on_punch
			function def.on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
				if not futil.is_player(puncher) then
					return old_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
				end

				local armor_groups = self.object:get_armor_groups()
				local tool = puncher:get_wielded_item()
				if tool:is_empty() then
					return old_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
				end

				local wear_before = tool:get_wear()
				local rv = old_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
				local tool_after = puncher:get_wielded_item()
				if tool:get_name() ~= tool_after:get_name() then
					return rv
				end

				local wear_after = tool_after:get_wear()

				-- simulate wear from engine, which happens later
				local hit_params =
					minetest.get_hit_params(armor_groups, tool_capabilities or {}, time_from_last_punch, wear_after)
				wear_after = math.min(65536, wear_after + hit_params.wear)

				if wear_after > wear_before then
					local remaining_uses = get_remaining_uses(wear_after, wear_after - wear_before)
					check_and_warn_uses(puncher, tool, remaining_uses, 2 * s.urgent_uses, 2 * s.careful_uses)
				end
				return rv
			end
		end
	end
end)
