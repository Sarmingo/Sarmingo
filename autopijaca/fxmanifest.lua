fx_version 'cerulean'
game 'gta5'

lua54 'yes'

author 'AutoPijaca by Assistant'
description 'Marketplace for vehicles with server-managed state and idempotent spawns'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

server_scripts {
    '@mysql-async/lib/MySQL.lua',
    'server.lua'
}

client_scripts {
    'client.lua'
}

