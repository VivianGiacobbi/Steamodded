--- STEAMODDED CORE
--- MODULE MODLOADER

-- Attempt to require nativefs
local nfs_success, nativefs = pcall(require, "nativefs")
local lovely_success, lovely = pcall(require, "lovely")

if nfs_success then
    if lovely_success then
        SMODS.MODS_DIR = lovely.mod_dir
    else
        sendErrorMessage("Error loading lovely library!", 'Loader')
        SMODS.MODS_DIR = "Mods"
    end
else
    sendErrorMessage("Error loading nativefs library!", 'Loader')
    SMODS.MODS_DIR = "Mods"
    nativefs = love.filesystem
end

NFS = nativefs

function loadMods(modsDirectory)
    SMODS.Mods = {}
    SMODS.mod_priorities = {}
    SMODS.mod_list = {}
    local header_components = {
        name          = { pattern = '%-%-%- MOD_NAME: ([^\n]+)\n', required = true },
        id            = { pattern = '%-%-%- MOD_ID: ([^ \n]+)\n', required = true },
        author        = { pattern = '%-%-%- MOD_AUTHOR: %[(.-)%]\n', required = true, parse_array = true },
        description   = { pattern = '%-%-%- MOD_DESCRIPTION: (.-)\n', required = true },
        priority      = { pattern = '%-%-%- PRIORITY: (%-?%d+)\n', handle = function(x) return x and x + 0 or 0 end },
        badge_colour  = { pattern = '%-%-%- BADGE_COLO[U]?R: (%x-)\n', handle = function(x) return HEX(x or '666666FF') end },
        display_name  = { pattern = '%-%-%- DISPLAY_NAME: (.-)\n' },
        dependencies  = {
            pattern = '%-%-%- DEPENDENCIES: %[(.-)%]\n',
            parse_array = true,
            handle = function(x)
                local t = {}
                for _, v in ipairs(x) do
                    table.insert(t, {
                        id = v:match '(.-)[<>]' or v,
                        v_geq = v:match '>=([^<>]+)',
                        v_leq = v:match '<=([^<>]+)',
                    })
                end
                return t
            end,
        },
        conflicts     = {
            pattern = '%-%-%- CONFLICTS: %[(.-)%]\n',
            parse_array = true,
            handle = function(x)
                local t = {}
                for _, v in ipairs(x) do
                    table.insert(t, {
                        id = v:match '(.-)[<>]',
                        v_geq = v:match '>=([^<>]+)',
                        v_leq = v:match '<=([^<>]+)',
                    })
                end
                return t
            end
        },
        prefix        = { pattern = '%-%-%- PREFIX: (.-)\n' },
        version       = { pattern = '%-%-%- VERSION: (.-)\n', handle = function(x) return x or '0.0.0' end },
        l_version_geq = {
            pattern = '%-%-%- LOADER_VERSION_GEQ: (.-)\n',
            handle = function(x)
                return x and x:gsub('%-STEAMODDED', '')
            end
        },
        l_version_leq = {
            pattern = '%-%-%- LOADER_VERSION_LEQ: (.-)\n',
            handle = function(x)
                return x and x:gsub('%-STEAMODDED', '')
            end
        },
        outdated      = { pattern = { 'SMODS%.INIT', 'SMODS%.Deck' } }
    }
    
    local used_prefixes = {}

    -- Function to process each directory (including subdirectories) with depth tracking
    local function processDirectory(directory, depth)
        if depth > 3 then
            return -- Stop processing if the depth is greater than 3
        end

        for _, filename in ipairs(NFS.getDirectoryItems(directory)) do
            local file_path = directory .. "/" .. filename

            -- Check if the current file is a directory
            local file_type = NFS.getInfo(file_path).type
            if file_type == 'directory' or file_type == 'symlink' then
                -- If it's a directory and depth is within limit, recursively process it
                processDirectory(file_path, depth + 1)
            elseif filename:lower():match("%.lua$") then -- Check if the file is a .lua file
                if depth == 1 then
                    sendWarnMessage(('Found lone Lua file %s in Mods directory :: Please place the files for each mod in its own subdirectory.'):format(filename))
                end
                local file_content = NFS.read(file_path)

                -- Convert CRLF in LF
                file_content = file_content:gsub("\r\n", "\n")

                -- Check the header lines using string.match
                local headerLine = file_content:match("^(.-)\n")
                if headerLine == "--- STEAMODDED HEADER" then
                    boot_print_stage('Processing Mod File: ' .. filename)
                    local mod = {}
                    local sane = true
                    for k, v in pairs(header_components) do
                        local component = nil
                        if type(v.pattern) == "table" then
                            for _, pattern in ipairs(v.pattern) do
                                component = file_content:match(pattern) or component
                                if component then break end
                            end
                        else
                            component = file_content:match(v.pattern)
                        end
                        if v.required and not component then
                            sane = false
                            sendWarnMessage(string.format('Mod file %s is missing required header component: %s',
                                filename, k))
                            break
                        end
                        if v.parse_array then
                            local list = {}
                            component = component or ''
                            for val in string.gmatch(component, "([^,]+)") do
                                table.insert(list, val:match("^%s*(.-)%s*$")) -- Trim spaces
                            end
                            component = list
                        end
                        if v.handle and type(v.handle) == 'function' then
                            component = v.handle(component)
                        end
                        mod[k] = component
                    end
                    if NFS.getInfo(directory..'/.lovelyignore') then
                        mod.disabled = true
                    end
                    if SMODS.Mods[mod.id] then
                        sane = false
                        sendWarnMessage("Duplicate Mod ID: " .. mod.id, 'Loader')
                    end
                
                    if mod.outdated then
                        mod.omit_mod_prefix = true
                    end
                    if not mod.omit_mod_prefix then
                        mod.prefix = mod.prefix or (mod.id or ''):lower():sub(1, 4)
                    end
                    if mod.prefix and used_prefixes[mod.prefix] then
                        sane = false
                        sendWarnMessage(('Duplicate Mod prefix %s used by %s, %s'):format(mod.prefix, mod.id, used_prefixes[mod.prefix]))
                    end

                    if sane then
                        boot_print_stage('Saving Mod Info: ' .. mod.id)
                        mod.path = directory .. '/'
                        mod.main_file = filename
                        mod.display_name = mod.display_name or mod.name
                        if mod.prefix then
                            used_prefixes[mod.prefix] = mod.id
                        end
                        mod.content = file_content
                        mod.optional_dependencies = {}
                        SMODS.Mods[mod.id] = mod
                        SMODS.mod_priorities[mod.priority] = SMODS.mod_priorities[mod.priority] or {}
                        table.insert(SMODS.mod_priorities[mod.priority], mod)
                    end
                elseif headerLine == '--- STEAMODDED CORE' then
                    -- save top-level directory of Steamodded installation
                    SMODS.dir = SMODS.dir or directory:match('^(.+/)')
                else
                    sendTraceMessage("Skipping non-Lua file or invalid header: " .. filename, 'Loader')
                end
            end
        end
    end

    -- Start processing with the initial directory at depth 1
    processDirectory(modsDirectory, 1)

    -- sort by priority
    local keyset = {}
    for k, _ in pairs(SMODS.mod_priorities) do
        keyset[#keyset + 1] = k
    end
    table.sort(keyset)

    local function check_dependencies(mod, seen)
        if not (mod.can_load == nil) then return mod.can_load end
        seen = seen or {}
        local can_load = true
        if seen[mod.id] then return true end
        seen[mod.id] = true
        local load_issues = {
            dependencies = {},
            conflicts = {},
        }
        for _, v in ipairs(mod.conflicts or {}) do
            -- block load even if the conflict is also blocked
            if
                SMODS.Mods[v.id] and
                (not v.v_leq or SMODS.Mods[v.id].version <= v.v_leq) and
                (not v.v_geq or SMODS.Mods[v.id].version >= v.v_geq)
            then
                can_load = false
                table.insert(load_issues.conflicts, v.id..(v.v_leq and '<='..v.v_leq or '')..(v.v_geq and '>='..v.v_geq or ''))
            end
        end
        for _, v in ipairs(mod.dependencies or {}) do
            -- recursively check dependencies of dependencies to make sure they are actually fulfilled
            if
                not SMODS.Mods[v.id] or
                not check_dependencies(SMODS.Mods[v.id], seen) or
                (v.v_leq and SMODS.Mods[v.id].version > v.v_leq) or
                (v.v_geq and SMODS.Mods[v.id].version < v.v_geq)
            then
                can_load = false
                table.insert(load_issues.dependencies,
                    v.id .. (v.v_geq and '>=' .. v.v_geq or '') .. (v.v_leq and '<=' .. v.v_leq or ''))
            end
        end
        if mod.outdated then
            load_issues.outdated = true
        end
        if mod.disabled then
            can_load = false
            load_issues.disabled = true
        end
        local loader_version = MODDED_VERSION:gsub('%-STEAMODDED', '')
        if
            (mod.l_version_geq and loader_version < mod.l_version_geq) or
            (mod.l_version_leq and loader_version > mod.l_version_geq)
        then
            can_load = false
            load_issues.version_mismatch = ''..(mod.l_version_geq and '>='..mod.l_version_geq or '')..(mod.l_version_leq and '<='..mod.l_version_leq or '')
        end
        if not can_load then
            mod.load_issues = load_issues
            return false
        end
        for _, v in ipairs(mod.dependencies) do
            SMODS.Mods[v.id].can_load = true
        end
        return true
    end

    -- load the mod files
    for _, priority in ipairs(keyset) do
        for _, mod in ipairs(SMODS.mod_priorities[priority]) do
            mod.can_load = check_dependencies(mod)
            SMODS.mod_list[#SMODS.mod_list + 1] = mod -- keep mod list in prioritized load order
            if mod.can_load then
                boot_print_stage('Loading Mod: ' .. mod.id)
                SMODS.current_mod = mod
                if mod.outdated then
                    load_compat_0_9_8()
                    assert(load(mod.content, "=[SMODS " .. mod.id .. ' "' .. mod.main_file .. '"]'))()
                    for k, v in pairs(SMODS.INIT) do
                        v()
                        SMODS.INIT[k] = nil
                        SMODS.INIT_DONE[k] = v
                    end
                else
                    assert(load(mod.content, "=[SMODS " .. mod.id .. ' "' .. mod.main_file .. '"]'))()
                end
            else
                boot_print_stage('Failed to load Mod: ' .. mod.id)
                sendWarnMessage(string.format("Mod %s was unable to load: %s%s%s", mod.id,
                    mod.load_issues.outdated and
                    'Outdated: Steamodded versions 0.9.8 and below are no longer supported!\n' or '',
                    next(mod.load_issues.dependencies) and
                    ('Missing Dependencies: ' .. inspect(mod.load_issues.dependencies) .. '\n') or '',
                    next(mod.load_issues.conflicts) and
                    ('Unresolved Conflicts: ' .. inspect(mod.load_issues.conflicts) .. '\n') or ''
                ))
            end
        end
    end
    if load_compat_0_9_8_done then
        -- Invasive change to Card:generate_UIBox_ability_table()
        local Card_generate_UIBox_ability_table_ref = Card.generate_UIBox_ability_table
        function Card:generate_UIBox_ability_table(...)
            compat_0_9_8_generate_UIBox_ability_table_card = self
            return Card_generate_UIBox_ability_table_ref(self, ...)
        end
    end
end

function SMODS.injectItems()
    SMODS.injectObjects(SMODS.GameObject)
    boot_print_stage('Initializing Localization')
    init_localization()
    SMODS.SAVE_UNLOCKS()
end

local function initializeModUIFunctions()
    for id, modInfo in pairs(SMODS.mod_list) do
        boot_print_stage("Initializing Mod UI: " .. modInfo.id)
        G.FUNCS["openModUI_" .. modInfo.id] = function(arg_736_0)
            G.ACTIVE_MOD_UI = modInfo
            G.FUNCS.overlay_menu({
                definition = create_UIBox_mods(arg_736_0)
            })
        end
    end
end

function initSteamodded()
    initGlobals()
    SMODS.current_mod = nil
    boot_print_stage("Loading APIs")
    loadAPIs()
    boot_print_stage("Loading Mods")
    loadMods(SMODS.MODS_DIR)
    initializeModUIFunctions()
    boot_print_stage("Injecting Items")
    SMODS.injectItems()
    SMODS.booted = true
end

-- re-inject on reload
local init_item_prototypes_ref = Game.init_item_prototypes
function Game:init_item_prototypes()
    init_item_prototypes_ref(self)
    if SMODS.booted then
        SMODS.injectItems()
    end
end

SMODS.booted = false
function boot_print_stage(stage)
    if not SMODS.booted then
        boot_timer(nil, "STEAMODDED - " .. stage, 0.95)
    end
end

function boot_timer(_label, _next, progress)
    progress = progress or 0
    G.LOADING = G.LOADING or {
        font = love.graphics.setNewFont("resources/fonts/m6x11plus.ttf", 20),
        love.graphics.dis
    }
    local realw, realh = love.window.getMode()
    love.graphics.setCanvas()
    love.graphics.push()
    love.graphics.setShader()
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setColor(0.6, 0.8, 0.9, 1)
    if progress > 0 then love.graphics.rectangle('fill', realw / 2 - 150, realh / 2 - 15, progress * 300, 30, 5) end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle('line', realw / 2 - 150, realh / 2 - 15, 300, 30, 5)
    love.graphics.print("LOADING: " .. _next, realw / 2 - 150, realh / 2 + 40)
    love.graphics.pop()
    love.graphics.present()

    G.ARGS.bt = G.ARGS.bt or love.timer.getTime()
    G.ARGS.bt = love.timer.getTime()
end

----------------------------------------------
------------MOD LOADER END--------------------
