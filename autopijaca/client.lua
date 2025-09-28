local ESX = exports['es_extended']:getSharedObject()

local PlayerData = {}
local State = {
    parkingSpots = {},
    myListedVehicles = {},
    isInitialized = false
}

local spawnedVehicles = {}
local spawnedKeyByIndex = {}
local reconcilePending = false
local isReconciling = false

local function SetState(key, value)
    State[key] = value
end

local function GetState(key)
    return State[key]
end

local function Notify(data)
    TriggerEvent('ox_lib:notify', data)
end

local function RequestSpawnReconcile()
    if reconcilePending then return end
    reconcilePending = true
    SetTimeout(400, function()
        reconcilePending = false
        local ok, err = pcall(function()
            if not isReconciling then
                isReconciling = true
                local success, e = pcall(function()
                    local spots = GetState('parkingSpots') or {}
                    -- Delete any that should not exist
                    for idx, veh in pairs(spawnedVehicles) do
                        local desired = spots[idx]
                        if not desired or not desired.occupied then
                            if DoesEntityExist(veh) then
                                ESX.Game.DeleteVehicle(veh)
                            end
                            spawnedVehicles[idx] = nil
                            spawnedKeyByIndex[idx] = nil
                        end
                    end

                    -- Ensure exist those that should
                    for i = 1, #spots do
                        local spot = spots[i]
                        if spot and spot.occupied and spot.vehicleProps and spot.vehicleModel then
                            local key = (tostring(spot.vehicleModel) or 'nil') .. '|' .. (tostring(spot.plate) or 'nil')
                            local existing = spawnedVehicles[i]
                            local existingKey = spawnedKeyByIndex[i]
                            if existing and DoesEntityExist(existing) then
                                if existingKey ~= key then
                                    ESX.Game.DeleteVehicle(existing)
                                    spawnedVehicles[i] = nil
                                    spawnedKeyByIndex[i] = nil
                                else
                                    -- Optionally refresh properties to keep them in sync
                                    ESX.Game.SetVehicleProperties(existing, spot.vehicleProps)
                                end
                            end

                            if not spawnedVehicles[i] then
                                local model = spot.vehicleModel
                                lib.requestModel(model)
                                ESX.Game.SpawnVehicle(model, spot.coords, spot.heading or 0.0, function(vehicle)
                                    if DoesEntityExist(vehicle) then
                                        ESX.Game.SetVehicleProperties(vehicle, spot.vehicleProps)
                                        SetVehicleDoorsLocked(vehicle, 2)
                                        FreezeEntityPosition(vehicle, true)
                                        SetEntityAsMissionEntity(vehicle, true, true)
                                        SetVehicleHasBeenOwnedByPlayer(vehicle, false)
                                        SetEntityCanBeDamaged(vehicle, false)
                                        SetVehicleCanBeVisiblyDamaged(vehicle, false)

                                        spawnedVehicles[i] = vehicle
                                        spawnedKeyByIndex[i] = key
                                    end
                                end)
                                Wait(50)
                            end
                        end
                    end
                end)
                isReconciling = false
                if not success then print('^1[AutoPijaca] reconcile error: ' .. tostring(e) .. '^0') end
            end
        end)
        if not ok then print('^1[AutoPijaca] reconcile wrapper error: ' .. tostring(err) .. '^0') end
    end)
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    CreateThread(function()
        while not ESX do Wait(100) end
        Wait(500)
        PlayerData = ESX.GetPlayerData()
        InitializeSystem()
    end)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for i, vehicle in pairs(spawnedVehicles) do
        if DoesEntityExist(vehicle) then ESX.Game.DeleteVehicle(vehicle) end
        spawnedVehicles[i] = nil
        spawnedKeyByIndex[i] = nil
    end
    for i = 1, #Config.MarketLocation.parkingSpots do
        exports.ox_target:removeZone('autopijaca_spot_' .. i)
    end
end)

RegisterNetEvent('esx:playerLoaded')
AddEventHandler('esx:playerLoaded', function(xPlayer)
    PlayerData = xPlayer
    if not State.isInitialized then InitializeSystem() else FetchMyListedVehicles() end
end)

