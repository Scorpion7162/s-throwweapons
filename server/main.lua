local ox_inventory = exports.ox_inventory
local thrownWeapons = {}
local weaponIdCounter = 0
local maxWeapons = 100
local cleanupInterval = 30000
local weaponLifetime = 600000
local playerActionCooldown = 1000
local broadcastDistance = 50.0
local broadcastDistanceSq = broadcastDistance * broadcastDistance
local pickupDistanceSq = 10.0
local validSources = {}
local lastPickupAttempt = {}
local pickupCooldown = 1000
local transactionLock = {}

local pistolHashMap = {
    [453432689] = true,
    [1593441988] = true,
    [584646201] = true,
    [-1716589765] = true,
    [-1076751822] = true,
    [-771403250] = true,
    [137902532] = true,
    [-598887786] = true,
    [-619010992] = true,
    [1432025498] = true,
    [-2009644972] = true,
    [-1045183535] = true,
    [-879347409] = true,
    [-1746263880] = true,
    [-1853920116] = true,
    [-1466123874] = true,
    [727643628] = true,
    [911657153] = true,
    [1198879012] = true,
}

local nameToHash = {
    ['pistol'] = 453432689,
    ['combatpistol'] = 1593441988,
    ['appistol'] = 584646201,
    ['pistol50'] = -1716589765,
    ['snspistol'] = -1076751822,
    ['heavypistol'] = -771403250,
    ['vintagepistol'] = 137902532,
    ['marksmanpistol'] = -598887786,
    ['machinepistol'] = -619010992,
    ['pistol_mk2'] = 1432025498,
    ['snspistol_mk2'] = -2009644972,
    ['revolver'] = -1045183535,
    ['revolver_mk2'] = -879347409,
    ['doubleaction'] = -1746263880,
    ['ceramicpistol'] = -1853920116,
    ['navyrevolver'] = -1466123874,
    ['gadgetpistol'] = 727643628,
    ['stungun'] = 911657153,
    ['flaregun'] = 1198879012
}

local activePlayerActions = {}
local playerTimeout = {}
local playerCoordsCache = {}
local pendingTimeouts = {}
local nearbyPlayerCache = {}
local nearbyPlayerCacheTime = {}
local cacheLifetime = 2000
local maxCacheEntries = 500

local function isValidSource(source)
    return source ~= nil and tonumber(source) ~= nil and GetPlayerPing(source) > 0
end

local function validatePosition(position) -- security n shi
    if not position or type(position) ~= "vector3" then
        return false
    end
    
    if math.abs(position.x) > 10000 or math.abs(position.y) > 10000 or math.abs(position.z) > 10000 then
        return false
    end
    
    return true
end

local function acquireLock(lockId, timeout)
    if transactionLock[lockId] then
        return false
    end
    
    transactionLock[lockId] = true
    
    if timeout and timeout > 0 then
        SetTimeout(timeout, function()
            transactionLock[lockId] = nil
        end)
    end
    
    return true
end

local function releaseLock(lockId)
    transactionLock[lockId] = nil
end

local function getDistanceSquared(v1, v2)
    if not v1 or not v2 then return math.huge end
    return (v1.x - v2.x)^2 + (v1.y - v2.y)^2 + (v1.z - v2.z)^2
end

local function getPlayerCoords(playerId)
    playerId = tonumber(playerId)
    if not playerId or not isValidSource(playerId) then return nil end
    
    local now = GetGameTimer()
    if not playerCoordsCache[playerId] or (now - (playerCoordsCache[playerId].time or 0)) > 1000 then
        local ped = GetPlayerPed(playerId)
        if not ped or ped == 0 then return nil end
        
        local coords = GetEntityCoords(ped)
        if not coords then return nil end
        
        playerCoordsCache[playerId] = {
            coords = coords,
            time = now
        }
        return coords
    end
    
    return playerCoordsCache[playerId].coords
end

