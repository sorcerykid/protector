--------------------------------------------------------
-- Minetest :: Protection Redux Mod (protector)
--
-- See README.txt for licensing and other information.
-- Copyright (c) 2016-2019, Leslie E. Krause
--
-- ./games/minetest_game/mods/protector/init.lua
--------------------------------------------------------

local OWNER_ANYBODY = "_anybody"
local OWNER_SOMEBODY = "_somebody"
local OWNER_NOBODY = ""	-- do not change this value!

local member_limit = 8
local max_tool_range = 10
local protector_radius = tonumber( minetest.setting_get( "protector_radius" ) or 5 )

minetest.register_privilege( "superuser", {
	description = "Bypass ownership and protection checks.",
	give_to_singleplayer = true,
} )

---------------------------
-- Helper Functions
---------------------------

local function is_superuser( name )
	return minetest.check_player_privs( name, "superuser" )
end

local function get_members( meta )
	return meta:get_string( "members" ):split( " " )
end

local function set_members( meta, members )
	meta:set_string( "members", table.concat( members, " " ) )
end

local function is_member( meta, name )
	for _, n in pairs( get_members( meta ) ) do
		if n == name then
			return true
		end
	end
	return false
end

local function is_owner( meta, name )
	return name == meta:get_string( "owner" )
end

local function add_member( meta, name )
	if is_member( meta, name ) or is_owner( meta, name ) then
		return
	end

	local members = get_members( meta )

	if #members < member_limit then
		table.insert( members, name )
	end

	set_members( meta, members )
end

local function del_member( meta, name )
	local members = get_members( meta )

	for i, n in pairs( members ) do
		if n == name then
			table.remove( members, i )
			break
		end
	end

	set_members( meta, members )
end

local function get_area_stats( meta )
	local bitmap = meta:get_string( "bitmap" )
	local node_total = #bitmap
	local lock_count = 0
	
	for node_count = 1, node_total do
		if string.byte( bitmap, node_count ) == 120 then
			lock_count = lock_count + 1
		end
	end

	return node_total, lock_count
end

local function is_area_locked( meta )
	local bitmap = meta:get_string( "bitmap" )
	return bitmap ~= ""
end

local function is_area_locked_at( meta, source_pos, target_pos )
	local bitmap = meta:get_string( "bitmap" )

	-- if there's no bitmap, then the entire area is unlocked
	if bitmap == "" then return false end

	-- check for dot in bitmap, indicating that position is locked
	local voxel_area = VoxelArea:new( {
		MinEdge = vector.subtract( source_pos, protector_radius ),
		MaxEdge = vector.add( source_pos, protector_radius )
	} )

	-- TODO: Sanity check for correct bitmap length!

	local idx = voxel_area:indexp( target_pos )
	return string.byte( bitmap, idx ) == 120
end

local function lock_area( meta, source_pos, content_ids )
	local pos1 = vector.subtract( source_pos, protector_radius )
	local pos2 = vector.add( source_pos, protector_radius )

	local voxel_manip = minetest.get_voxel_manip( )
	local min_pos, max_pos = voxel_manip:read_from_map( pos1, pos2 )
	local map_buffer = voxel_manip:get_data( )
	local voxel_area = VoxelArea:new( { MinEdge = min_pos, MaxEdge = max_pos } )

	local node_data = { }
	local lock_count = 0

	-- indicate all non-buildable nodes as dot in bitmap
	for idx in voxel_area:iterp( pos1, pos2 ) do
		local is_buildable = content_ids[ map_buffer[ idx ] ]

		table.insert( node_data, is_buildable and " " or "x" )

		if not is_buildable then
			lock_count = lock_count + 1
		end
	end

	-- bitmap is compressed by engine, so no need for optimization
	meta:set_string( "bitmap", table.concat( node_data ) )

	return #node_data, lock_count
end

local function unlock_area( meta )
	meta:set_string( "bitmap", "" )
end

local function create_bitmap( is_buildable )
	return string.rep( is_buildable and " " or "x", math.pow( protector_radius * 2 + 1, 3 ) )
