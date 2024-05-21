---@type Plugin
local mode = ...
mode.name = 'Duels'
mode.author = 'jdb'
mode.description = 'A multi 1v1 arena similar to source mods.'

mode.defaultConfig = {
	advertisement = '',
	weaponWeights = {1,1,1,1,2,2,2,2,3,3,4,4,5}
}

local json = require 'main.json'

local elo = mode:require('elo')
local botProfiles = mode:require('botProfiles')
local duelLocations = mode:require('locations')

local profilesFile = 'duels-elo.json'
local profiles = {}
local profilesDirty = false
local defaultElo = 1500

local testingLocation = 0

local currentDuels = {}
local canShoot = false

local function saveProfiles ()
	local f = io.open(profilesFile, 'w')
	if f then
		f:write(json.encode(profiles))
		f:close()
		mode:print('Profiles saved')
	end
end

local duelWeapons = {
	{
		name = 'AK-47',
		id = 1,
		extraMags = 3
	},
	{
		name = 'M-16',
		id = 3,
		extraMags = 3
	},
	{
		name = 'MP5',
		id = 7,
		extraMags = 6
	},
	{
		name = 'Uzi',
		id = 9,
		extraMags = 6
	},
	{
		name = '9mm',
		id = 11,
		extraMags = 6
	}
}

-- Global text chat rather than human talking
function mode.hooks.PlayerChat (ply, message)
	if message:gsub('%W',''):lower():find('nigge') then
		message = "i'm an idiot"
	end

	local str = string.format('<%s> %s', ply.name, message)
	chat.announceWrap(str)

	if log then
		log('[Chat][G] %s (%s): %s', ply.name, dashPhoneNumber(ply.phoneNumber), message)
	end

	return hook.override
end

local specCamSpawnPoint = Vector(2536, 41, 1000)

function mode.hooks.PostPlayerCreate ()
	if server.state == 1 then
		events.createSound(37, specCamSpawnPoint)
	end
end

function mode.hooks.PostPlayerDelete ()
	if server.state == STATE_PREGAME then
		events.createSound(29, specCamSpawnPoint)
	end
end

-- Disable top 10 list, we have a custom one
function mode.hooks.EventMessage (type, message, speakerID)
	if type == 0 and speakerID == -1 then
		if message == 'Top 10 list' then
			return hook.override
		end
		for i = 1, 10 do
			if message:startsWith(i .. '. ') then
				return hook.override
			end
		end
	end
end

function mode.hooks.PhysicsBullets ()
	local doGC = false
	for _, bul in pairs(bullets.getAll()) do
		local duel = bul.player.data.duel
		if duel then
			local loc = duel.location
			if not isVectorInCuboid(bul.pos, loc.bounds[1], loc.bounds[2]) then
				bul.time = -1
				doGC = true
			end
		end
	end
	if doGC then
		physics.garbageCollectBullets()
	end
end

function mode.hooks.Physics ()
	if server.state == STATE_GAME then
		for _, man in pairs(humans.getAll()) do
			if not canShoot then
				man.inputFlags = bit32.band(man.inputFlags, bit32.bnot(1))
			end
			if man.isAlive and not man.isBleeding then
				if man.leftArmHP < 100 then man.leftArmHP = man.leftArmHP + 1 end
				if man.rightArmHP < 100 then man.rightArmHP = man.rightArmHP + 1 end
				if man.leftLegHP < 100 then man.leftLegHP = man.leftLegHP + 1 end
				if man.rightLegHP < 100 then man.rightLegHP = man.rightLegHP + 1 end
			end
		end
	end
end

function mode.onEnable ()
	local f = io.open(profilesFile, 'r')
	if f then
		local data = json.decode(f:read('*all'))
		profiles = data

		f:close()
		mode:print('Profiles loaded')
	end

	server.type = TYPE_ROUND
	server:reset()
end

function mode.hooks.PostResetGame ()
	if profilesDirty then
		profilesDirty = false
		saveProfiles()
	end

	server.state = STATE_PREGAME
	server.time = 5 * server.TPS

	for _, ply in ipairs(players.getAll()) do
		ply.data.duel = nil
	end

	currentDuels = {}
	canShoot = false

	-- Play a C chord : )
	events.createSound(29, specCamSpawnPoint, 1, 1.49831)
	events.createSound(29, specCamSpawnPoint, 1, 1.25992)
	events.createSound(29, specCamSpawnPoint, 1, 1)

	-- Disable random spread
	for _, type in pairs(itemTypes.getAll()) do
		if type.isGun then
			type.bulletSpread = 0.0
		end
	end
