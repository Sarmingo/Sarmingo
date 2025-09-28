ESX = exports['es_extended']:getSharedObject()

local ServerState = {
    parkingSpots = {},
    isInitialized = false
}

local function SetServerState(key, value)
    ServerState[key] = value
    if key == 'parkingSpots' then
        TriggerClientEvent('autopijaca:updateParkingSpots', -1, value)
    end
end

local function GetServerState(key)
    return ServerState[key]
end

CreateThread(function()
    while not ESX do
        Wait(100)
    end

    InitializeDatabase()
    LoadParkingSpotsFromDB()
    SetServerState('isInitialized', true)
    print('^2[AutoPijaca] Server system initialized^0')

    -- Delay migration a bit so table exists for sure
    Wait(3000)
    MigrateExistingData()
end)

function InitializeDatabase()
    MySQL.Async.execute([[ 
        CREATE TABLE IF NOT EXISTS `autopijaca_vehicles` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `spot_index` INT NOT NULL,
            `seller_identifier` VARCHAR(255) NOT NULL,
            `seller_name` VARCHAR(255) NOT NULL,
            `vehicle_plate` VARCHAR(12) NOT NULL,
            `vehicle_model` VARCHAR(50) NOT NULL,
            `vehicle_props` LONGTEXT NOT NULL,
            `sell_price` INT NOT NULL,
            `vehicle_label` VARCHAR(255) NOT NULL,
            `parking_price` INT NOT NULL,
            `lambrachip` INT DEFAULT 0,
            `lambranitro` INT DEFAULT 0,
            `listed_date` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY `unique_spot` (`spot_index`)
        )
    ]])
end

function LoadParkingSpotsFromDB()
    local spots = {}
    for i = 1, #Config.MarketLocation.parkingSpots do
        spots[i] = {
            coords = Config.MarketLocation.parkingSpots[i].coords,
            heading = Config.MarketLocation.parkingSpots[i].heading,
            occupied = false,
            vehicleNetId = nil,
            seller = nil,
            sellerName = nil,
            plate = nil,
            price = 0,
            vehicleProps = nil,
            vehicleModel = nil,
            vehicleLabel = nil,
            dbId = nil,
            lambrachip = 0,
            lambranitro = 0
        }
    end

    MySQL.Async.fetchAll('SELECT * FROM autopijaca_vehicles', {}, function(results)
        if results then
            for _, vehicleData in ipairs(results) do
                local idx = vehicleData.spot_index
                if spots[idx] then
                    spots[idx].occupied = true
                    spots[idx].seller = vehicleData.seller_identifier
                    spots[idx].sellerName = vehicleData.seller_name
                    spots[idx].plate = vehicleData.vehicle_plate
                    spots[idx].price = vehicleData.sell_price
                    spots[idx].vehicleProps = json.decode(vehicleData.vehicle_props)
                    spots[idx].vehicleModel = vehicleData.vehicle_model
                    spots[idx].vehicleLabel = vehicleData.vehicle_label
                    spots[idx].dbId = vehicleData.id
                    spots[idx].lambrachip = vehicleData.lambrachip or 0
                    spots[idx].lambranitro = vehicleData.lambranitro or 0
                end
            end
        end

        SetServerState('parkingSpots', spots)
        CheckAutoReturn()
    end)
end

function CheckAutoReturn()
    local cutoffDate = os.date('%Y-%m-%d %H:%M:%S', os.time() - (Config.DaysUntilAutoReturn * 24 * 60 * 60))
    MySQL.Async.fetchAll('SELECT * FROM autopijaca_vehicles WHERE listed_date < @cutoff', {
        ['@cutoff'] = cutoffDate
    }, function(oldVehicles)
        if oldVehicles then
            for _, oldVehicle in ipairs(oldVehicles) do
                ReturnVehicleToSeller(oldVehicle, true)
            end
        end
    end)
end