end

local function get_bitmap_raw( meta )
	local bitmap = meta:get_string( "bitmap" )
	return bitmap ~= "" and bitmap or nil
end

local function set_bitmap_raw( meta, bitmap )
	meta:set_string( "bitmap", bitmap )
	return get_area_stats( meta )
end

---------------------------
-- Formspec Handlers
---------------------------

local function open_shared_editor( pos, meta, player_name )
	local ignore_air = true
	local ignore_water = true
	local ignore_lava = true

	local function get_formspec( )
		local formspec = "size[8,7]"
			.. default.gui_bg
			.. default.gui_bg_img
			.. default.gui_slots
			.. "label[0.0,0.0;Protector Properties (Shared)]"
			.. "box[0.0,0.6;7.9,0.1;#111111]"
			.. "box[0.0,6.1;7.9,0.1;#111111]"
			.. "label[0.0,1.0;Members: (type player name then click '+' to add)]"
			.. "button_exit[6.0,6.5;2.0,0.5;close;Close]"

		if is_area_locked( meta, pos ) then
			local node_total, lock_count = get_area_stats( meta )

			formspec = formspec
				.. "label[0.0,4.5;Bitmap Mask: (click 'Unlock' to disengage bitmap mask)]"
				.. "button_exit[0.0,5.2;2.0,0.5;unlock;Unlock]"
				.. string.format( "label[2.0,5.2;Contains %d nodes (%d locked, %d unlocked)]", node_total, lock_count, node_total - lock_count )
		else
			formspec = formspec
				.. "label[0.0,4.5;Bitmap Mask: (click 'Lock' to engage bitmap mask)]"
				.. "button_exit[0.0,5.2;2.0,0.5;lock;Lock]"
				.. "checkbox[2.0,5.0;ignore_air;Ignore Air;" .. tostring( ignore_air ) .. "]"
				.. "checkbox[3.8,5.0;ignore_water;Ignore Water;" .. tostring( ignore_water ) .. "]"
				.. "checkbox[6.0,5.0;ignore_lava;Ignore Lava;" .. tostring( ignore_lava ) .. "]"
		end

		local members = get_members( meta )
		local count = 0

		for _, member in pairs( members ) do
			if count < member_limit then
	 			formspec = formspec
					.. string.format( "button[%0.2f,%0.2f;1.5,0.5;;%s]", count % 4 * 2, 0.8 + math.floor( count / 4 + 1 ), member )
					.. string.format( "button[%0.2f,%0.2f;0.75,0.5;del_member_%s;X]", count % 4 * 2 + 1.25, 0.8 + math.floor( count / 4 + 1 ), member )
			end
			count = count + 1
		end
	
		if count < member_limit then
			formspec = formspec
				.. string.format( "field[%0.2f,%0.2f;1.433,0.5;member_name;;]", count % 4 * 2 + 1 / 3, 0.8 + math.floor( count / 4 + 1 ) + 1 / 3 )
				.. string.format( "button[%0.2f,%0.2f;0.75,0.5;add_member;+]", count % 4 * 2 + 1.25, 0.8 + math.floor( count / 4 + 1 ) )
		end

		return formspec
	end

	local function on_close( pos, player, fields )
		if fields.close then
			return

		elseif fields.ignore_air then
			ignore_air = fields.ignore_air == "true"

		elseif fields.ignore_water then
			ignore_water = fields.ignore_water == "true"

		elseif fields.ignore_lava then
			ignore_lava = fields.ignore_lava == "true"

		elseif fields.lock then
			local content_ids = { }

			if ignore_water then
				content_ids[ minetest.get_content_id( "default:water_flowing" ) ] = true
				content_ids[ minetest.get_content_id( "default:water_source" ) ] = true
			end
			if ignore_lava then
				content_ids[ minetest.get_content_id( "default:lava_flowing" ) ] = true
				content_ids[ minetest.get_content_id( "default:lava_source" ) ] = true
			end
			if ignore_air then
				content_ids[ minetest.get_content_id( "air" ) ] = true
			end

			local node_total, lock_count = lock_area( meta, pos, content_ids )
			minetest.chat_send_player( player_name, string.format( "Protection area updated (%d of %d nodes locked).", lock_count, node_total ) )

		elseif fields.unlock then
			unlock_area( meta )
			minetest.chat_send_player( player_name, "Protection area updated (all nodes unlocked)." )

		elseif fields.add_member then
			if string.match( fields.member_name, "^[a-zA-Z0-9_-]+$" ) and string.len( fields.member_name ) <= 25 then
				add_member( meta, fields.member_name )
				minetest.update_form( player:get_player_name( ), get_formspec( meta ) )
			end

		elseif not fields.quit then
			fields.member_name = nil

			local fname = next( fields, nil )     -- use next since we only care about the name of the first button
	                if fname then
				local member_name = string.match( fname, "^del_member_(.+)" )
        	                if member_name then
					del_member( meta, member_name )
					minetest.update_form( player:get_player_name( ), get_formspec( meta ) )
				end
			end
		end
	end

	minetest.create_form( pos, player_name, get_formspec( ), on_close )
