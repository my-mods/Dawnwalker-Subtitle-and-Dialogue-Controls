-- Mod-local severity adapter. Pinned shared libraries remain unchanged. MIT.
local Levels=require('LogLevels')
local M={}
local level=Levels.DEFAULT
function M.level() return level end
function M.setLevel(value) if Levels.valid(value) then level=value end end
function M.allows(value) return level>=value end
local function emit(severity,message,...)
    if level<severity then return end
    local text=tostring(message)
    if select('#',...)>0 then local ok,result=pcall(string.format,text,...);if ok then text=result end end
    print('[UIAndSubtitles]['..Levels.tags[severity]..'] '..text:gsub('[\r\n]+$','')..'\n')
end
function M.error(message,...) emit(Levels.ERROR,message,...) end
function M.warning(message,...) emit(Levels.WARNING,message,...) end
function M.info(message,...) emit(Levels.INFO,message,...) end
function M.debug(message,...) emit(Levels.DEBUG,message,...) end
-- Read only at startup, before capability checks, so explicit Off also silences
-- failures that occur before the full preferences can be accepted.
function M.initialize(directory,filename,section)
    local f=io.open(directory..'../'..(filename or 'settings.ini'),'rb')
    if not f then return end
    local text=f:read(1048577);f:close()
    if type(text)~='string' or #text>1048576 then return end
    local current,legacy,where
    for line in (text..'\n'):gmatch('(.-)\r?\n') do
        line=line:gsub('^\239\187\191',''):gsub('[;#].*$','')
        local header=line:match('^%s*%[([^%]]+)%]%s*$')
        if header then where=header
        elseif where==(section or 'Settings') then
            local key,value=line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
            if key=='logLevel' and Levels.valid(tonumber(value)) then current=tonumber(value)
            elseif key=='debugLogging' then legacy=tonumber(value) end
        end
    end
    M.setLevel(current or Levels.fromLegacyToggle(legacy))
end
-- Isolate output from vendored modules without patching their pinned bytes or
-- changing the global print function used by the loader and other mods.
function M.dependency(directory,name,severity)
    local env=setmetatable({print=function(message) emit(severity or Levels.WARNING,message) end},{__index=_G})
    return assert(loadfile(directory..name..'.lua','t',env))()
end
function M.subscribe(directory,id,callback)
    if not M.api then M.api=M.dependency(directory,'dmm_api',Levels.ERROR) end
    return M.api.subscribe(id,callback)
end
return M
