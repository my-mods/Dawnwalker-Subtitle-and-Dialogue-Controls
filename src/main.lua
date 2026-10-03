-- Subtitle and Dialogue Controls. All engine access stays in registered game-thread callbacks.
local directory=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local cfg={enabled=1,subtitlePercent=75,dialoguePercent=100,gameplayPercent=100,fontFamily=1,uiPercent=100,uiFontFamily=2,debugLogging=0}
local warned,warningCount={},0
local function report(key,message)
    if message==nil then message=key;key=message end
    if warned[key] or warningCount>=24 then return end
    warned[key]=true;warningCount=warningCount+1
    print('[SubtitleDialogueControls] '..message..'\n')
end
for _,name in ipairs({'ExecuteInGameThread','ExecuteInGameThreadWithDelay','RegisterHook','StaticFindObject','FindFirstOf'})do
    if type(_G[name])~='function' then report(name,'Required UE4SS API missing: '..name);return end
end
local function valid(o)return o~=nil and o:IsValid()==true end
local function same(a,b)return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function numeric(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local names,classes,uiNames,uiOwners={},{},{},{}
local uiTextClassId
local engine,system,fontClass
local fonts,attemptedFonts={},{}
local hooks,records,pending={},{},{}
local queues={{first=1,last=0,items={}},{first=1,last=0,items={}}}
local worker,writing,refreshFont=false,false,false
local recordCount,uiRecordCount=0,0
local currentWorld
local diagnostics={jobs=0,writes=0,seconds=0,last=0}
local function uiActive()return cfg.uiPercent~=100 or cfg.uiFontFamily~=2 end
local function queueEmpty()return queues[1].first>queues[1].last and queues[2].first>queues[2].last end
local function worldNow()
    if not valid(engine)then return valid(currentWorld) and currentWorld or nil end
    local viewport=engine.GameViewport
    if valid(viewport)then local w=viewport:GetWorld();if valid(w)then return w end end
end
local function classId(o)return o:GetClass():GetFName():GetComparisonIndex()end
local function classify(label)
    if not valid(label) or label:HasAnyFlags(0x30) then return end -- CDO/archetype
    local name=label:GetFName():GetComparisonIndex()
    if not names[name] and not uiNames[name]then return end
    local tree=label:GetOuter()
    if not valid(tree)then return end
    local owner=tree:GetOuter()
    if not valid(owner) or owner:HasAnyFlags(0x30)then return end
    local ownerId=classId(owner)
    local kind=classes[ownerId]
    local ui=uiOwners[ownerId]
    if not kind and not (ui and ui[name])then return end
    local group
    if kind=='choice' and (names[name]=='ChoiceLabel' or names[name]=='QuantityLabel')then group='dialoguePercent'
    elseif kind=='movie' and names[name]=='SubtitleLabel'then group='subtitlePercent'
    elseif kind=='overhead' and names[name]=='SubtitleLabel'then group='gameplayPercent'
    elseif (kind=='line' or kind=='accessibility') and (names[name]=='LineLabel' or names[name]=='NameLabel')then
        if kind=='accessibility'then group='gameplayPercent'
        else
            local ancestor=owner
            for _=1,6 do
                ancestor=ancestor:GetOuter()
                if not valid(ancestor)then break end
                local parent=classes[classId(ancestor)]
                if parent=='cinematicRoot'then group='subtitlePercent';break end
                if parent=='gameplayRoot'then group='gameplayPercent';break end
            end
        end
    end
    if not group and ui and ui[name]then group='uiPercent'end
    if not group then return end
    if group=='uiPercent' and classId(label)~=uiTextClassId then return end
    local w=label:GetWorld()
    if not same(w,worldNow()) or not same(owner:GetWorld(),w)then return end
    return owner,w,group
end
local function removeRecord(address)
    if records[address]then
        if records[address].group=='uiPercent'then uiRecordCount=uiRecordCount-1 end
        records[address]=nil;recordCount=recordCount-1
    end
end
local function applyLabel(label,fresh)
    if not valid(label)then return end
    local address=label:GetAddress()
    local owner,world,group=classify(label)
    if not owner then removeRecord(address);return end
    local record=records[address]
    local identity=label:GetFullName()
    if record and (record.identity~=identity or not same(record.owner,owner) or not same(record.world,world))then
        removeRecord(address);record=nil
    end
    if cfg.enabled~=1 and not record then return end
    local isUI=group=='uiPercent'
    if isUI and not uiActive() and not record then return end
    -- Font is borrowed from the widget. Never retain this struct beyond this operation.
    local font=label.Font
    local size,fontObject=font.Size,font.FontObject
    if not numeric(size) or size<=0 or not valid(fontObject)then
        report('font-layout','A target widget has an unsupported font; that widget is unchanged.');return
    end
    if not record then
        local count=isUI and uiRecordCount or recordCount-uiRecordCount
        if count>=256 then
            for key,item in pairs(records)do
                if not valid(item.label) or not same(item.world,world)then removeRecord(key)end
            end
        end
        count=isUI and uiRecordCount or recordCount-uiRecordCount
        if count>=256 then report(isUI and 'ui-record-limit' or 'record-limit','Target cache is full; additional widgets are unchanged until a later text event.');return end
        record={label=label,owner=owner,world=world,identity=identity,group=group,baseSize=size,baseFont=fontObject}
        records[address]=record;recordCount=recordCount+1
        if isUI then uiRecordCount=uiRecordCount+1 end
    else
        record.group=group
        if fresh or (record.lastSize and size~=record.lastSize)then record.baseSize=size end
        if fresh or (record.lastFont and not same(fontObject,record.lastFont))then record.baseFont=fontObject end
        if not record.lastSize then record.baseSize=size end
        if not record.lastFont then record.baseFont=fontObject end
    end
    local targetSize,targetFont=size,fontObject
    if cfg.enabled==1 then
        targetSize=math.max(6,math.min(192,math.floor(record.baseSize*cfg[group]/10+0.5)/10))
        local family=isUI and cfg.uiFontFamily or cfg.fontFamily
        local selected=fonts[family]
        if family==2 then
            if valid(record.baseFont)then targetFont=record.baseFont end
        elseif valid(selected)then targetFont=selected end
    else
        if record.lastSize and size==record.lastSize then targetSize=record.baseSize end
        if record.lastFont and same(fontObject,record.lastFont) and valid(record.baseFont)then targetFont=record.baseFont end
    end
    if targetSize~=size or not same(targetFont,fontObject)then
        -- SetFont copies the full font, preserving typeface, outlines, spacing and materials.
        -- Its native implementation updates Slate even when the reflected property was already changed.
        writing=true
        local ok,err=pcall(function()
            font.Size=targetSize;font.FontObject=targetFont
            label:SetFont(font)
        end)
        writing=false
        if not ok then
            font.Size=size;font.FontObject=fontObject
            pcall(function()writing=true;label:SetFont(font)end);writing=false
            report('setfont','Font update failed: '..tostring(err));return
        end
        if cfg.debugLogging==1 then diagnostics.writes=diagnostics.writes+1 end
    end
    if cfg.enabled==1 then record.lastSize=targetSize;record.lastFont=targetFont
    else record.lastSize=nil;record.lastFont=nil end
    if isUI and (cfg.enabled~=1 or not uiActive())then removeRecord(address)end
end
local function neededFont()
    if cfg.enabled~=1 then return end
    for _,selection in ipairs({cfg.fontFamily,cfg.uiFontFamily})do
        if selection~=2 and not valid(fonts[selection]) and not attemptedFonts[selection]then return selection end
    end
end
local function loadFont(selection)
    if selection==nil then return end
    attemptedFonts[selection]=true
    local family=selection==0 and 'Afacad' or 'Alegreya'
    local path='/Game/SubtitleDialogueControls/Fonts/SDC_'..family..'.SDC_'..family
    local ok,result=pcall(function()
        if not valid(system) or not valid(fontClass)then error('Font loading functions or Font class unavailable')end
        -- Soft references load unique mounted packages without depending on AssetRegistry entries.
        local softPath=system:MakeSoftObjectPath(path)
        local reference=system:Conv_SoftObjPathToSoftObjRef(softPath)
        local object=system:LoadAsset_Blocking(reference)
        assert(valid(object) and object:IsA(fontClass),'Font package missing or invalid: '..family)
        return object
    end)
    if ok then fonts[selection]=result
    else report('font-'..family,'Font selection unavailable; size controls remain active. '..tostring(result))end
end
local pump
local function schedule()
    if worker or (queueEmpty() and not refreshFont)then return end
    worker=true
    ExecuteInGameThreadWithDelay(16,pump)
end
local function enqueue(label,fresh,isUI)
    if not valid(label)then return end
    local address=label:GetAddress()
    if pending[address]then pending[address].fresh=pending[address].fresh or fresh;return end
    local q=queues[isUI and 2 or 1]
    if q.last-q.first+1>=256 then report(isUI and 'ui-queue-limit' or 'queue-limit','Text event burst exceeds the queue budget; skipped labels retry on their next event.');return end
    local item={label=label,fresh=fresh,address=address}
    pending[address]=item;q.last=q.last+1;q.items[q.last]=item
    schedule()
end
pump=function()
    worker=false
    local start=cfg.debugLogging==1 and os.clock() or nil
    -- At most one asset load OR one label operation in each later-frame callback.
    if refreshFont then loadFont(neededFont());refreshFont=neededFont()~=nil
    elseif not queueEmpty() then
        -- Menu bursts have a separate budget and cannot fill the subtitle queue.
        local q=queues[1].first<=queues[1].last and queues[1] or queues[2]
        local item=q.items[q.first];q.items[q.first]=nil;q.first=q.first+1
        pending[item.address]=nil
        if valid(item.label)then
            local ok,err=pcall(applyLabel,item.label,item.fresh)
            if not ok then report('widget','Widget update stopped: '..tostring(err))end
        else
            removeRecord(item.address)
        end
        if q.first>q.last then q.first=1;q.last=0 end
    end
    if start then
        diagnostics.jobs=diagnostics.jobs+1;diagnostics.seconds=diagnostics.seconds+os.clock()-start
        if queueEmpty() and (diagnostics.last==0 or os.clock()-diagnostics.last>=30)then
            diagnostics.last=os.clock()
            print(string.format('[SubtitleDialogueControls] jobs=%d writes=%d total=%.3fms tracked=%d\n',diagnostics.jobs,diagnostics.writes,diagnostics.seconds*1000,recordCount))
            diagnostics.jobs=0;diagnostics.writes=0;diagnostics.seconds=0
        end
    end
    schedule()
end
local function configure(snapshot)
    local changed=false
    for key,value in pairs(snapshot)do if key~='debugLogging' and cfg[key]~=value then changed=true end;cfg[key]=value end
    if not changed then return end
    if cfg.enabled==1 then refreshFont=true;attemptedFonts={} end
    for _,record in pairs(records)do enqueue(record.label,false,record.group=='uiPercent')end
    schedule()
end
local function install(path,signature,fresh)
    if hooks[path]then return end
    local ok,err=pcall(function()
        local fn=StaticFindObject(path);assert(valid(fn),'function missing')
        local i=0
        fn:ForEachProperty(function(p)
            i=i+1;local expected=signature[i]
            assert(expected and p:GetFName():ToString()==expected[1] and p:GetFullName():match('^(%S+)')==expected[2],'function signature changed')
        end)
        assert(i==#signature,'incomplete signature')
        local a,b=RegisterHook(path,function()end,function(context)
            if writing or cfg.enabled~=1 then return end
            local success,problem=pcall(function()
                local label=context:get()
                -- FName indices reject unrelated text before any tree traversal or string building.
                if not valid(label)then return end
                local name=label:GetFName():GetComparisonIndex()
                if names[name] or (uiActive() and uiNames[name])then
                    for _,family in ipairs({cfg.fontFamily,cfg.uiFontFamily})do
                        if fonts[family] and not valid(fonts[family])then
                            fonts[family]=nil;attemptedFonts[family]=nil;refreshFont=true
                        end
                    end
                    local isUI=not names[name]
                    if names[name] and uiNames[name]then
                        local tree=label:GetOuter()
                        local owner=valid(tree) and tree:GetOuter() or nil
                        local allow=valid(owner) and uiOwners[classId(owner)] or nil
                        isUI=allow and allow[name] or false
                    end
                    enqueue(label,fresh,isUI)
                end
            end)
            if not success then report(path,'Text event failed: '..tostring(problem))end
        end)
        assert(type(a)=='number' and type(b)=='number' and a>0 and b>0,'hook registration failed')
        hooks[path]={a,b}
    end)
    if not ok then report(path,'Text event unavailable ('..path..'): '..tostring(err))end
end
local function installTextHooks()
    install('/Script/UMG.TextBlock:SetText',{{'InText','TextProperty'}},false)
    install('/Script/UMG.TextBlock:SetFont',{{'InFontInfo','StructProperty'}},true)
    install('/Script/CommonUI.CommonTextBlock:SetStyle',{{'InStyle','ClassProperty'}},false)
end
ExecuteInGameThread(function()
    local ok,err=pcall(function()
        for _,name in ipairs({'LineLabel','NameLabel','SubtitleLabel','ChoiceLabel','QuantityLabel'})do names[FName(name):GetComparisonIndex()]=name end
        uiTextClassId=FName('DWW_Text_C'):GetComparisonIndex()
        for owner,labels in pairs(require('UITargets'))do
            local allow={}
            for _,name in ipairs(labels)do
                local id=FName(name):GetComparisonIndex();uiNames[id]=true;allow[id]=true
            end
            uiOwners[FName(owner):GetComparisonIndex()]=allow
        end
        for name,kind in pairs({WBP_Dialogue_Line_C='line',WBP_Accessibility_Dialogue_Line_C='accessibility',WBP_MovieSubtitle_C='movie',WBP_GameplayDialogue_OverheadSubtitle_C='overhead',WBP_Dialogue_ChoiceBox_Line_C='choice',WBP_Dialogue_ChoiceBox_Line_Shrine_C='choice',WBP_Dialogue_C='cinematicRoot',WBP_Dialogue_Shrine_C='cinematicRoot',WBP_GameplayDialogue_HUD_C='gameplayRoot'})do classes[FName(name):GetComparisonIndex()]=kind end
        engine=FindFirstOf('Engine')
        system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
        fontClass=StaticFindObject('/Script/Engine.Font')
        require('Settings').start(directory,configure,report)
        installTextHooks()
        local success,problem=pcall(function()
            local a,b=RegisterHook('/Script/Engine.PlayerController:ClientRestart',function()end,function(context)
                local recovered,failure=pcall(function()
                    local pc=context:get()
                    if not valid(pc) or pc:IsLocalController()~=true then return end
                    currentWorld=pc:GetWorld()
                    -- A verified player lifecycle event can recover startup capabilities once.
                    if not valid(engine)then engine=FindFirstOf('Engine')end
                    if not valid(system)then system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')end
                    if not valid(fontClass)then fontClass=StaticFindObject('/Script/Engine.Font')end
                    installTextHooks()
                    attemptedFonts={};refreshFont=cfg.enabled==1
                    for key,record in pairs(records)do
                        if not valid(record.label) or not same(record.world,currentWorld)then removeRecord(key)
                        else enqueue(record.label,false,record.group=='uiPercent')end
                    end
                    schedule()
                end)
                if not recovered then report('restart-event','Player lifecycle recovery stopped: '..tostring(failure))end
            end)
            assert(type(a)=='number' and type(b)=='number' and a>0 and b>0,'restart hook failed')
            hooks.restart={a,b}
        end)
        if not success then report('restart','Player lifecycle recovery unavailable: '..tostring(problem))end
        refreshFont=cfg.enabled==1;schedule()
    end)
    if not ok then report('startup','Startup stopped: '..tostring(err))end
end)