end

local function open_public_editor( pos, meta, player_name )
	local ignore_air = true
	local ignore_water = false
	local ignore_lava = false
	local allow_doors = meta:get_string( "allow_doors" ) == "true"
	local allow_chests = meta:get_string( "allow_chests" ) == "true"

	local function get_formspec( )
		local formspec = "size[8,5]"
			.. default.gui_bg
			.. default.gui_bg_img
			.. default.gui_slots
			.. "label[0.0,0.0;Protector Properties (Public)]"
			.. "box[0.0,0.6;7.9,0.1;#111111]"
			.. "box[0.0,4.1;7.9,0.1;#111111]"
			.. "label[0.0,1.0;Permissions:]"
			.. "button_exit[6.0,4.5;2.0,0.5;close;Close]"

			.. "checkbox[0.0,1.4;allow_doors;Allow Steel Doors;" .. tostring( allow_doors ) .. "]"
			.. "checkbox[4.0,1.4;allow_chests;Allow Locked Chests;" .. tostring( allow_chests ) .. "]"

			if is_area_locked( meta, pos ) then
				local node_total, lock_count = get_area_stats( meta )

				formspec = formspec
					.. "label[0.0,2.5;Bitmap Mask: (click 'Unlock' to disengage bitmap mask)]"
					.. "button_exit[0.0,3.2;2.0,0.5;unlock;Unlock]"
					.. string.format( "label[2.0,3.2;Contains %d nodes (%d locked, %d unlocked)]", node_total, lock_count, node_total - lock_count )
			else
				formspec = formspec
					.. "label[0.0,2.5;Bitmap Mask: (click 'Lock' to engage bitmap mask)]"
					.. "button_exit[0.0,3.2;2.0,0.5;lock;Lock]"
					.. "checkbox[2.0,3.0;ignore_air;Ignore Air;" .. tostring( ignore_air ) .. "]"
					.. "checkbox[3.8,3.0;ignore_water;Ignore Water;" .. tostring( ignore_water ) .. "]"
					.. "checkbox[6.0,3.0;ignore_lava;Ignore Lava;" .. tostring( ignore_lava ) .. "]"
			end

		return formspec
	end

	local function on_close( pos, player, fields )
		if fields.close then
			return

		elseif fields.ignore_air then
			ignore_air = fields.ignore_air == "true"

		elseif fields.ignore_water then
			ignore_water = fields.ignore_water == "true"

		elseif fields.ignore_lava then
			ignore_lava = fields.ignore_lava == "true"

		elseif fields.allow_chests then
			allow_chests = fields.allow_chests == "true"
			meta:set_string( "allow_chests", allow_chests and "true" or "false" )

		elseif fields.allow_doors then
			allow_doors = fields.allow_doors == "true"
			meta:set_string( "allow_doors", allow_doors and "true" or "false" )

		elseif fields.lock then
			local content_ids = { }

			if ignore_water then
				content_ids[ minetest.get_content_id( "default:water_flowing" ) ] = true
				content_ids[ minetest.get_content_id( "default:water_source" ) ] = true
			end
			if ignore_lava then
				content_ids[ minetest.get_content_id( "default:lava_flowing" ) ] = true
				content_ids[ minetest.get_content_id( "default:lava_source" ) ] = true
			end
			if ignore_air then
				content_ids[ minetest.get_content_id( "air" ) ] = true
			end

			local node_total, lock_count = lock_area( meta, pos, content_ids )
			minetest.chat_send_player( player_name, string.format( "Protection area updated (%d of %d nodes locked).", lock_count, node_total ) )

		elseif fields.unlock then
			unlock_area( meta )
			minetest.chat_send_player( player_name, "Protection area updated (all nodes unlocked)." )
		end
	end

	minetest.create_form( pos, player_name, get_formspec( ), on_close )
