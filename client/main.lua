local thrownWeapons = {}
local playerCoords = vector3(0, 0, 0)
local animDicts = {
    ['melee@unarmed@streamed_variations'] = false,
    ['pickup_object'] = false
}
local MAX_THROWN_OBJECTS = 25
local objectCount = 0
local lastThrowTime = 0
local THROW_COOLDOWN = 1000 -- 1 second cooldown between throws

local pistolHashes = { -- thank plebmasters forge for this otherwise id kms
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
    [1198879012] = true     
}

local suppressorCompatiblePistols = {
    [453432689] = true,     
    [1593441988] = true,    
    [584646201] = true,     
    [-1716589765] = true,   
    [-771403250] = true,    
    [137902532] = true,     
    [1432025498] = true,    
    [-2009644972] = true    
}

local weaponNameToHash = { -- Thank plebmasters for this, otherwise id kms Again bruh
    ['WEAPON_PISTOL'] = 453432689,
    ['WEAPON_COMBATPISTOL'] = 1593441988,
    ['WEAPON_APPISTOL'] = 584646201,
    ['WEAPON_PISTOL50'] = -1716589765,
    ['WEAPON_SNSPISTOL'] = -1076751822,
    ['WEAPON_HEAVYPISTOL'] = -771403250,
    ['WEAPON_VINTAGEPISTOL'] = 137902532,
    ['WEAPON_MARKSMANPISTOL'] = -598887786,
    ['WEAPON_MACHINEPISTOL'] = -619010992,
    ['WEAPON_PISTOL_MK2'] = 1432025498,
    ['WEAPON_SNSPISTOL_MK2'] = -2009644972,
    ['WEAPON_REVOLVER'] = -1045183535,
    ['WEAPON_REVOLVER_MK2'] = -879347409,
    ['WEAPON_DOUBLEACTION'] = -1746263880,
    ['WEAPON_CERAMICPISTOL'] = -1853920116,
    ['WEAPON_NAVYREVOLVER'] = -1466123874,
    ['WEAPON_GADGETPISTOL'] = 727643628,
    ['WEAPON_STUNGUN'] = 911657153,
    ['WEAPON_FLAREGUN'] = 1198879012
}

local weaponHashToBaseName = {}
for name, hash in pairs(weaponNameToHash) do
    weaponHashToBaseName[hash] = name:gsub('WEAPON_', '')
end

local labelCache = {}
local weaponModelCache = {}
local loadedModels = {}

local function ensureAnimLoaded(dict)
    if not dict or dict == '' then return false end
    
    if not animDicts[dict] then
        RequestAnimDict(dict)
        local timeout = 0
        while not HasAnimDictLoaded(dict) and timeout < 50 do
            Wait(10)
            timeout = timeout + 1
        end
        animDicts[dict] = HasAnimDictLoaded(dict)
    elseif not HasAnimDictLoaded(dict) then
        RequestAnimDict(dict)
        local timeout = 0
        while not HasAnimDictLoaded(dict) and timeout < 50 do
            Wait(10)
            timeout = timeout + 1
        end
        animDicts[dict] = HasAnimDictLoaded(dict)
    end
    return animDicts[dict]
end

local function unloadAnimDict(dict)
    if animDicts[dict] and HasAnimDictLoaded(dict) then
        RemoveAnimDict(dict)
        animDicts[dict] = false
        return true
    end
    return false
end

local function unloadUnusedAnims()
    for dict, loaded in pairs(animDicts) do
        if loaded then
            unloadAnimDict(dict)
        end
    end
end

local function getFormattedLabel(baseName)
    if not baseName then return "Unknown" end
    if labelCache[baseName] then return labelCache[baseName] end
    local label = baseName:gsub('_', ' ')
    label = label:upper():sub(1,1) .. label:sub(2)
    labelCache[baseName] = label
    return label
end

local function getWeaponPropModel(weaponHash)
    if not weaponHash or weaponHash == 0 then return 0 end
    if weaponModelCache[weaponHash] then return weaponModelCache[weaponHash] end
    
    local modelHash
    
    if suppressorCompatiblePistols[weaponHash] then
        modelHash = GetWeaponComponentTypeModel(0x65EA7EBB)
    end
    
    if not modelHash or modelHash == 0 then
        local baseName = weaponHashToBaseName[weaponHash]
        if not baseName then return 0 end
        
        modelHash = `w_${baseName:lower()}`
        if modelHash == 0 then
            modelHash = `w_pi_${baseName:lower()}`
        end
    end
    
    modelHash = modelHash ~= 0 and modelHash or weaponHash
    weaponModelCache[weaponHash] = modelHash
    return modelHash
end

local function loadModel(modelHash)
    if not modelHash or modelHash == 0 then return false end
    if loadedModels[modelHash] then return true end
    
    RequestModel(modelHash)
    
    local timeout = 0
    while not HasModelLoaded(modelHash) and timeout < 50 do
        Wait(10)
        timeout = timeout + 1
    end
    
    if HasModelLoaded(modelHash) then
        loadedModels[modelHash] = true
        return true
    end
    
    return false
end

local function unloadModel(modelHash)
    if loadedModels[modelHash] then
        SetModelAsNoLongerNeeded(modelHash)
        loadedModels[modelHash] = nil
        return true
    end
    return false
end

local function unloadUnusedModels()
    for modelHash in pairs(loadedModels) do
        unloadModel(modelHash)
    end
end

local function createWeaponObject(modelHash, position, heading, force)
    if not position or not heading or not force then return 0 end
    if not loadModel(modelHash) then return 0 end
    
    local obj = CreateObject(modelHash, position.x, position.y, position.z, true, true, true)
    if not obj or obj == 0 then 
        unloadModel(modelHash)
        return 0 
    end
    
    SetEntityHeading(obj, heading)
    ApplyForceToEntity(obj, 1, force.x, force.y, force.z, 0.0, 0.0, 0.0, 0, true, true, true, false, true)
    
    return obj
