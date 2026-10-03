local M={}
M.schema={
    {key='enabled',values={0,1},default=1},
    {key='subtitlePercent',min=25,max=200,integer=true,default=75},
    {key='dialoguePercent',min=25,max=200,integer=true,default=100},
    {key='gameplayPercent',min=25,max=200,integer=true,default=100},
    {key='fontFamily',values={0,1},default=1},
    {key='uiPercent',min=25,max=200,integer=true,default=100},
    {key='uiFontFamily',values={0,1,2},default=2},
    {key='debugLogging',values={0,1},default=0},
}
-- Preserve existing bytes and add only missing keys after full validation.
function M.parse(text)
    local store=require('SettingsStore')
    for _=1,3 do
        local values,err=store.parse(text,M.schema)
        if values then return values,nil,text end
        if err=='Missing setting: uiPercent' then text=text..'\n[Settings]\nuiPercent=100\n'
        elseif err=='Missing setting: uiFontFamily' then text=text..'\n[Settings]\nuiFontFamily=2\n'
        else return nil,err end
    end
end
function M.upgrade(path,original,updated)
    local store=require('SettingsStore')
    if original==updated then return true end
    if #updated>1048576 then return nil,'Updated preferences exceed 1 MiB' end
    local tmp,backup=path..'.ui-upgrade.tmp',path..'.before-ui-controls'
    for _,file in ipairs({tmp,backup})do
        local text,err,code=store.read(file)
        if text~=nil or code~=2 then return nil,'Review existing preference backup/temporary file: '..file end
    end
    local ok,err=store.create(tmp,updated)
    if not ok then return nil,err end
    if store.read(tmp)~=updated or store.read(path)~=original then
        os.remove(tmp);return nil,'Preferences changed during upgrade; retry after restarting'
    end
    ok,err=os.rename(path,backup)
    if not ok then os.remove(tmp);return nil,err end
    if store.read(backup)~=original then
        os.rename(backup,path);os.remove(tmp);return nil,'Preferences changed during upgrade; original retained'
    end
    ok,err=os.rename(tmp,path)
    if not ok then
        local restored=os.rename(backup,path)
        os.remove(tmp)
        return nil,restored and err or ('Restore preferences from '..backup..': '..tostring(err))
    end
    if store.read(path)~=updated then return nil,'Preference upgrade verification failed; backup: '..backup end
    return true
end
function M.start(directory,apply,report)
    local ids,defaults={},{}
    for _,row in ipairs(M.schema)do ids[row.key]=row.key;defaults[row.key]=row.default end
    local live=require('UE4SSDawnwalkerSettings').new({modId='UIAndSubtitles',schema=M.schema,ids=ids,report=report})
    live.attach(apply)
    local store=require('SettingsStore')
    local path=store.path(directory)
    local text=store.read(path)
    local values,err
    if text then
        local updated
        values,err,updated=M.parse(text)
        if values then
            local ok,problem=M.upgrade(path,text,updated)
            if not ok then report('settings-upgrade','UI settings could not be added: '..tostring(problem))end
        end
    else values,err=store.load(directory,M.schema,function()return defaults end)end
    if values then live.seed(values);apply(values)
    else report('settings','Settings could not be read; defaults retained: '..tostring(err)) end
    live.start(function(id,callback)return require('dmm_api').subscribe(id,callback)end)
end
return M