end

local function getProfile (ply)
	if ply.isBot then
		return nil
	end

	-- Profile keys are strings so JSON doesn't see it is an array
	local phone = tostring(ply.phoneNumber)
	
	if not profiles[phone] then
		profiles[phone] = {
			elo = defaultElo
		}
	end

	profiles[phone].name = ply.name

	return profiles[phone]
end

local function getElo (ply)
	if ply.isBot then
		return defaultElo
	end

	return getProfile(ply).elo
end

local function setElo (ply, eloRating)
	local profile = getProfile(ply)
	if not profile then return end

	profile.elo = eloRating
	if profile.timesUpdated then
		profile.timesUpdated = profile.timesUpdated + 1
	else
		profile.timesUpdated = 1
	end

	if ply.isActive then
		ply.money = eloRating
		ply:updateFinance()
	end
end

--[[
Decided based on the distribution of all players' ratings
1200
1258  D-
1317  D
1375  D+
1433  C-
1492  C
1550  C+
1608  B-
1667  B
1725  B+
1788  A-
1842  A
1900  A+
1958
]]
local function getEloRank (eloRating)
	if eloRating < 1258 then return 'D-' end
	if eloRating < 1317 then return 'D' end
	if eloRating < 1375 then return 'D+' end
	if eloRating < 1433 then return 'C-' end
	if eloRating < 1492 then return 'C' end
	if eloRating < 1550 then return 'C+' end
	if eloRating < 1608 then return 'B-' end
	if eloRating < 1667 then return 'B' end
	if eloRating < 1725 then return 'B+' end
	if eloRating < 1788 then return 'A-' end
	if eloRating < 1842 then return 'A' end
	return 'A+'
end

do
	local oldName

	mode.hooks.EventUpdatePlayer = function (ply)
		if ply.isBot then
			oldName = ply.name
			ply.name = '[Bot] ' .. ply.name
			return
		end

		local profile = getProfile(ply)
		if profile then
			ply.money = profile.elo
			ply:updateFinance()
			if profile.timesUpdated and profile.timesUpdated >= 10 then
				oldName = ply.name
				ply.name = string.format('[%s] %s', getEloRank(profile.elo), ply.name)
			end
		end
	end

	mode.hooks.PostEventUpdatePlayer = function (ply)
		if oldName then
			ply.name = oldName
			oldName = nil
		end
	end
end

local function isSomeoneReady (plys, desired)
	for _, ply in pairs(plys) do
		if ply.isReady == desired then
			return true
		end
	end
	return false
end

local function playSoundAll (plys, type, volume, pitch)
	for _, ply in pairs(plys) do
		local man = ply.human
		if man and man.isAlive then
			events.createSound(type, man.pos, volume, pitch)
		end
	end
end

local function duelSpawn (ply, spawn, shirtColor, wep, objectsTable)
	ply.model = 0 --civilian
	ply.suitColor = shirtColor
	ply.tieColor = 0 --none

	local pos = vecRandBetween(spawn[2], spawn[3])
	local rot = orientations[spawn[1]]

	local man = humans.create(pos, rot, ply)
	table.insert(objectsTable, man)

	if not hook.run('EventUpdatePlayer', ply) then
		ply:update()
		hook.run('PostEventUpdatePlayer', ply)
	end

	if ply.isBot then
		ply.botDestination = spawn[4]
	end

	local gun = items.create(itemTypes[wep.id], pos, rot)
	if gun then
		table.insert(objectsTable, gun)

		man:mountItem(gun, 0)
		local loadedMag = items.create(itemTypes[wep.id + 1], pos, rot)
		if loadedMag then
			table.insert(objectsTable, loadedMag)
			gun:mountItem(loadedMag, 0)
		end

		for _ = 1, wep.extraMags do
			local mag = items.create(itemTypes[wep.id + 1], pos, rot)
			if not mag then break end
			table.insert(objectsTable, mag)
			for slot = 3, 5 do
				if man:mountItem(mag, slot) then
					break
				end
			end
		end
	end

	local bandage = items.create(itemTypes[14], pos, rot)
	if bandage then
		table.insert(objectsTable, bandage)
		man:mountItem(bandage, 6)
	end
end

local function sortCompare (a, b)
	return a.money > b.money
end