RegisterNetEvent('esx:setJob')
AddEventHandler('esx:setJob', function(job)
    PlayerData.job = job
    if State.isInitialized and job and job.name == Config.JobName then
        FetchMyListedVehicles()
    end
end)

function InitializeSystem()
    if State.isInitialized then return end
    CreateMarketPed()
    SetupParkingSpotTargets()
    FetchParkingSpots(function()
        RequestSpawnReconcile()
    end)
    if PlayerData.job and PlayerData.job.name == Config.JobName then
        FetchMyListedVehicles()
    end
    State.isInitialized = true
    print('^2[AutoPijaca] Client system initialized^0')
end

function CreateMarketPed()
    local market = Config.MarketLocation
    lib.requestModel(market.pedModel)
    local ped = CreatePed(4, market.pedModel, market.pedCoords.x, market.pedCoords.y, market.pedCoords.z - 1.0, market.pedHeading, false, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)

    exports.ox_target:addLocalEntity(ped, {
        {
            name = 'autopijaca_sell_car',
            icon = 'fa-solid fa-car',
            label = 'Postavi auto na prodaju',
            distance = 2.5,
            canInteract = function()
                return PlayerData.job and PlayerData.job.name == Config.JobName
            end,
            onSelect = OpenSellVehicleMenu
        },
        {
            name = 'autopijaca_my_vehicles',
            icon = 'fa-solid fa-list',
            label = 'Moja vozila na prodaji',
            distance = 2.5,
            canInteract = function()
                return PlayerData.job and PlayerData.job.name == Config.JobName
            end,
            onSelect = ShowMyListedVehicles
        }
    })
end

function SetupParkingSpotTargets()
    for i, spot in ipairs(Config.MarketLocation.parkingSpots) do
        exports.ox_target:addSphereZone({
            coords = spot.coords,
            radius = 3.0,
            debug = false,
            options = {
                {
                    name = 'autopijaca_spot_' .. i,
                    icon = 'fa-solid fa-car',
                    label = 'Pregledaj vozilo',
                    distance = 3.0,
                    onSelect = function()
                        OpenVehicleContext(i)
                    end
                }
            }
        })
    end
end

function FetchParkingSpots(cb)
    ESX.TriggerServerCallback('autopijaca:getParkingSpots', function(spots)
        SetState('parkingSpots', spots or {})
        if cb then cb() end
    end)
end

function FetchMyListedVehicles()
    ESX.TriggerServerCallback('autopijaca:getMyListedVehicles', function(vehicles)
        SetState('myListedVehicles', vehicles or {})
    end)
end

-- MENU: Sell vehicle
function OpenSellVehicleMenu()
    ESX.TriggerServerCallback('autopijaca:getPlayerVehicles', function(playerVehicles)
        if not playerVehicles or #playerVehicles == 0 then
            return lib.notify({ title = 'Autopijaca', description = 'Nemaš vozila za prodaju', type = 'error' })
        end

        local freeSpots = GetFreeParkingSpots()
        if #freeSpots == 0 then
            return lib.notify({ title = 'Autopijaca', description = 'Nema slobodnih mjesta na pijaci', type = 'error' })
        end

        local options = {}
        for _, vehicle in ipairs(playerVehicles) do
            local vehicleProps = json.decode(vehicle.vehicle or '{}')
            local displayName = GetDisplayNameFromVehicleModel(vehicleProps.model or 'UNKNOWN')
            table.insert(options, {
                title = ('%s - %s'):format(displayName, vehicle.plate),
                description = 'Klikni za postavljanje na prodaju',
                onSelect = function()
                    SelectParkingSpot({ plate = vehicle.plate }, vehicleProps)
                end
            })
        end

        lib.registerContext({ id = 'sell_vehicle_menu', title = 'Odaberi vozilo za prodaju', options = options })
        lib.showContext('sell_vehicle_menu')
    end)
end

function GetFreeParkingSpots()
    local spots = GetState('parkingSpots') or {}
    local freeSpots = {}
    for i, spot in ipairs(spots) do
        if not spot.occupied then
            table.insert(freeSpots, { index = i, spot = spot })
        end
    end
    return freeSpots
end