end

---------------------------
-- Protection Handlers
---------------------------

-- Info Level:
-- 0 for no info
-- 1 for "This area is owned by <owner> !" if you can't dig
-- 2 for "This area is owned by <owner>.
-- 3 for checking protector overlaps

local function can_dig( radius, target_pos, player_name, is_strict, info_level )
	if not player_name then return false end

	-- Privileged users can override protection
	if minetest.check_player_privs( player_name, "superuser" ) and info_level == 1 then
		return true
	end

	if info_level == 3 then info_level = 1 end

	local pos_list = minetest.find_nodes_in_area(
		vector.subtract( target_pos, radius or protector_radius ),
		vector.add( target_pos, radius or protector_radius ),
		{ "protector:protect", "protector:protect2", "protector:protect3" }
	)

	for _, pos in pairs( pos_list ) do
		local meta = minetest.get_meta( pos )
		local owner = meta:get_string( "owner" )
		local members = meta:get_string( "members" )
		local is_public = minetest.get_node( pos ).name == "protector:protect3"

		if owner ~= player_name then 

			if is_strict or not is_public and not is_member( meta, player_name ) or is_area_locked_at( meta, pos, target_pos ) then
				if info_level == 1 then
					minetest.chat_send_player( player_name, "This area is owned by " .. owner .. "!" )
				elseif info_level == 2 then
					minetest.chat_send_player( player_name, "This area is owned by " .. owner .. "." )
				end

				if members ~= "" then
					minetest.chat_send_player( player_name, "Protector located at " .. minetest.pos_to_string( pos ) .. " with members: " .. members .. "." )
				else
					minetest.chat_send_player( player_name, "Protector located at " .. minetest.pos_to_string( pos ) .. "." )
				end
				return false
			end
		end

		if info_level == 2 then
			minetest.chat_send_player( player_name, "This area is owned by " .. owner .. "." )

			if members ~= "" then
				minetest.chat_send_player( player_name, "Protector located at " .. minetest.pos_to_string( pos ) .. " with members: " .. members .. "." )
			else
				minetest.chat_send_player( player_name, "Protector located at " .. minetest.pos_to_string( pos ) .. "." )
			end
			return false
		end
	end

	if info_level == 2 then
		if #positions == 0 then
			minetest.chat_send_player( player_name, "This area is not protected." )
		end
		minetest.chat_send_player( digger, "You can build here." )
	end

	return true
end

local old_is_protected = minetest.is_protected

minetest.is_protected = function ( pos, player_name )
        local owner = minetest.get_meta( pos ):get_string( "owner" )
	local player = minetest.get_player_by_name( player_name )

        -- owner = _anybody -> always FALSE
        -- owner = <digger> -> always FALSE
        -- owner = _somebody -> always TRUE
        -- owner = <stranger> -> always TRUE
        -- owner = _nobody / null -> return protection

        -- never allow digging of nodes owned by stranger or by OWNER_SOMEBODY (strictly private ownership)
        -- always allow digging of nodes owned by digger or by OWNER_ANYBODY (strictly public ownership)
        -- otherwise verify protection rules for nodes owned by OWNER_NOBODY (default ownership, when undefined)

	-- prevent long-range dig exploit (evading protectors in unloaded areas)
	if vector.distance( pos, player:getpos( ) ) > max_tool_range then
		return true
	end

	if owner == player_name or owner == OWNER_ANYBODY or owner == OWNER_NOBODY and can_dig( protector_radius, pos, player_name, false, 1 ) then
		return old_is_protected( pos, player_name )
	else
		return true
	end
