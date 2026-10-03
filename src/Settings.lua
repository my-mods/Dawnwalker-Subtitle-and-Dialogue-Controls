local M={}
M.schema={
    {key='enabled',values={0,1},default=1},
    {key='subtitlePercent',min=25,max=200,integer=true,default=75},
    {key='dialoguePercent',min=25,max=200,integer=true,default=100},
    {key='gameplayPercent',min=25,max=200,integer=true,default=100},
    {key='fontFamily',values={0,1},default=1},
    {key='debugLogging',values={0,1},default=0},
}
function M.start(directory,apply,report)
    local ids,defaults={},{}
    for _,row in ipairs(M.schema)do ids[row.key]=row.key;defaults[row.key]=row.default end
    local live=require('UE4SSDawnwalkerSettings').new({modId='SubtitleDialogueControls',schema=M.schema,ids=ids,report=report})
    live.attach(apply)
    local values,err=require('SettingsStore').load(directory,M.schema,function()return defaults end)
    if values then live.seed(values);apply(values)
    else report('settings','Settings could not be read; defaults retained: '..tostring(err)) end
    live.start(function(id,callback)return require('dmm_api').subscribe(id,callback)end)
end
return M