function SelectParkingSpot(vehicleData, vehicleProps)
    local freeSpots = GetFreeParkingSpots()
    if #freeSpots == 0 then
        return lib.notify({ title = 'Autopijaca', description = 'Nema slobodnih mjesta', type = 'error' })
    end

    local options = {}
    for _, freeSpot in ipairs(freeSpots) do
        table.insert(options, {
            title = ('Parking mjesto %d'):format(freeSpot.index),
            description = ('Cijena parkinga: $%s'):format(ESX.Math.GroupDigits(Config.ParkingPrice)),
            metadata = {{ label = 'Pozicija', value = string.format('X: %.1f, Y: %.1f', freeSpot.spot.coords.x, freeSpot.spot.coords.y) }},
            onSelect = function()
                SetSellPrice(vehicleData, vehicleProps, freeSpot.index)
            end
        })
    end

    lib.registerContext({ id = 'select_parking_spot', title = 'Odaberi parking mjesto', options = options })
    lib.showContext('select_parking_spot')
end

function SetSellPrice(vehicleData, vehicleProps, spotIndex)
    local input = lib.inputDialog('Postavi cijenu prodaje', {
        { type = 'number', label = 'Prodajna cijena', description = 'Minimalno $1000', required = true, min = 1000, default = 10000 }
    })
    if not input then return end
    local sellPrice = tonumber(input[1])
    if not sellPrice or sellPrice < 1000 then
        return lib.notify({ title = 'Autopijaca', description = 'Cijena mora biti najmanje $1000', type = 'error' })
    end
    PreviewVehicleSale(vehicleData, vehicleProps, spotIndex, sellPrice)
end

function PreviewVehicleSale(vehicleData, vehicleProps, spotIndex, sellPrice)
    local spot = Config.MarketLocation.parkingSpots[spotIndex]
    lib.requestModel(vehicleProps.model)
    ESX.Game.SpawnVehicle(vehicleProps.model, spot.coords, spot.heading, function(vehicle)
        ESX.Game.SetVehicleProperties(vehicle, vehicleProps)
        local options = {
            {
                title = 'Potvrdi prodaju',
                description = 'Postavi vozilo na prodaju',
                onSelect = function()
                    ConfirmVehicleSale(vehicleData, spotIndex, sellPrice, vehicle)
                end
            },
            {
                title = 'Odustani',
                description = 'Poništi prodaju',
                onSelect = function()
                    ESX.Game.DeleteVehicle(vehicle)
                end
            }
        }
        lib.registerContext({ id = 'preview_vehicle_sale', title = 'Pregled vozila prije prodaje', options = options })
        lib.showContext('preview_vehicle_sale')
    end)
end

function ConfirmVehicleSale(vehicleData, spotIndex, sellPrice, vehicle)
    local vehicleProps = ESX.Game.GetVehicleProperties(vehicle)
    ESX.Game.DeleteVehicle(vehicle)
    TriggerServerEvent('autopijaca:setVehicleForSale', vehicleData.plate, spotIndex, sellPrice, vehicleProps)
end

function OpenVehicleContext(spotIndex)
    local spots = GetState('parkingSpots') or {}
    local spot = spots[spotIndex]
    if not spot or not spot.occupied then
        return lib.notify({ title = 'Autopijaca', description = 'Ovo mjesto je prazno', type = 'info' })
    end

    local options = {
        {
            title = 'Kupi vozilo',
            description = ('Cijena: $%s'):format(ESX.Math.GroupDigits(spot.price)),
            onSelect = function()
                BuyVehicle(spotIndex)
            end
        },
        {
            title = 'Pregledaj specifikacije',
            description = 'Detaljan pregled vozila',
            onSelect = function()
                ShowVehicleSpecifications(spotIndex)
            end
        }
    }
    if spot.seller == (PlayerData and PlayerData.identifier) then
        table.insert(options, 1, {
            title = 'Vrati moje vozilo',
            description = 'Ukloni vozilo sa prodaje',
            icon = 'fa-solid fa-arrow-left',
            onSelect = function()
                ReturnMyVehicle(spotIndex)
            end
        })
    end

    lib.registerContext({ id = 'vehicle_context', title = spot.vehicleLabel or 'Vozilo na prodaji', options = options })
    lib.showContext('vehicle_context')