function ReturnVehicleToSeller(vehicleData, isAutoReturn)
    local vehicleProps = json.decode(vehicleData.vehicle_props) or {}
    vehicleProps.lambrachip = vehicleData.lambrachip or 0
    vehicleProps.lambranitro = vehicleData.lambranitro or 0

    MySQL.Async.execute('INSERT INTO owned_vehicles (owner, plate, vehicle, stored) VALUES (@owner, @plate, @vehicle, 1)', {
        ['@owner'] = vehicleData.seller_identifier,
        ['@plate'] = vehicleData.vehicle_plate,
        ['@vehicle'] = json.encode(vehicleProps)
    })

    MySQL.Async.execute('DELETE FROM autopijaca_vehicles WHERE id = @id', {
        ['@id'] = vehicleData.id
    })

    local spots = GetServerState('parkingSpots')
    if spots[vehicleData.spot_index] then
        spots[vehicleData.spot_index].occupied = false
        spots[vehicleData.spot_index].seller = nil
        spots[vehicleData.spot_index].sellerName = nil
        spots[vehicleData.spot_index].plate = nil
        spots[vehicleData.spot_index].price = 0
        spots[vehicleData.spot_index].vehicleProps = nil
        spots[vehicleData.spot_index].vehicleModel = nil
        spots[vehicleData.spot_index].vehicleLabel = nil
        spots[vehicleData.spot_index].dbId = nil
        spots[vehicleData.spot_index].lambrachip = 0
        spots[vehicleData.spot_index].lambranitro = 0
        SetServerState('parkingSpots', spots)
    end

    local xSeller = ESX.GetPlayerFromIdentifier(vehicleData.seller_identifier)
    if xSeller then
        local message = isAutoReturn and 
            ('Tvoje vozilo je vraćeno u garažu jer nije prodano u roku od %d dana'):format(Config.DaysUntilAutoReturn) or
            'Vratio si vozilo iz autopijace u garažu'
        TriggerClientEvent('ox_lib:notify', xSeller.source, {
            title = 'Autopijaca',
            description = message,
            type = isAutoReturn and 'inform' or 'success'
        })
        TriggerClientEvent('autopijaca:myVehiclesUpdated', xSeller.source)
    end

    TriggerClientEvent('autopijaca:vehicleSold', -1, vehicleData.spot_index)
end

ESX.RegisterServerCallback('autopijaca:getParkingSpots', function(source, cb)
    cb(GetServerState('parkingSpots') or {})
end)

ESX.RegisterServerCallback('autopijaca:getPlayerVehicles', function(source, cb)
    local xPlayer = ESX.GetPlayerFromId(source)
    MySQL.Async.fetchAll('SELECT plate, vehicle FROM owned_vehicles WHERE owner = @owner AND stored = 1', {
        ['@owner'] = xPlayer.identifier
    }, function(result)
        cb(result or {})
    end)
end)

local function computeDaysLeft(listedDateStr)
    -- listedDateStr format from MySQL TIMESTAMP: 'YYYY-MM-DD HH:MM:SS'
    local pattern = '(%d+)%-(%d+)%-(%d+)%s+(%d+):(%d+):(%d+)'
    local y, m, d, H, M, S = listedDateStr:match(pattern)
    if not y then return Config.DaysUntilAutoReturn end
    local listedTs = os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(H), min = tonumber(M), sec = tonumber(S)})
    local diffDays = math.floor((os.time() - listedTs) / (24 * 60 * 60))
    local left = Config.DaysUntilAutoReturn - diffDays
    if left < 0 then left = 0 end
    return left
end

ESX.RegisterServerCallback('autopijaca:getMyListedVehicles', function(source, cb)
    local xPlayer = ESX.GetPlayerFromId(source)
    MySQL.Async.fetchAll('SELECT * FROM autopijaca_vehicles WHERE seller_identifier = @seller', {
        ['@seller'] = xPlayer.identifier
    }, function(result)
        if not result then return cb({}) end
        for i = 1, #result do
            result[i].daysLeft = computeDaysLeft(result[i].listed_date)
        end
        cb(result)
    end)
end)