local function chooseWeapon (a, b)
	local weights = mode.config.weaponWeights
	local weapons = {}

	for _, ply in ipairs({a, b}) do
		if not ply.isBot then
			local profile = getProfile(ply)
			local weapon
	
			if profile then
				local name = profile.gun
				if name then
					for _, wep in ipairs(duelWeapons) do
						if wep.name == name then
							weapon = wep
						end
					end
				end
			end

			if not weapon then
				local index = weights[math.random(#weights)]
				weapon = duelWeapons[index]
			end
	
			table.insert(weapons, weapon)
		end
	end

	if #weapons then
		return weapons[math.random(#weapons)]
	end

	return duelWeapons[weights[math.random(#weights)]]
end

local function getContestants (plys)
	local contestants = {}
	for _, ply in pairs(plys) do
		if ply.isReady then
			table.insert(contestants, ply)
		end
	end

	table.sort(contestants, sortCompare)

	if (#contestants % 2) ~= 0 then
		local bot = players.createBot()
		if bot then
			bot.gender = math.random(0, 1)
			local identities = botProfiles[bot.gender]
			local index = math.random(#identities)
			bot.name = identities[index]
			bot.head = index % 5
			bot.hairColor = index % 8
			bot.skinColor = index % 6
			bot.hair = index % 9
			bot.eyeColor = index % 8
			bot.phoneNumber = 4201337
			table.insert(contestants, math.random(#contestants + 1), bot)
		end
	end

	return contestants
end

local function matchPlayers (plys)
	local contestants = getContestants(plys)

	local remaining = #contestants
	local location = 0

	if testingLocation > 0 then
		location = testingLocation - 1
	else
		table.shuffle(duelLocations)
	end

	mode:print('Matching players...')

	while remaining > 1 do
		location = location + 1

		if location > #duelLocations then
			chat.announce('** Ran out of arenas somehow. Sorry!')
			break
		end

		remaining = remaining - 2

		local a = table.remove(contestants, 1)
		local b = table.remove(contestants, 1)

		if not a or not b then
			chat.announce('** Failed to get a bot for some reason. Sorry!')
			break
		end

		a.team = 0
		b.team = 1

		local duel = {
			a = a,
			b = b,
			location = duelLocations[location],
			finishTime = nil,
			objects = {}
		}

		mode:print(string.format(' -> %s is facing %s at %s', a.name, b.name, duel.location.name))
			
		table.insert(currentDuels, duel)
		a.data.duel = duel
		b.data.duel = duel

		local shirtColor = math.random(1, 5)
		local wep = chooseWeapon(a, b)

		duelSpawn(a, duel.location.spawnA, shirtColor, wep, duel.objects)
		duelSpawn(b, duel.location.spawnB, shirtColor, wep, duel.objects)
	end
end

local lastReadyUpWarning = 0

local function logicPregame (plys)
	for _, ply in pairs(plys) do
		if ply.team ~= 17 then
			ply.team = 17
			if not hook.run('EventUpdatePlayer', ply) then
				ply:update()
				hook.run('PostEventUpdatePlayer', ply)
			end
		end
	end

	local now = os.realClock()
	if now - lastReadyUpWarning > 4 then
		lastReadyUpWarning = now
		for _, ply in pairs(plys) do
			if not ply.isReady then
				ply:sendMessage('** Ready up if you want to play!')
			end
		end
	end

	if not isSomeoneReady(plys, true) then
		server.time = 10 * server.TPS
		return
	end

	if isSomeoneReady(plys, false) then
		server.time = server.time - 1
		if server.time > 0 then return end
	end

	server.state = STATE_GAME
	server.time = 95 * server.TPS
	matchPlayers(plys)
end

local function announceTopFive ()
	local candidates = {}

	for _, profile in pairs(profiles) do
		table.insert(candidates, profile)
	end

	table.sort(candidates, function (a, b)
		return a.elo > b.elo
	end)

	local strs = {}
	for i = 1, 5 do
		local cnd = candidates[i]
		if cnd then
			table.insert(strs, string.format('%s (%i)', cnd.name, cnd.elo))
		end
	end

	chat.announceWrap('** Top 5 players: ' .. table.concat(strs, ', '))
end

local function getEloBoard (candidates)
	local board = {
		title = 'Top Elo',
		headers = {
			'Rank',
			'Elo',
			'Player'
		},
		rows = {}
	}

	table.sort(candidates, function (a, b)
		return a[2].elo > b[2].elo
	end)

	for i = 1, 20 do
		local cnd = candidates[i]
		if not cnd then
			break
		end

		table.insert(board.rows, {
			tostring(i),
			tostring(cnd[2].elo),
			{
				name = cnd[2].name,
				phoneNumber = tonumber(cnd[1])
			}
		})
	end

	return board
end

local function getTimesPlayedBoard (candidates)
	local board = {
		title = 'Top Play Time',
		headers = {
			'Rank',
			'Games Played',
			'Player'
		},
		rows = {}
	}

	table.sort(candidates, function (a, b)
		return (a[2].timesUpdated or 0) > (b[2].timesUpdated or 0)
	end)

	for i = 1, 20 do
		local cnd = candidates[i]
		if not cnd then
			break
		end

		table.insert(board.rows, {
			tostring(i),
			tostring(cnd[2].timesUpdated or 0),
			{
				name = cnd[2].name,
				phoneNumber = tonumber(cnd[1])
			}
		})
	end

	return board
end

function mode.hooks.BuildBoards (boards)
	local candidates = {}

	for phoneString, profile in pairs(profiles) do
		table.insert(candidates, { phoneString, profile })
	end

	table.insert(boards, getEloBoard(candidates))
	table.insert(boards, getTimesPlayedBoard(candidates))
end

local function outOfBoundsLogic (plys)
	local t = server.time
	for _, ply in ipairs(plys) do
		local man = ply.human
		if man and man.isAlive then
			local pos = man.pos
			local duel = ply.data.duel
			if duel then
				local loc = duel.location
	
				if pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0 then
					for i = 0, 15 do
						local body = man:getRigidBody(i)
						
						-- Nicely bounce people back inside their arenas
						if not isVectorInCuboid(body.pos, loc.bounds[1], loc.bounds[2]) then
							local v = 0.03
	
							local minX, maxX = lowHigh(loc.bounds[1].x, loc.bounds[2].x)
							if body.pos.x <= minX then man:addVelocity(Vector(v, 0, 0)) end
							if body.pos.x >= maxX then man:addVelocity(Vector(-v, 0, 0)) end
	
							local minY, maxY = lowHigh(loc.bounds[1].y, loc.bounds[2].y)
							if body.pos.y <= minY then man:addVelocity(Vector(0, v, 0)) end
							if body.pos.y >= maxY then man:addVelocity(Vector(0, -v, 0)) end
	
							local minZ, maxZ = lowHigh(loc.bounds[1].z, loc.bounds[2].z)
							if body.pos.z <= minZ then man:addVelocity(Vector(0, 0, v)) end
							if body.pos.z >= maxZ then man:addVelocity(Vector(0, 0, -v)) end

							if duel.finishTime then break end

							local manData = man.data

							if manData.duelsOOBTimer and t > manData.duelsOOBTimer then break end
							manData.duelsOOBTimer = t - server.TPS

							if manData.duelsTimesOOB == nil then
								manData.duelsTimesOOB = 1
							else
								manData.duelsTimesOOB = manData.duelsTimesOOB + 1
							end

							if manData.duelsTimesOOB > 10 then
								man.isAlive = false
								break
							end

							local remaining = 10 - manData.duelsTimesOOB
							man:speak(string.format('Out of bounds! %i warning%s left.', remaining, remaining == 1 and '' or 's'), 0)
							mode:print(ply.name..' out of bounds at '..loc.name..' @ '..pos.x..' '..pos.y..' '..pos.z)

							break
						end
					end
				end
			end
		end
	end
end

local function winDuel (winner, loser)
	local winElo, loseElo = elo.calculate(getElo(winner), getElo(loser), 1, 0)

	local winMan = winner.human
	local loseMan = loser.human

	if winMan then
		events.createSound(38, winMan:getRigidBody(3).pos)
	end

	local reason = 'defeated'
	if isActive(loser) and isActive(loseMan) then
		if loseMan.isAlive then
			reason = 'knocked out'
		else
			reason = 'killed'
		end
	end

	local numOngoing = 0
	for _, duel in pairs(currentDuels) do
		if not duel.finishTime then
			numOngoing = numOngoing + 1
		end
	end

	if not winner.isBot and not loser.isBot then
		setElo(winner, winElo)
		setElo(loser, loseElo)

		profilesDirty = true

		chat.announceWrap(string.format('** %s (%i) %s %s (%i)! %i duel%s left.', winner.name, winElo, reason, loser.name, loseElo, numOngoing, numOngoing == 1 and '' or 's'))
	else
		chat.announceWrap(string.format('** %s %s %s! %i duel%s left.', winner.name, reason, loser.name, numOngoing, numOngoing == 1 and '' or 's'))
	end

	mode:print(string.format(' -x %s %s %s', winner.name, reason, loser.name))
end

local function whisperInfo (plys)
	for _, ply in ipairs(plys) do
		local man = ply.human
		if man and not ply.isBot then
			local duel = ply.data.duel
			if duel then
				local opponent

				if duel.a == ply then
					opponent = duel.b
				else
					opponent = duel.a
				end

				if not opponent.isBot then
					man:speak(string.format("Facing %s (%i) at %s", opponent.name, getElo(opponent), duel.location.name), 0)
				else
					man:speak(string.format("Practicing against %s at %s", opponent.name, duel.location.name), 0)
				end
			end
		end
	end
end

local function logicGame (plys)
	server.time = server.time - 1

	if server.time == 94 * server.TPS then
		playSoundAll(plys, 29, 1, 1)
	end
	if server.time == 93 * server.TPS then
		playSoundAll(plys, 29, 1, 1)
	end
	if server.time == 92 * server.TPS then
		playSoundAll(plys, 29, 1, 1)
	end
	if server.time == 91 * server.TPS then
		playSoundAll(plys, 32, 1, 1.63710223425)
		canShoot = true
	end

	if server.time == (95 * server.TPS) - 20 then
		whisperInfo(plys)
	end

	outOfBoundsLogic(plys)

	local numOngoing = 0
	local now = os.realClock()

	for i = #currentDuels, 1, -1 do
		local duel = currentDuels[i]
		if not duel.finishTime then
			numOngoing = numOngoing + 1

			local a = duel.a
			local b = duel.b

			local aMan = a.human
			local bMan = b.human

			if not isActive(a) or not aMan or not aMan.isAlive or aMan.bloodLevel < 20 then
				duel.finishTime = now
				winDuel(b, a)
			elseif not isActive(b) or not bMan or not bMan.isAlive or bMan.bloodLevel < 20 then
				duel.finishTime = now
				winDuel(a, b)
			end
		elseif now - duel.finishTime > 2.5 then
			table.remove(currentDuels, i)

			-- Delete the duel's humans and items
			for _, obj in pairs(duel.objects) do
				if isActive(obj) then
					obj:remove()
				end
			end

			for _, ply in ipairs({ duel.a, duel.b }) do
				if isActive(ply) then
					ply:update()
				end
			end
		end
	end

	if numOngoing == 0 and server.time > 2 * server.TPS then
		server.time = 2 * server.TPS
	end

	if server.time < 1 then
		mode:print('Game ended')
		if numOngoing > 0 then
			chat.announce '** Out of time!'
		end

		server.state = STATE_RESTARTING
		server.time = 4 * server.TPS
		return
	end
end

local function logicRestarting ()
	server.time = server.time - 1

	if server.time == 3 * server.TPS then
		announceTopFive()
	end

	if server.time == 2 * server.TPS and mode.config.advertisement ~= '' then
		chat.announce('** ' .. mode.config.advertisement)
	end

	if server.time < 1 then
		server:reset()
	end
end

mode.hooks.LogicRound = function ()
	local state = server.state
	local plys = players.getAll()

	if state == STATE_PREGAME then
		logicPregame(plys)
	elseif state == STATE_GAME then
		logicGame(plys)
	elseif state == STATE_RESTARTING then
		logicRestarting()
	else
		server.state = STATE_RESTARTING
	end

	return hook.override
end

mode.commands['/gun'] = {
	info = 'Select your preferred gun.',
	usage = '<name>',
	canCall = function (ply) return not ply.isConsole end,
	call = function (ply, _, args)
		assert(#args >= 1, 'usage')

		local allowedNames = {}
		local gunName = args[1]:lower()
		local foundWeapon

		for _, weapon in ipairs(duelWeapons) do
			table.insert(allowedNames, weapon.name)
			if weapon.name:lower() == gunName then
				foundWeapon = weapon
			end
		end

		if not foundWeapon then
			error('Allowed guns: ' .. table.concat(allowedNames, ', '))
		end

		local profile = getProfile(ply)
		assert(profile, 'No profile?')

		profile.gun = foundWeapon.name
		profilesDirty = true

		ply:sendMessage('Preferred gun set to ' .. foundWeapon.name)
	end
}