end

function BuyVehicle(spotIndex)
    local price = (GetState('parkingSpots')[spotIndex] or {}).price or 0
    local alert = lib.alertDialog({
        header = 'Kupovina vozila',
        content = ('Želiš li kupiti ovo vozilo za $%s?'):format(ESX.Math.GroupDigits(price)),
        centered = true,
        cancel = true,
        labels = { confirm = 'Kupi', cancel = 'Odustani' }
    })
    if alert then
        TriggerServerEvent('autopijaca:buyVehicle', spotIndex)
    end
end

RegisterNetEvent('autopijaca:vehicleBought')
AddEventHandler('autopijaca:vehicleBought', function(spotIndex, vehicleProps, plate, vehicleModel)
    local spot = (GetState('parkingSpots') or {})[spotIndex]
    if spot and spawnedVehicles[spotIndex] then
        if DoesEntityExist(spawnedVehicles[spotIndex]) then ESX.Game.DeleteVehicle(spawnedVehicles[spotIndex]) end
        spawnedVehicles[spotIndex] = nil
        spawnedKeyByIndex[spotIndex] = nil
    end
    local out = Config.MarketLocation
    lib.requestModel(vehicleModel)
    ESX.Game.SpawnVehicle(vehicleModel, out.spawnCoords, out.spawnHeading or 0.0, function(vehicle)
        ESX.Game.SetVehicleProperties(vehicle, vehicleProps)
        SetVehicleNumberPlateText(vehicle, plate)
        SetVehicleDoorsLocked(vehicle, 1)
        lib.notify({ title = 'Autopijaca', description = 'Vozilo je kupljeno i spawnano ispred tebe!', type = 'success' })
    end)
end)

function ReturnMyVehicle(spotIndex)
    local alert = lib.alertDialog({ header = 'Vraćanje vozila', content = 'Želiš li vratiti ovo vozilo u garažu?', centered = true, cancel = true, labels = { confirm = 'Potvrdi', cancel = 'Odustani' } })
    if alert then TriggerServerEvent('autopijaca:returnMyVehicle', spotIndex) end
end

