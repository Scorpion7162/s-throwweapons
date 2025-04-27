fx_version 'cerulean'
game 'gta5'
author 'Scorpion'
repository 'github.com/Scorpion7162/s-throwweapons'
description 'Throw weapons in GTA V'
version '1.0.0'
use_experimental_fxv2_oal 'yes'

client_scripts {
    'client/*.lua',
}

server_scripts {
    'server/*.lua
}


shared_script '@ox_lib/init.lua'