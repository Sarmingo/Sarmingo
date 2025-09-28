Config = {}

Config.JobName = 'mehanicar'

Config.MarketLocation = {
    pedModel = `a_m_m_business_01`,
    pedCoords = vector3(-832.8216, -786.7191, 19.3840),
    pedHeading = 75.6788,

    spawnCoords = vector3(-838.3635, -789.7620, 19.3841),
    spawnHeading = 180.0,
    
    parkingSpots = {
        {
            coords = vector3(-822.2147, -805.8210, 18.7868),
            heading = 0.0
        },
        {
            coords = vector3(-818.2304, -806.1107, 18.9453),
            heading = 0.0
        }
    }
}

Config.ParkingPrice = 1000
Config.SellCommission = 0.10
Config.DaysUntilAutoReturn = 7

Config.AllowedVehicles = {
    -- 'adder', 'zentorno'
}

Config.BlockedVehicles = {
    'police', 'police2', 'ambulance', 'firetruck'
}

Config.Notifications = {
    success = { r = 0, g = 255, b = 0 },
    error = { r = 255, g = 0, b = 0 },
    info = { r = 0, g = 150, b = 255 }
}