end

local function cleanupObject(objectId)
    if not objectId or objectId == 0 then return false end
    if not DoesEntityExist(objectId) then return false end
    
    exports.ox_target:removeLocalEntity(objectId)
    SetEntityAsMissionEntity(objectId, true, true)
    
    local deleted = DeleteEntity(objectId)
    if deleted then
        objectCount = math.max(0, objectCount - 1)
        return true
    end
    
    return false
end

local function cleanupAllObjects()
    for weaponId, objectId in pairs(thrownWeapons) do
        cleanupObject(objectId)
        thrownWeapons[weaponId] = nil
    end
    objectCount = 0
end

local function removeOldestObject()
    local oldestId = nil
    local oldestTime = math.huge
    
    for id, data in pairs(thrownWeapons) do
        if data.time < oldestTime then
            oldestTime = data.time
            oldestId = id
        end
    end
    
    if oldestId then
        cleanupObject(thrownWeapons[oldestId].object)
        thrownWeapons[oldestId] = nil
        return true
    end
    
    return false
}

lib.onCache('coords', function(coords)
    playerCoords = coords or playerCoords
end)

RegisterNetEvent('s-throwweapons:throwWeapon', function()
    if not cache.weapon then return end
    
    local currentTime = GetGameTimer()
    if currentTime - lastThrowTime < THROW_COOLDOWN then return end
    lastThrowTime = currentTime
    
    local inventory = exports.ox_inventory:GetPlayerItems()
    if not inventory then return end
    
    local itemData
    local baseName = weaponHashToBaseName[cache.weapon]
    
    if not baseName then return end
    
    for _, item in pairs(inventory) do
        if item.name == baseName then
            itemData = item
            break
        end
    end
    
    if not itemData then return end
    
    if ensureAnimLoaded('melee@unarmed@streamed_variations') then
        TaskPlayAnim(cache.ped, 'melee@unarmed@streamed_variations', 'plyr_takedown_front_slap', 8.0, -8.0, -1, 0, 0, false, false, false)
    end
    
    Wait(700)
    
    local forwardVector = GetEntityForwardVector(cache.ped)
    if not forwardVector then return end
    
    local throwPosition = vector3(
        playerCoords.x + (forwardVector.x * 2.0),
        playerCoords.y + (forwardVector.y * 2.0),
        playerCoords.z
    )
    
    TriggerServerEvent('s-throwweapons:throwWeaponServer', baseName, itemData.metadata, throwPosition, GetEntityHeading(cache.ped))
    
    Wait(1000)
    unloadAnimDict('melee@unarmed@streamed_variations')
end)

lib.addKeybind({
    name = 'throwpistol',
    description = 'Throw your pistol on the ground',
    defaultKey = 'G',
    defaultMapper = 'keyboard',
    onPressed = function(self)
        TriggerServerEvent('s-throwweapons:commandThrow')
    end -- OX LIB IS GOATED
})

RegisterNetEvent('s-throwweapons:spawnWeaponObject', function(weaponId, weaponName, position, heading)
    if not weaponId or not weaponName or not position or not heading then return end
    
    if objectCount >= MAX_THROWN_OBJECTS then
        if not removeOldestObject() then return end
    end
    
    local weaponHash = weaponNameToHash['WEAPON_' .. weaponName] or 0
    if weaponHash == 0 then return end
    
    local modelHash = getWeaponPropModel(weaponHash)
    if modelHash == 0 then return end
    
    local forwardVector = GetEntityForwardVector(cache.ped)
    if not forwardVector then return end
    
    local force = vector3(forwardVector.x * 3.0, forwardVector.y * 3.0, 0.5)
    
    local weaponObj = createWeaponObject(modelHash, position, heading, force)
    if weaponObj == 0 then return end
    
    objectCount = objectCount + 1
    thrownWeapons[weaponId] = {
        object = weaponObj,
        model = modelHash,
        time = GetGameTimer()
    }
    
    exports.ox_target:addLocalEntity(weaponObj, {
        {
            name = 'pickup_weapon_' .. weaponId,
            label = 'Pick up ' .. getFormattedLabel(weaponName),
            icon = 'fas fa-hand-point-up',
            distance = 2.0,
            onSelect = function()
                TriggerServerEvent('s-throwweapons:pickupWeapon', weaponId)
            end
        }
    })
end)

RegisterNetEvent('s-throwweapons:pickupWeapon', function(weaponId)
    if not weaponId or not thrownWeapons[weaponId] then return end
    
    local objectData = thrownWeapons[weaponId]
    if not objectData or not DoesEntityExist(objectData.object) then return end
    
    if ensureAnimLoaded('pickup_object') then
        TaskPlayAnim(cache.ped, 'pickup_object', 'pickup_low', 8.0, -8.0, -1, 0, 0, false, false, false)
    end
    
    Wait(1000)
    TriggerServerEvent('s-throwweapons:confirmPickup', weaponId)
    unloadAnimDict('pickup_object')
end)

RegisterNetEvent('s-throwweapons:removeWeaponObject', function(weaponId)
    if not weaponId or not thrownWeapons[weaponId] then return end
    
    local objectData = thrownWeapons[weaponId]
    if objectData then
        cleanupObject(objectData.object)
        unloadModel(objectData.model)
        thrownWeapons[weaponId] = nil
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    ensureAnimLoaded('melee@unarmed@streamed_variations')
    ensureAnimLoaded('pickup_object')
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    cleanupAllObjects()
    unloadUnusedAnims()
    unloadUnusedModels()
end)