end

---------------------------
-- Anti-Grief Hooks
---------------------------

local function allow_place( target_pos, player_name, node_name )
	if is_superuser( player_name ) then return true end

	local pos_list = minetest.find_nodes_in_area(
		vector.subtract( target_pos, protector_radius ),
		vector.add( target_pos, protector_radius ),
		{ "protector:protect3" }
	)

	for _, pos in pairs( pos_list ) do
		local meta = minetest.get_meta( pos )
		local allow_doors = meta:get_string( "allow_doors" ) == "true"
		local allow_chests = meta:get_string( "allow_chests" ) == "true"

		-- check restrictions of public protector
		if node_name == "default:chest_locked" and not allow_chests or node_name == "doors:door_steel" and not allow_doors then
			return false
		end
	end
	return true
end

minetest.override_item( "default:chest_locked", {
        allow_place = function ( target_pos, player )
		local player_name = player:get_player_name( )
		if not allow_place( target_pos, player_name, "default:chest_locked" ) then
	                minetest.chat_send_player( player_name, "You are not allowed to place locked chests here!" )
			return false
		end
                return true
        end
} )

minetest.override_item( "doors:door_steel", {
        allow_place = function ( target_pos, player )
		local player_name = player:get_player_name( )
		if not allow_place( target_pos, player_name, "doors:door_steel" ) then
	                minetest.chat_send_player( player_name, "You are not allowed to place steel doors here!" )
			return false
		end
                return true
        end
} )

---------------------------
-- Tool Definitions
---------------------------