local function getNearbyPlayers(position, distanceSquared)
    if not validatePosition(position) or not distanceSquared then
        return {}
    end
    
    local cacheKey = string.format("%.1f_%.1f_%.1f_%d", position.x, position.y, position.z, distanceSquared)
    local now = GetGameTimer()
    
    if nearbyPlayerCache[cacheKey] and (now - (nearbyPlayerCacheTime[cacheKey] or 0)) < cacheLifetime then
        return nearbyPlayerCache[cacheKey]
    end
    
    local players = GetPlayers()
    local result = {}
    
    for i=1, #players do
        local playerId = tonumber(players[i])
        if playerId and isValidSource(playerId) then
            local playerCoords = getPlayerCoords(playerId)
            if playerCoords and getDistanceSquared(position, playerCoords) < distanceSquared then
                result[#result+1] = playerId
            end
        end
    end
    
    nearbyPlayerCache[cacheKey] = result
    nearbyPlayerCacheTime[cacheKey] = now
    
    return result
end

local function clearPlayerAction(source)
    if not source or not activePlayerActions[source] then return end
    
    activePlayerActions[source] = nil
    if playerTimeout[source] then
        playerTimeout[source] = nil
    end
end

local function setPlayerActionTimeout(source, time)
    if not source or playerTimeout[source] then return end
    
    local timeoutId = {active = true}
    playerTimeout[source] = timeoutId
    
    pendingTimeouts[#pendingTimeouts+1] = {
        source = source,
        time = GetGameTimer() + time,
        id = timeoutId
    }
end

local function processTimeouts()
    local now = GetGameTimer()
    local remaining = {}
    
    for i=1, #pendingTimeouts do
        local timeout = pendingTimeouts[i]
        if timeout and timeout.id and timeout.id.active then
            if now >= timeout.time then
                clearPlayerAction(timeout.source)
            else
                remaining[#remaining+1] = timeout
            end
        end
    end
    
    pendingTimeouts = remaining
end

local function broadcastToNearbyPlayers(position, eventName, ...)
    if not validatePosition(position) or not eventName then return end
    
    local players = getNearbyPlayers(position, broadcastDistanceSq)
    for i=1, #players do
        local player = players[i]
        if isValidSource(player) then
            TriggerClientEvent(eventName, player, ...)
        end
    end
end

local function removeOldestWeapon()
    local oldestId = nil
    local oldestTime = math.huge
    
    for id, data in pairs(thrownWeapons) do
        if data and data.timestamp and data.timestamp < oldestTime then
            oldestTime = data.timestamp
            oldestId = id
        end
    end
    
    if oldestId and thrownWeapons[oldestId] then
        local position = thrownWeapons[oldestId].position
        if position then
            broadcastToNearbyPlayers(position, 's-throwweapons:removeWeaponObject', oldestId)
        end
        thrownWeapons[oldestId] = nil
        return true
    end
    
    return false
end

local function cleanupCaches()
    local now = GetGameTimer()
    local cacheCount = 0
    local oldestKey = nil
    local oldestTime = math.huge
    
    for k, v in pairs(nearbyPlayerCacheTime) do
        cacheCount = cacheCount + 1
        if v < oldestTime then
            oldestTime = v
            oldestKey = k
        end
        
        if now - v > cacheLifetime * 2 then
            nearbyPlayerCache[k] = nil
            nearbyPlayerCacheTime[k] = nil
            cacheCount = cacheCount - 1
        end
    end
    
    while cacheCount > maxCacheEntries and oldestKey do
        nearbyPlayerCache[oldestKey] = nil
        nearbyPlayerCacheTime[oldestKey] = nil
        cacheCount = cacheCount - 1
        
        oldestKey = nil
        oldestTime = math.huge
        
        for k, v in pairs(nearbyPlayerCacheTime) do
            if v < oldestTime then
                oldestTime = v
                oldestKey = k
            end
        end
    end
    
    for playerId, data in pairs(playerCoordsCache) do
        if now - data.time > cacheLifetime * 2 or not isValidSource(playerId) then
            playerCoordsCache[playerId] = nil
        end
    end
end

local function countThrownWeapons()
    local count = 0
    for _ in pairs(thrownWeapons) do
        count = count + 1
    end
    return count
end

local function playerHasItem(source, itemName)
    if not source or not itemName then return false end
    
    local inventory = ox_inventory:GetInventoryItems(source)
    if not inventory then return false end
    local weaponName = itemName
    local fullWeaponName = 'WEAPON_' .. itemName
    
    for _, item in pairs(inventory) do
        if item and item.name and (item.name == weaponName or item.name == fullWeaponName) then
            return item.name -- Return the actual item name found
        end
    end
    
    return false
end

lib.addCommand('throwweapon', {
    help = 'Throw your pistol',
}, function(source)
    if isValidSource(source) then
        TriggerClientEvent('s-throwweapons:throwWeapon', source)
    end
end) -- Ox lib is so fucking easy - Linden my beloved🥰🥰🥰🥰

RegisterNetEvent('s-throwweapons:commandThrow', function()
    local source = source
    if not isValidSource(source) then return end
    
    TriggerClientEvent('s-throwweapons:throwWeapon', source)
end)

RegisterNetEvent('s-throwweapons:throwWeaponServer', function(weaponName, metadata, position, heading)
    local source = source
    
    if not isValidSource(source) or activePlayerActions[source] then return end
    if not weaponName or not validatePosition(position) or not heading then return end
    
    local weaponHash = nameToHash[weaponName:lower()]
    if not weaponHash or not pistolHashMap[weaponHash] then return end
    
    local actualItemName = playerHasItem(source, weaponName)
    if not actualItemName then return end
    
    local playerCoords = getPlayerCoords(source)
    if not playerCoords or getDistanceSquared(playerCoords, position) > broadcastDistanceSq then return end
    
    local lockId = 'throw_' .. source
    if not acquireLock(lockId, 5000) then return end
    
    if countThrownWeapons() >= maxWeapons then
        if not removeOldestWeapon() then
            releaseLock(lockId)
            return
        end
    end -- vibe coding could never do what i do
    
    local success = ox_inventory:RemoveItem(source, actualItemName, 1, nil, metadata)
    if not success then
        releaseLock(lockId)
        return
    end
    
    activePlayerActions[source] = true
    setPlayerActionTimeout(source, playerActionCooldown)
    
    weaponIdCounter = weaponIdCounter + 1
    local weaponId = weaponIdCounter
    
    thrownWeapons[weaponId] = {
        weaponName = weaponName,
        metadata = metadata or {},
        position = position,
        thrownBy = source,
        timestamp = GetGameTimer()
    }
    
    TriggerClientEvent('s-throwweapons:spawnWeaponObject', source, weaponId, weaponName, position, heading)
    broadcastToNearbyPlayers(position, 's-throwweapons:spawnWeaponObject', weaponId, weaponName, position, heading)
    
    Wait(500)
    clearPlayerAction(source)
    
    releaseLock(lockId)
end)

RegisterNetEvent('s-throwweapons:pickupWeapon', function(weaponId)
    local source = source
    
    if not isValidSource(source) or activePlayerActions[source] then return end
    if not weaponId or not thrownWeapons[weaponId] then return end
    
    local now = GetGameTimer()
    if lastPickupAttempt[source] and now - lastPickupAttempt[source] < pickupCooldown then return end
    lastPickupAttempt[source] = now
    
    local weaponData = thrownWeapons[weaponId]
    if not weaponData or not validatePosition(weaponData.position) then return end
    
    local lockId = 'pickup_' .. weaponId
    if not acquireLock(lockId, 10000) then return end
    
    local playerCoords = getPlayerCoords(source)
    if not playerCoords or getDistanceSquared(playerCoords, weaponData.position) > pickupDistanceSq then
        releaseLock(lockId)
        return
    end
    
    activePlayerActions[source] = true
    setPlayerActionTimeout(source, playerActionCooldown * 2)
    
    TriggerClientEvent('s-throwweapons:pickupWeapon', source, weaponId)
end)

RegisterNetEvent('s-throwweapons:confirmPickup', function(weaponId)
    local source = source
    
    if not isValidSource(source) or not activePlayerActions[source] then return end
    if not weaponId or not thrownWeapons[weaponId] then
        clearPlayerAction(source)
        return
    end
    
    local lockId = 'confirm_' .. weaponId
    if not acquireLock(lockId, 5000) then
        clearPlayerAction(source)
        return
    end
    
    local weaponData = thrownWeapons[weaponId]
    if not weaponData then
        clearPlayerAction(source)
        releaseLock(lockId)
        return
    end
    
    local playerCoords = getPlayerCoords(source)
    if not playerCoords or getDistanceSquared(playerCoords, weaponData.position) > pickupDistanceSq then
        clearPlayerAction(source)
        releaseLock(lockId)
        return
    end
    
    -- Try to add with the full weapon name first
    local fullWeaponName = 'WEAPON_' .. weaponData.weaponName
    local success = ox_inventory:AddItem(source, fullWeaponName, 1, weaponData.metadata)
    if not success then
        success = ox_inventory:AddItem(source, weaponData.weaponName, 1, weaponData.metadata)
    end
    
    if success then
        broadcastToNearbyPlayers(weaponData.position, 's-throwweapons:removeWeaponObject', weaponId)
        thrownWeapons[weaponId] = nil
    end
    
    clearPlayerAction(source)
    releaseLock(lockId)
end)

AddEventHandler('playerDropped', function()
    local source = source
    clearPlayerAction(source)
    playerCoordsCache[source] = nil
    lastPickupAttempt[source] = nil
    
    for weaponId, weaponData in pairs(thrownWeapons) do
        if weaponData.thrownBy == source then
            thrownWeapons[weaponId].thrownBy = 0
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    activePlayerActions = {}
    playerTimeout = {}
    playerCoordsCache = {}
    pendingTimeouts = {}
    nearbyPlayerCache = {}
    nearbyPlayerCacheTime = {}
    thrownWeapons = {}
    lastPickupAttempt = {}
    transactionLock = {}
end)

CreateThread(function()
    while true do
        processTimeouts()
        
        local now = GetGameTimer()
        local weaponsToRemove = {}
        
        for weaponId, weaponData in pairs(thrownWeapons) do
            if weaponData and weaponData.timestamp and now - weaponData.timestamp > weaponLifetime then
                if validatePosition(weaponData.position) then
                    weaponsToRemove[#weaponsToRemove+1] = {id = weaponId, pos = weaponData.position}
                else
                    thrownWeapons[weaponId] = nil
                end
            end
        end
        
        for i=1, #weaponsToRemove do
            local data = weaponsToRemove[i]
            if data and data.id and data.pos then
                broadcastToNearbyPlayers(data.pos, 's-throwweapons:removeWeaponObject', data.id)
                thrownWeapons[data.id] = nil
            end
        end
        
        cleanupCaches()
        
        Wait(cleanupInterval)
    end
end)