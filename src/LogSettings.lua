-- Preserving, verified startup schema completion; no menu callback I/O. MIT.
local M={}
local function read(path)
    local f,e,c=io.open(path,'rb');if not f then return nil,e,c end
    local text,err=f:read(1048577);f:close()
    if not text or #text>1048576 then return nil,err or 'Settings exceed 1 MiB',-1 end
    return text
end
M.read=read
local function valid(row,value)
    if type(value)~='number' or value~=value or math.abs(value)==math.huge then return false end
    if row.values then for _,v in ipairs(row.values) do if v==value then return true end end;return false end
    return value>=row.min and value<=row.max and (not row.integer or value%1==0)
end
function M.complete(original,schema)
    local text=original
    if text:sub(1,3)=='\239\187\191' and text:sub(4):match('^%s*%[') then text='\239\187\191; UTF-8 preferences\n'..text:sub(4) end
    local present,values,section,legacy,legacyCount={},{},'',nil,0
    local known={};for _,row in ipairs(schema) do known[(row.section or 'Settings')..'/'..row.key]=row end
    for line in (text..'\n'):gmatch('(.-)\r?\n') do
        local clean=line:gsub('^\239\187\191',''):gsub('[;#].*$',''):match('^%s*(.-)%s*$')
        local header=clean:match('^%[([^%]]+)%]$')
        if header then section=header
        elseif clean~='' then
            local key,value=clean:match('^([%w_]+)%s*=%s*(.-)%s*$')
            if not key then return nil,'Malformed settings line' end
            local token=section..'/'..key
            if known[token] or ((section=='Settings' or section=='Diagnostics') and key=='debugLogging') then
                if known[token] and present[token] then return nil,'Duplicate setting: '..key end
                present[token]=true
                if known[token] then
                    value=tonumber(value)
                    if not valid(known[token],value) then return nil,'Invalid setting: '..key end
                    values[key]=value
                else legacy=value;legacyCount=legacyCount+1 end
            end
        end
    end
    if values.logLevel==nil and legacy~=nil then
        if legacyCount~=1 then return nil,'Duplicate setting: debugLogging' end
        if legacy~='0' and legacy~='1' then return nil,'Invalid setting: debugLogging' end
    end
    local newline=text:find('\r\n',1,true) and '\r\n' or '\n'
    for _,row in ipairs(schema) do
        if values[row.key]==nil then
            local value=row.default
            if row.key=='logLevel' then value=legacy=='1' and 4 or 2 end
            if not valid(row,value) then return nil,'Missing setting: '..row.key end
            if text~='' and text:sub(-1)~='\n' then text=text..newline end
            text=text..'['..(row.section or 'Settings')..']'..newline..row.key..' = '..string.format('%.17g',value)..newline
            values[row.key]=value
        end
    end
    return values,nil,text
end
local function create(path,text)
    local existing,e,c=read(path);if existing or c~=2 then return nil,e or 'Transaction file exists' end
    local f,err=io.open(path,'wb');if not f then return nil,err end
    local wrote,we=f:write(text);local closed,ce=f:close()
    if not wrote or not closed then os.remove(path);return nil,we or ce end
    if read(path)~=text then os.remove(path);return nil,'Settings write verification failed' end
    return true
end
function M.replace(path,original,updated)
    if original==updated then return true end
    local tmp,backup=path..'.log-levels.tmp',path..'.before-log-levels'
    for _,p in ipairs({tmp,backup}) do
        local text,e,c=read(p);if text or c~=2 then return nil,'Recover existing transaction file: '..p..': '..tostring(e or '') end
    end
    local ok,e=create(tmp,updated);if not ok then return nil,e end
    if read(path)~=original then os.remove(tmp);return nil,'Settings changed during upgrade' end
    if original then
        ok,e=os.rename(path,backup);if not ok then os.remove(tmp);return nil,e end
        if read(backup)~=original then os.rename(backup,path);os.remove(tmp);return nil,'Settings changed during backup' end
    end
    ok,e=os.rename(tmp,path)
    if not ok then
        local restored=not original or os.rename(backup,path)
        if restored then os.remove(tmp) end
        return nil,tostring(e)..(restored and '; original restored' or '; recover '..backup)
    end
    if read(path)~=updated then return nil,'Settings verification failed; recover '..backup end
    -- Preserve the first pre-upgrade file as a recovery copy, not a runtime input.
    return true
end
function M.load(path,schema)
    local text,e,c=read(path)
    if not text and c~=2 then return nil,e end
    local values,err,updated=M.complete(text or '',schema)
    if not values then return nil,err end
    local ok,why=M.replace(path,text,updated)
    if not ok then return nil,why end
    return values
end
-- Pinned stores reject duplicates even for obsolete keys. A valid explicit
-- logLevel retires debugLogging completely; ignore its lines only in the
-- validation view, never in the player's persisted file.
function M.validation(text)
    local section,level,count='',nil,0
    for line in (text..'\n'):gmatch('(.-)\r?\n') do
        local clean=line:gsub('^\239\187\191',''):gsub('[;#].*$','')
        local header=clean:match('^%s*%[([^%]]+)%]%s*$')
        if header then section=header
        elseif section=='Settings' then
            local value=clean:match('^%s*logLevel%s*=%s*(.-)%s*$')
            if value then count=count+1;level=tonumber(value) end
        end
    end
    if count~=1 or not level or level<0 or level>4 or level%1~=0 then return text end
    section=''
    return (text:gsub('[^\r\n]+',function(line)
        local clean=line:gsub('^\239\187\191',''):gsub('[;#].*$','')
        local header=clean:match('^%s*%[([^%]]+)%]%s*$')
        if header then section=header end
        if section=='Settings' and clean:match('^%s*debugLogging%s*=') then return '; retired logging toggle' end
        return line
    end))
end

return M