minetest.register_tool( "protector:protection_wand", {
        description = "Protection Wand",
        range = 5,
        inventory_image = "protector_wand.png",
	on_use = function( itemstack, player, pointed_thing )
		local pos = pointed_thing.under or vector.round( vector.offset_y( player:getpos( ) ) ) -- if pointing at air, get player position instead
		local player_name = player:get_player_name( )

		-- find the protector nodes
		local pos_list = minetest.find_nodes_in_area(
			vector.subtract( pos, protector_radius ),
			vector.add( pos, protector_radius ),
			{ "protector:protect", "protector:protect2", "protector:protect3" }
		)

		if #pos_list == 0 then
			minetest.chat_send_player( player_name,  "This area is not protected." )
			return
		end
		for i = 1, math.min( 5, #pos_list ) do
			local owner = minetest.get_meta( pos_list[ i ] ):get_string( "owner" ) or ""
			local members = minetest.get_meta( pos_list[ i ] ):get_string( "members" ) or ""

			if i == 1 then
				minetest.chat_send_player( player_name,  "This area is owned by " .. owner .. "." )
			end
			if members ~= "" then
				minetest.chat_send_player( player_name, "Protector located at " .. minetest.pos_to_string( pos_list[ i ] ) .. " with members: " .. members .. "." )
			else
				minetest.chat_send_player( player_name, "Protector located at " .. minetest.pos_to_string( pos_list[ i ] ) .. "." )
			end
		end
	end,
} )

minetest.register_craftitem( "protector:protection_mask", {
	description = "Protection Mask (Point to protector and use)",
	inventory_image = "protector_mask.png",
	wield_image = "protector_mask.png",
	groups = { flammable = 3 },

	on_use = function( cur_stack, player, pointed_thing )
		if pointed_thing.type == "node" then
			local player_name = player:get_player_name( )
			local player_inv = player:get_inventory( )
			local node_meta = minetest.get_meta( pointed_thing.under )
			local node_name = minetest.get_node( pointed_thing.under ).name

			if node_name ~= "protector:protect" and node_name ~= "protector:protect2" and node_name ~= "protector:protect3" then
				return cur_stack
			end

			-- only owner of protector is permitted to copy mask
			if not is_superuser( player_name ) and not is_owner( node_meta, player_name ) then
				minetest.chat_send_player( player_name, "Access denied. Failed to copy protection mask." )
				return cur_stack
			end

			local new_stack = ItemStack( "protector:protection_mask_saved" )
			local new_stack_meta = new_stack:get_meta( )

			local bitmap = get_bitmap_raw( node_meta ) or create_bitmap( true )
			local node_total, lock_count = set_bitmap_raw( new_stack_meta, bitmap )
			local title = string.format( "%d of %d nodes locked", lock_count, node_total )

			new_stack_meta:set_string( "title", title )
			new_stack_meta:set_string( "description", "Protection Mask (" .. title .. ")" )
			new_stack_meta:set_string( "owner", player_name )

			minetest.chat_send_player( player_name, "Protection mask copied (" .. title .. ")" )

			cur_stack:take_item( )

			if cur_stack:is_empty( ) then
				cur_stack:replace( new_stack )
			elseif player_inv:room_for_item( "main", new_stack ) then
				player_inv:add_item( "main", new_stack )
			else
				minetest.add_item( player:getpos( ), new_stack )
			end
		end
		return cur_stack
	end
} )

minetest.register_craftitem( "protector:protection_mask_saved", {
	inventory_image = "protector_mask_saved.png",
	wield_image = "protector_mask_saved.png",
	stack_max = 1,
	groups = { flammable = 3, not_in_creative_inventory = 1 },

        on_use = function( cur_stack, player, pointed_thing )
		if pointed_thing.type == "node" then
			local player_name = player:get_player_name( )
			local node_meta = minetest.get_meta( pointed_thing.under )
			local node_name = minetest.get_node( pointed_thing.under ).name

			if node_name ~= "protector:protect" and node_name ~= "protector:protect2" and node_name ~= "protector:protect3" then
				return cur_stack
			end

			-- only owner of protector is permitted to paste mask
			if not is_superuser( player_name ) and not is_owner( node_meta, player_name ) then
				minetest.chat_send_player( player_name, "Access denied. Failed to paste protection mask." )
				return cur_stack
			end

			local cur_stack_meta = cur_stack:get_meta( )
			local bitmap = get_bitmap_raw( cur_stack_meta )
			local node_total, lock_count = set_bitmap_raw( node_meta, bitmap )

			minetest.chat_send_player( player_name, string.format( "Protection mask pasted (%d of %d nodes locked).", lock_count, node_total ) )
		end

		return cur_stack
	end
} )

---------------------------
-- Node Definitions
---------------------------

local function on_place( itemstack, placer, pointed_thing )
	if pointed_thing.type == "node" then
		if not can_dig( protector_radius * 2, pointed_thing.above, placer:get_player_name( ), true, 3 ) then
			minetest.chat_send_player( placer:get_player_name( ), "Overlaps into above player's protected area." )
		else
			return minetest.item_place( itemstack, placer, pointed_thing )
		end
	end
	return itemstack
end

minetest.register_node( "protector:protect", {
	description = "Protection Stone (Shared)",
	tiles = {
		"protector_top1.png",
		"protector_top1.png",
		"protector_side1.png"
	},
	sounds = default.node_sound_stone_defaults( ),
	groups = { dig_immediate = 2, unbreakable = 1 },
	is_ground_content = false,
	paramtype = "light",
	light_source = 4,

	can_dig = function( pos, player )
		return can_dig( 1, pos, player:get_player_name( ), true, 1 )
	end,

	on_place = on_place,

	after_place_node = function( pos, placer )
		local meta = minetest.get_meta( pos )
		local player_name = placer:get_player_name( ) or "singleplayer"

		meta:set_string( "owner", player_name )
		meta:set_string( "infotext", "Protection (owned by " .. player_name .. ")" )
	end,

	on_rightclick = function( pos, node, clicker, itemstack )
		local meta = minetest.get_meta( pos )
		local player_name = clicker:get_player_name( )
                
		if is_owner( meta, player_name ) or is_superuser( player_name ) then
			open_shared_editor( pos, meta, player_name )
		end
        end,

	on_punch = function( pos, node, puncher )
		local meta = minetest.get_meta( pos )
		local player_name = puncher:get_player_name( )

		if is_owner( meta, player_name ) or is_superuser( player_name ) then
			minetest.add_entity( pos, "protector:display")
		end
	end,

	on_blast = function() end,
} )

minetest.register_node( "protector:protect2", {
	description = "Protection Badge (Shared)",
	tiles = { "protector_logo.png" },
	wield_image = "protector_logo.png",
	inventory_image = "protector_logo.png",
	sounds = default.node_sound_stone_defaults( ),
	groups = { dig_immediate = 2, unbreakable = 1 },
	paramtype = "light",
	paramtype2 = "wallmounted",
	legacy_wallmounted = true,
	light_source = 4,
	drawtype = "nodebox",
	sunlight_propagates = true,
	walkable = false,
	node_box = {
		type = "wallmounted",
		wall_top    = { -0.375, 0.4375, -0.5, 0.375, 0.5, 0.5 },
		wall_bottom = { -0.375, -0.5, -0.5, 0.375, -0.4375, 0.5 },
		wall_side   = { -0.5, -0.5, -0.375, -0.4375, 0.5, 0.375 },
	},
	selection_box = { type = "wallmounted" },

	can_dig = function( pos, player )
		return can_dig( 1, pos, player:get_player_name( ), true, 1 )
	end,

	on_place = on_place,

	after_place_node = function( pos, placer )
		local meta = minetest.get_meta( pos )
		local player_name = placer:get_player_name( ) or "singleplayer"

		meta:set_string( "owner", player_name )
		meta:set_string( "infotext", "Protection (owned by " .. player_name .. ")" )
		meta:set_string( "members", "" )
	end,

	on_rightclick = function( pos, node, clicker, itemstack )
		local meta = minetest.get_meta( pos )
		local player_name = clicker:get_player_name( )

		if is_owner( meta, player_name ) or is_superuser( player_name ) then
			open_shared_editor( pos, meta, player_name )
		end
	end,

	on_punch = function( pos, node, puncher )
		local meta = minetest.get_meta( pos )
		local player_name = puncher:get_player_name( )

		if is_owner( meta, player_name ) or is_superuser( player_name ) then
			minetest.add_entity( pos, "protector:display" )
		end
	end,

	on_blast = function( ) end,
} )

minetest.register_node( "protector:protect3", {
	description = "Protection Stone (Public)",
	tiles = {
		"protector_top2.png",
		"protector_top2.png",
		"protector_side2.png"
	},
	sounds = default.node_sound_stone_defaults( ),
	groups = { dig_immediate = 2, unbreakable = 1 },
	is_ground_content = false,
	paramtype = "light",
	light_source = 4,

	can_dig = function( pos, player )
		return can_dig( 1, pos, player:get_player_name( ), true, 1 )
	end,

	on_place = on_place,

	after_place_node = function( pos, placer )
		local meta = minetest.get_meta( pos )
		local player_name = placer:get_player_name( ) or "singleplayer"

		meta:set_string( "owner", player_name )
		meta:set_string( "infotext", "Protection (owned by " .. player_name .. ")" )
		meta:set_string( "allow_doors", "false" )
		meta:set_string( "allow_chests", "false" )

		local node_total, lock_count = lock_area( meta, pos, {
			[minetest.get_content_id( "default:water_flowing" )] = true,
			[minetest.get_content_id( "default:water_source" )] = true,
			[minetest.get_content_id( "default:lava_flowing" )] = true,
			[minetest.get_content_id( "default:lava_source" )] = true,
			[minetest.get_content_id( "air" )] = true
		} )
		minetest.chat_send_player( player_name, string.format( "Protection area updated (%d of %d nodes locked).", lock_count, node_total ) )
	end,

	on_rightclick = function( pos, node, clicker, itemstack )
		local meta = minetest.get_meta( pos )
		local player_name = clicker:get_player_name( )
                
		if is_owner( meta, player_name ) or is_superuser( player_name ) then
			open_public_editor( pos, meta, player_name )
		end
        end,

	on_punch = function( pos, node, puncher )
		local meta = minetest.get_meta( pos )
		local player_name = puncher:get_player_name( )

		if is_owner( meta, player_name ) or is_superuser( player_name ) then
			minetest.add_entity( pos, "protector:display" )
		end
	end,

	on_blast = function() end,
} )

---------------------------
-- Entity Definition
---------------------------

minetest.register_entity( "protector:display", {
	physical = false,
	collisionbox = { 0, 0, 0, 0, 0, 0 },
	visual = "wielditem",
	-- wielditem is scaled to 1.5 times original node size?
	visual_size = { x = 1.0 / 1.5, y = 1.0 / 1.5 },
	textures = { "protector:display_node" },
	timer = 0,

	on_step = function( self, dtime )
		self.timer = self.timer + dtime

		if self.timer > 7 then
			self.object:remove( )
		end
	end,
} )

local r = protector_radius

-- NB: this node definition is only a basis for the entity above
minetest.register_node( "protector:display_node", {
	tiles = { "protector_display.png" },
	use_texture_alpha = true,
	walkable = false,
	drawtype = "nodebox",
	node_box = {
		type = "fixed",
		fixed = {
			-- west face
			{ -r + 0.55, -r + 0.55, -r + 0.55, -r + 0.45, r + 0.55, r + 0.55 },
			-- north face
			{ -r + 0.55, -r + 0.55, r + 0.45, r + 0.55, r + 0.55, r + 0.55 },
			-- east face
			{ r + 0.45, -r + 0.55, -r + 0.55, r + 0.55, r + 0.55, r + 0.55 },
			-- south face
			{ -r + 0.55, -r + 0.55, -r + 0.55, r + 0.55, r + 0.55, -r + 0.45 },
			-- top face
			{ -r + 0.55, r + 0.45, -r + 0.55, r + 0.55, r + 0.55, r + 0.55 },
			-- bottom face
			{ -r + 0.55, -r + 0.55, -r + 0.55, r + 0.55, -r + 0.45, r +0.55 },
			-- center (surround protector)
			{ -0.55, -0.55, -0.55, 0.55, 0.55, 0.55 },
		},
	},
	selection_box = {
		type = "regular",
	},
	paramtype = "light",
	groups = { dig_immediate = 3, not_in_creative_inventory = 1 },
	drop = "",
} )

---------------------------
-- Crafting Recipes
---------------------------

minetest.register_craft( {
	output = "protector:protect3",
	recipe = {
		{ "default:stone", "default:stone", "default:stone" },
		{ "default:stone", "default:mese", "default:stone" },
		{ "default:stone", "default:stone", "default:stone" },
	}
} )

minetest.register_craft( {
	output = "protector:protect2",
	recipe = {
		{ "default:stone", "default:copper_ingot", "default:stone" },
		{ "default:copper_ingot", "default:mese", "default:copper_ingot" },
		{ "default:stone", "default:copper_ingot", "default:stone" },
	}
} )

minetest.register_craft( {
	output = "protector:protect",
	recipe = {
		{ "default:stone", "default:steel_ingot", "default:stone" },
		{ "default:steel_ingot", "default:mese", "default:steel_ingot" },
		{ "default:stone", "default:steel_ingot", "default:stone" },
	}
} )

minetest.register_craft( {
	output = "protector:protection_wand",
	recipe = {
		{ "default:mese_crystal" },
		{ "default:stick" },
	}
} )

minetest.register_craft( {
	output = "protector:protection_mask",
	recipe = {
		{ "", "default:steel_ingot", "" },
		{ "default:steel_ingot", "default:mese_crystal", "default:steel_ingot" },
		{ "", "default:steel_ingot", "" },
	}
} )

