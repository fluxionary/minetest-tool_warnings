tool_warnings = fmod.create()

local s = tool_warnings.settings

-----------------------------------------------
-- general functions

local last_caution_by_name = {}
local last_warning_by_name = {}

local function caution_player(player)
	local player_name = player:get_player_name()
	local now = os.time()
	local last = last_caution_by_name[player_name]

	if not last or now - last >= s.warning_cooldown then
		local description = futil.futil.get_safe_short_description(player:get_wielded_item())

		local msg = minetest.colorize("yellow", ("your %s needs repair!"):format(description))
		minetest.chat_send_player(player_name, msg)
		last_caution_by_name[player_name] = now
	end

	minetest.sound_play("default_tool_breaks", {
		to_player = player_name,
		gain = 1.0,
	})
end

local function urge_player(player)
	local player_name = player:get_player_name()
	local now = os.time()
	local last = last_warning_by_name[player_name]

	if not last or now - last >= s.warning_cooldown then
		local description = futil.get_safe_short_description(player:get_wielded_item())

		local msg = minetest.colorize("red", ("your %s needs repair urgently!"):format(description))
		minetest.chat_send_player(player_name, msg)
		last_warning_by_name[player_name] = now
	end

	minetest.sound_play("default_tool_breaks", {
		to_player = player_name,
		gain = 2.0,
	})

	local wielded = player:get_wielded_item()
	tool_warnings.log("action", "%s's %q is about to break", player_name, wielded:to_string())
end

local function get_dig_params(item, node)
	local tool_capabilities = (minetest.registered_tools[item:get_name()] or {}).tool_capabilities
	local node_groups = (minetest.registered_nodes[node.name] or {}).groups
	local wear = item:get_wear()

	if not (tool_capabilities and node_groups and wear) then
		return
	end

	return minetest.get_dig_params(node_groups, tool_capabilities, wear)
end

local function get_remaining_uses_and_time(dig_params, wear)
	if not wear or not dig_params.wear or dig_params.wear == 0 then
		return
	end

	local remaining_uses = math.ceil((65535 - wear) / dig_params.wear)

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
		return tonumber("inf"), tonumber("inf")
	end

	local remaining_uses = math.ceil((65535 - original_wear) / (used_wear - original_wear))

	if not dig_params.time or dig_params.time == 0 then
		return remaining_uses
	end

	return remaining_uses, (remaining_uses - 1) * dig_params.time
end

local function check_and_warn_time(player, remaining, urgent, careful)
	if not (urgent and careful) then
		check_and_warn_time(player, remaining, urgent or s.urgent_time, careful or s.careful_time)
		return
	end

	if remaining <= urgent then
		urge_player(player)
	elseif remaining <= careful then
		caution_player(player)
	end
end

local function check_and_warn_uses(player, remaining, urgent, careful)
	if not (urgent and careful) then
		check_and_warn_uses(player, remaining, urgent or s.urgent_uses, careful or s.careful_uses)
		return
	end

	if remaining <= urgent then
		urge_player(player)
	elseif remaining <= careful then
		caution_player(player)
	end
end

local function check_and_warn_wear(player, wear, urgent, careful)
	if not (urgent and careful) then
		check_and_warn_wear(player, wear, urgent or s.urgent_wear, careful or s.careful_wear)
		return
	end

	if wear > urgent then
		urge_player(player)
	elseif wear > careful then
		caution_player(player)
	end
end

-----------------------------------------------
-- check and warn on normal tool use

local function check_and_warn(pos, node, player, pointed_thing)
	local item = player:get_wielded_item()
	local dig_params = get_dig_params(item, node)

	if not (dig_params and dig_params.diggable) then
		return
	end

	local remaining_uses, remaining_time
	local item_def = item:get_definition()
	if item_def.after_use then
		local item_after_use = item_def.after_use(ItemStack(item), player, node, dig_params) or item
		remaining_uses, remaining_time = get_remaining_uses_and_time_after_use(item, item_after_use, dig_params)
	else
		remaining_uses, remaining_time = get_remaining_uses_and_time(dig_params, item:get_wear())
	end

	if remaining_time then
		check_and_warn_time(player, remaining_time)
	elseif remaining_uses then
		check_and_warn_uses(player, remaining_uses)
	else
		local wear = item:get_wear()
		check_and_warn_wear(player, wear)
	end
end

minetest.register_on_punchnode(check_and_warn)

-----------------------------------------------
-- Overrides for tools with special logic not handled by the above

local function generate_on_use(old_on_use, careful_level, urgent_level)
	return function(itemstack, user, pointed_thing)
		local wear_before = itemstack:get_wear()
		local name_before = itemstack:get_name()
		local itemstack_after = old_on_use(itemstack, user, pointed_thing) or itemstack
		local name_after = itemstack:get_name()

		if name_before ~= name_after then
			return itemstack_after
		end

		local wear_after = itemstack_after:get_wear()
		local wear_used = wear_after - wear_before

		if wear_used > 0 then
			local remaining_uses = math.ceil((65535 - wear_after) / wear_used)
			check_and_warn_uses(user, remaining_uses, urgent_level, careful_level)
		end

		return itemstack_after
	end
end

function tool_warnings.check_wear_on_use(itemname, careful_level, urgent_level)
	local def = minetest.registered_items[itemname]
	if not def then
		error(("attempt to override unknown item %s"):format(itemname))
	end
	local old_on_use = def.on_use
	if not old_on_use then
		error(("attempt to override non-existent on_use for %s"):format(itemname))
	end

	minetest.override_item(itemname, {
		on_use = generate_on_use(old_on_use, careful_level, urgent_level),
	})
end

function tool_warnings.check_wear_on_rightclick(itemname, careful_level, urgent_level)
	local def = minetest.registered_items[itemname]
	if not def then
		error(("attempt to override unknown item %s"):format(itemname))
	end
	local old_on_secondary_use = def.on_secondary_use
	if not old_on_secondary_use then
		error(("attempt to override non-existent on_secondary_use for %s"):format(itemname))
	end

	minetest.override_item(itemname, {
		on_secondary_use = generate_on_use(old_on_secondary_use, careful_level, urgent_level),
	})
end

function tool_warnings.check_wear_on_place(itemname, careful_level, urgent_level)
	local def = minetest.registered_items[itemname]
	if not def then
		error(("attempt to override unknown item %s"):format(itemname))
	end
	local old_on_place = def.on_place
	if not old_on_place then
		error(("attempt to override non-existent on_secondary_use for %s"):format(itemname))
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
		tool_warnings.log("action", "%s's %q broke after use", digger:get_player_name(), wielded_string)
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
				if not minetest.is_player(puncher) then
					return old_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
				end

				local armor_groups = self.object:get_armor_groups()
				local before_item = puncher:get_wielded_item()
				if before_item:is_empty() then
					return old_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
				end

				local before_wear = before_item:get_wear()
				local rv = old_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
				local after_item = puncher:get_wielded_item()
				if before_item:get_name() ~= after_item:get_name() then
					return rv
				end

				local after_wear = after_item:get_wear()

				-- simulate wear from engine, which happens later
				local hit_params =
					minetest.get_hit_params(armor_groups, tool_capabilities or {}, time_from_last_punch, after_wear)
				after_wear = math.min(65536, after_wear + hit_params.wear)

				if after_wear > before_wear then
					local remaining_uses = math.ceil((65536 - after_wear) / (after_wear - before_wear))
					check_and_warn_uses(puncher, remaining_uses, 2 * s.urgent_uses, 2 * s.careful_uses)
				end
				return rv
			end
		end
	end
end)
