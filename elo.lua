--[[
	Elo functions from:
	https://github.com/TheSquirrel/Combat-Rating-System/blob/master/elo_functions.lua
]]

local elo = {}

local K = 16

function elo.expectedScores (ratA, ratB)
	return 1 / (1 + 10 ^ ((ratB - ratA) / 400)), 1 / (1 + 10 ^ ((ratA - ratB) / 400))
end

function elo.updateRating (rat, score, expScore)
	return math.round(rat + K * (score - expScore))
end

function elo.calculate (ratA, ratB, scoreA, scoreB)
	local expA, expB = elo.expectedScores(ratA, ratB)
	return elo.updateRating(ratA, scoreA, expA), elo.updateRating(ratB, scoreB, expB)
end

return elo