function ShowVehicleSpecifications(spotIndex)
    local spot = (GetState('parkingSpots') or {})[spotIndex]
    if not spot or not spot.vehicleProps then return end
    local props = spot.vehicleProps
    local options = {}

    table.insert(options, { title = 'Model vozila', description = spot.vehicleLabel or 'Nepoznato', icon = 'fa-solid fa-car' })
    table.insert(options, { title = 'Registarske tablice', description = spot.plate or 'Nepoznato', icon = 'fa-solid fa-address-card' })
    table.insert(options, { title = 'Prodavač', description = spot.sellerName or 'Nepoznato', icon = 'fa-solid fa-user' })
    table.insert(options, { title = 'Prodajna cijena', description = '$' .. ESX.Math.GroupDigits(spot.price), icon = 'fa-solid fa-tag' })

    if props.engine then
        local engineLevels = { 'Standard', 'Sport', 'Race' }
        local engineLevel = engineLevels[(props.engine or 0) + 1] or 'Standard'
        table.insert(options, { title = 'Jačina motora', description = engineLevel, icon = 'fa-solid fa-gauge-high' })
    end

    if props.brakes then
        local brakesLevels = { 'Standard', 'Sport', 'Race' }
        local brakesLevel = brakesLevels[(props.brakes or 0) + 1] or 'Standard'
        table.insert(options, { title = 'Kvalitet kočnica', description = brakesLevel, icon = 'fa-solid fa-stop' })
    end

    if props.transmission then
        local transmissionLevels = { 'Standard', 'Sport', 'Race' }
        local transmissionLevel = transmissionLevels[(props.transmission or 0) + 1] or 'Standard'
        table.insert(options, { title = 'Vrsta mjenjača', description = transmissionLevel, icon = 'fa-solid fa-gears' })
    end

    if props.suspension then
        local suspensionLevels = { 'Standard', 'Sport', 'Race' }
        local suspensionLevel = suspensionLevels[(props.suspension or 0) + 1] or 'Standard'
        table.insert(options, { title = 'Vrsta suspenzije', description = suspensionLevel, icon = 'fa-solid fa-car-side' })
    end

    if props.armor then
        local armorLevels = { 'Bez oklopa', 'Laki', 'Srednji', 'Teški', 'Max' }
        local armorLevel = armorLevels[(props.armor or 0) + 1] or 'Bez oklopa'
        table.insert(options, { title = 'Oklop', description = armorLevel, icon = 'fa-solid fa-shield' })
    end

    table.insert(options, { title = 'Turbo punjač', description = (props.turbo == 1) and 'Instaliran' or 'Nije instaliran', icon = 'fa-solid fa-gauge-high' })
    table.insert(options, { title = 'Xenon svjetla', description = (props.xenon == 1) and 'Da' or 'Ne', icon = 'fa-solid fa-lightbulb' })
    table.insert(options, { title = 'Neon svjetla', description = props.neon and 'Instalirana' or 'Nema', icon = 'fa-solid fa-lightbulb' })

    if props.color1 then table.insert(options, { title = 'Primarna boja', description = 'Prilagođena', icon = 'fa-solid fa-palette' }) end
    if props.color2 then table.insert(options, { title = 'Sekundarna boja', description = 'Prilagođena', icon = 'fa-solid fa-palette' }) end

    if props.bodyHealth then
        local healthPercent = (props.bodyHealth / 1000) * 100
        table.insert(options, { title = 'Stanje karoserije', description = string.format('%.0f%%', math.min(healthPercent, 100)), icon = 'fa-solid fa-car-side' })
    end
    if props.engineHealth then
        local enginePercent = (props.engineHealth / 1000) * 100
        table.insert(options, { title = 'Stanje motora', description = string.format('%.0f%%', math.min(enginePercent, 100)), icon = 'fa-solid fa-gears' })
    end
    if props.dirtLevel then
        local cleanliness = (1 - (props.dirtLevel / 15)) * 100
        table.insert(options, { title = 'Čistoća vozila', description = string.format('%.0f%%', math.max(cleanliness, 0)), icon = 'fa-solid fa-soap' })
    end

    local clsMap = {
        [0] = 'Kompaktni',[1] = 'Sedan',[2] = 'SUV',[3] = 'Kupe',[4] = 'Muscle',[5] = 'Sport Klasični',[6] = 'Sport',[7] = 'Super Sport',[8] = 'Motocikli',[9] = 'Off-road',[10] = 'UTV',[11] = 'Industrijski',[12] = 'Utility',[13] = 'Van',[14] = 'Ciper',[15] = 'Boat',[16] = 'Avion',[17] = 'Helikopter',[18] = 'Plovilo',[19] = 'Bicikl',[20] = 'BMX'
    }
    local vclass = GetVehicleClassFromName(spot.vehicleModel)
    table.insert(options, { title = 'Vrsta vozila', description = clsMap[vclass] or 'Nepoznato', icon = 'fa-solid fa-car' })

    lib.registerContext({ id = 'vehicle_specifications', title = 'Detaljne specifikacije vozila', menu = 'vehicle_context', options = options })
    lib.showContext('vehicle_specifications')
end

RegisterNetEvent('autopijaca:updateParkingSpots')
AddEventHandler('autopijaca:updateParkingSpots', function(spots)
    print('^3[AutoPijaca] Primio update parking spots^0')
    SetState('parkingSpots', spots or {})
    RequestSpawnReconcile()
end)

RegisterNetEvent('autopijaca:vehicleSold')
AddEventHandler('autopijaca:vehicleSold', function(spotIndex)
    local veh = spawnedVehicles[spotIndex]
    if veh and DoesEntityExist(veh) then ESX.Game.DeleteVehicle(veh) end
    spawnedVehicles[spotIndex] = nil
    spawnedKeyByIndex[spotIndex] = nil
    local spots = GetState('parkingSpots') or {}
    if spots[spotIndex] then
        spots[spotIndex].occupied = false
        spots[spotIndex].vehicleNetId = nil
        SetState('parkingSpots', spots)
    end
end)

RegisterNetEvent('autopijaca:myVehiclesUpdated')
AddEventHandler('autopijaca:myVehiclesUpdated', function()
    FetchMyListedVehicles()
end)

