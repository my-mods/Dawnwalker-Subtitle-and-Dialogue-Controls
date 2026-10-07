local M={}
M.schema={
    {key='enabled',values={0,1},default=1},
    {key='subtitlePercent',min=25,max=200,integer=true,default=75},
    {key='dialoguePercent',min=25,max=200,integer=true,default=100},
    {key='gameplayPercent',min=25,max=200,integer=true,default=100},
    {key='fontFamily',values={0,1},default=1},
    {key='uiPercent',min=25,max=200,integer=true,default=100},
    {key='uiFontFamily',values={0,1,2},default=2},
    {key='logLevel',values={0,1,2,3,4},default=2},
}
function M.parse(text) return require('LogSettings').complete(text,M.schema) end
function M.upgrade(path,original,updated) return require('LogSettings').replace(path,original,updated) end
function M.start(directory,apply,report)
    local ids,defaults={},{}
    for _,row in ipairs(M.schema)do ids[row.key]=row.key;defaults[row.key]=row.default end
    local live=require('UE4SSDawnwalkerSettings').new({modId='UIAndSubtitles',schema=M.schema,ids=ids,report=report})
    live.attach(function(values) require('ModLog').setLevel(values.logLevel);apply(values) end)
    local store=require('SettingsStore')
    local path=store.path(directory)
    local values,err=require('LogSettings').load(path,M.schema)
    if values then require('ModLog').setLevel(values.logLevel);live.seed(values);apply(values)
    else report('settings','Settings could not be read; defaults retained: '..tostring(err)) end
    live.start(function(id,callback)return require('ModLog').subscribe(directory,id,callback)end)
end
return M