RegisterNetEvent('autopijaca:setVehicleForSale')
AddEventHandler('autopijaca:setVehicleForSale', function(plate, spotIndex, price, vehicleProps)
    local src = source
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end

    local spots = GetServerState('parkingSpots')
    if not spots[spotIndex] or spots[spotIndex].occupied then
        return TriggerClientEvent('ox_lib:notify', src, { title = 'Greška', description = 'Mjesto je već zauzeto', type = 'error' })
    end

    -- Blocked/allowed check
    local model = vehicleProps and vehicleProps.model
    if model and Config.BlockedVehicles then
        for _, blocked in ipairs(Config.BlockedVehicles) do
            if tostring(blocked) == tostring(model) then
                return TriggerClientEvent('ox_lib:notify', src, { title = 'Greška', description = 'Ovo vozilo nije dozvoljeno za prodaju', type = 'error' })
            end
        end
    end
    if model and Config.AllowedVehicles and #Config.AllowedVehicles > 0 then
        local allowed = false
        for _, allow in ipairs(Config.AllowedVehicles) do
            if tostring(allow) == tostring(model) then
                allowed = true
                break
            end
        end
        if not allowed then
            return TriggerClientEvent('ox_lib:notify', src, { title = 'Greška', description = 'Ovo vozilo nije dozvoljeno za prodaju', type = 'error' })
        end
    end

    MySQL.Async.fetchScalar('SELECT 1 FROM owned_vehicles WHERE owner = @owner AND plate = @plate', {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = plate
    }, function(exists)
        if not exists then
            return TriggerClientEvent('ox_lib:notify', src, { title = 'Greška', description = 'Ne posjeduješ ovo vozilo', type = 'error' })
        end

        if xPlayer.getMoney() >= Config.ParkingPrice then
            xPlayer.removeMoney(Config.ParkingPrice)
        else
            return TriggerClientEvent('ox_lib:notify', src, { title = 'Greška', description = 'Nemaš dovoljno novca za parking', type = 'error' })
        end

        local lambrachip = vehicleProps.lambrachip or 0
        local lambranitro = vehicleProps.lambranitro or 0

        MySQL.Async.execute([[ 
            INSERT INTO autopijaca_vehicles 
            (spot_index, seller_identifier, seller_name, vehicle_plate, vehicle_model, vehicle_props, sell_price, vehicle_label, parking_price, lambrachip, lambranitro)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], {
            spotIndex, xPlayer.identifier, xPlayer.getName(), plate, vehicleProps.model, 
            json.encode(vehicleProps), price, vehicleProps.model, Config.ParkingPrice, lambrachip, lambranitro
        }, function(rowsChanged)
            if not rowsChanged or rowsChanged < 1 then
                return TriggerClientEvent('ox_lib:notify', src, { title = 'Greška', description = 'Ne mogu postaviti vozilo na prodaju (DB greška)', type = 'error' })
            end

            MySQL.Async.fetchScalar('SELECT id FROM autopijaca_vehicles WHERE spot_index = @spot', { ['@spot'] = spotIndex }, function(insertId)
                spots[spotIndex].occupied = true
                spots[spotIndex].seller = xPlayer.identifier
                spots[spotIndex].sellerName = xPlayer.getName()
                spots[spotIndex].plate = plate
                spots[spotIndex].price = price
                spots[spotIndex].vehicleProps = vehicleProps
                spots[spotIndex].vehicleModel = vehicleProps.model
                spots[spotIndex].vehicleLabel = vehicleProps.model
                spots[spotIndex].dbId = insertId
                spots[spotIndex].lambrachip = lambrachip
                spots[spotIndex].lambranitro = lambranitro
                SetServerState('parkingSpots', spots)

                MySQL.Async.execute('DELETE FROM owned_vehicles WHERE plate = @plate AND owner = @owner', {
                    ['@plate'] = plate,
                    ['@owner'] = xPlayer.identifier
                })

                TriggerClientEvent('ox_lib:notify', src, { title = 'Autopijaca', description = 'Vozilo postavljeno na prodaju!', type = 'success' })
                TriggerClientEvent('autopijaca:myVehiclesUpdated', src)
            end)
        end)
    end)
end)

RegisterNetEvent('autopijaca:buyVehicle')
AddEventHandler('autopijaca:buyVehicle', function(spotIndex)
    local src = source
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end

    local spots = GetServerState('parkingSpots')
    local spot = spots[spotIndex]
    if not spot or not spot.occupied then
        return TriggerClientEvent('ox_lib:notify', src, { title = 'Greška', description = 'Vozilo nije dostupno', type = 'error' })
    end
    if spot.seller == xPlayer.identifier then
        return TriggerClientEvent('ox_lib:notify', src, { title = 'Autopijaca', description = 'Ne možeš kupiti vlastito vozilo', type = 'error' })
    end

    if xPlayer.getMoney() < spot.price then
        return TriggerClientEvent('ox_lib:notify', src, { title = 'Autopijaca', description = 'Nemaš dovoljno novca za ovo vozilo', type = 'error' })
    end

    xPlayer.removeMoney(spot.price)

    local vehicleProps = spot.vehicleProps or {}
    vehicleProps.lambrachip = spot.lambrachip or 0
    vehicleProps.lambranitro = spot.lambranitro or 0

    MySQL.Async.execute('INSERT INTO owned_vehicles (owner, plate, vehicle, stored) VALUES (@owner, @plate, @vehicle, 0)', {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = spot.plate,
        ['@vehicle'] = json.encode(vehicleProps)
    })

    local sellerMoney = math.floor(spot.price * (1 - Config.SellCommission))
    local xSeller = ESX.GetPlayerFromIdentifier(spot.seller)
    if xSeller then
        xSeller.addMoney(sellerMoney)
        TriggerClientEvent('ox_lib:notify', xSeller.source, {
            title = 'Autopijaca',
            description = 'Tvoje vozilo je prodano za $' .. ESX.Math.GroupDigits(sellerMoney),
            type = 'success'
        })
        TriggerClientEvent('autopijaca:myVehiclesUpdated', xSeller.source)
    else
        MySQL.Async.execute('UPDATE users SET bank = bank + @money WHERE identifier = @identifier', {
            ['@money'] = sellerMoney,
            ['@identifier'] = spot.seller
        })
    end

    MySQL.Async.execute('DELETE FROM autopijaca_vehicles WHERE spot_index = @spot', {
        ['@spot'] = spotIndex
    })

    TriggerClientEvent('autopijaca:vehicleBought', src, spotIndex, vehicleProps, spot.plate, spot.vehicleModel)

    spots[spotIndex].occupied = false
    spots[spotIndex].seller = nil
    spots[spotIndex].sellerName = nil
    spots[spotIndex].plate = nil
    spots[spotIndex].price = 0
    spots[spotIndex].vehicleProps = nil
    spots[spotIndex].vehicleModel = nil
    spots[spotIndex].vehicleLabel = nil
    spots[spotIndex].dbId = nil
    spots[spotIndex].lambrachip = 0
    spots[spotIndex].lambranitro = 0
    SetServerState('parkingSpots', spots)

    TriggerClientEvent('autopijaca:vehicleSold', -1, spotIndex)
end)

RegisterNetEvent('autopijaca:returnMyVehicle')
AddEventHandler('autopijaca:returnMyVehicle', function(spotIndex)
    local src = source
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end
    local spots = GetServerState('parkingSpots')
    local spot = spots[spotIndex]
    if not spot or not spot.occupied or spot.seller ~= xPlayer.identifier then
        return TriggerClientEvent('ox_lib:notify', src, { title = 'Autopijaca', description = 'Ovo nije tvoje vozilo ili mjesto je prazno', type = 'error' })
    end

    MySQL.Async.fetchAll('SELECT * FROM autopijaca_vehicles WHERE spot_index = @spot AND seller_identifier = @seller', {
        ['@spot'] = spotIndex,
        ['@seller'] = xPlayer.identifier
    }, function(rows)
        if rows and rows[1] then
            ReturnVehicleToSeller(rows[1], false)
        end
    end)
end)

RegisterNetEvent('autopijaca:updateVehicleMods')
AddEventHandler('autopijaca:updateVehicleMods', function(plate, mods)
    local src = source
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end

    MySQL.Async.execute('UPDATE owned_vehicles SET vehicle = @vehicle WHERE plate = @plate AND owner = @owner', {
        ['@vehicle'] = json.encode(mods),
        ['@plate'] = plate,
        ['@owner'] = xPlayer.identifier
    })

    MySQL.Async.execute('UPDATE autopijaca_vehicles SET vehicle_props = @vehicle, lambrachip = @lambrachip, lambranitro = @lambranitro WHERE vehicle_plate = @plate AND seller_identifier = @seller', {
        ['@vehicle'] = json.encode(mods),
        ['@lambrachip'] = mods.lambrachip or 0,
        ['@lambranitro'] = mods.lambranitro or 0,
        ['@plate'] = plate,
        ['@seller'] = xPlayer.identifier
    })

    local spots = GetServerState('parkingSpots')
    for i, spot in ipairs(spots) do
        if spot.occupied and spot.plate == plate and spot.seller == xPlayer.identifier then
            spots[i].vehicleProps = mods
            spots[i].lambrachip = mods.lambrachip or 0
            spots[i].lambranitro = mods.lambranitro or 0
            SetServerState('parkingSpots', spots)
            break
        end
    end
end)

function MigrateExistingData()
    MySQL.Async.fetchAll('SELECT * FROM autopijaca_vehicles WHERE lambrachip IS NULL OR lambranitro IS NULL', {}, function(vehicles)
        if vehicles and #vehicles > 0 then
            print(('^3[AutoPijaca] Pokrećem migraciju za %d vozila^0'):format(#vehicles))
            for _, vehicle in ipairs(vehicles) do
                local vehicleProps = json.decode(vehicle.vehicle_props) or {}
                local lambrachip = vehicleProps.lambrachip or 0
                local lambranitro = vehicleProps.lambranitro or 0
                MySQL.Async.execute('UPDATE autopijaca_vehicles SET lambrachip = @lambrachip, lambranitro = @lambranitro WHERE id = @id', {
                    ['@lambrachip'] = lambrachip,
                    ['@lambranitro'] = lambranitro,
                    ['@id'] = vehicle.id
                })
            end
            print('^2[AutoPijaca] Migracija podataka završena^0')
        else
            print('^2[AutoPijaca] Nema podataka za migraciju^0')
        end
    end)
end

RegisterCommand('refresh_autopijaca', function(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if xPlayer and xPlayer.getGroup and xPlayer.getGroup() == 'vlasnik' then
        LoadParkingSpotsFromDB()
        TriggerClientEvent('ox_lib:notify', source, { title = 'Autopijaca', description = 'Autopijaca je osvježena', type = 'success' })
    else
        TriggerClientEvent('ox_lib:notify', source, { title = 'Autopijaca', description = 'Nemaš ovlaštenje za ovu komandu', type = 'error' })
    end
end, false)

