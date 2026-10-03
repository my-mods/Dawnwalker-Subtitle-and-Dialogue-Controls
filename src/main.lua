-- UI and Subtitles - Configurable Font and Text Size. All engine access stays in registered game-thread callbacks.
local directory=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local cfg={enabled=1,subtitlePercent=75,dialoguePercent=100,gameplayPercent=100,fontFamily=1,uiPercent=100,uiFontFamily=2,debugLogging=0}
local warned,warningCount={},0
local function report(key,message)
    if message==nil then message=key;key=message end
    if warned[key] or warningCount>=24 then return end
    warned[key]=true;warningCount=warningCount+1
    print('[UIAndSubtitles] '..message..'\n')
end
for _,name in ipairs({'ExecuteInGameThread','ExecuteInGameThreadWithDelay','RegisterHook','StaticFindObject','FindFirstOf'})do
    if type(_G[name])~='function' then report(name,'Required UE4SS API missing: '..name);return end
end
local function valid(o)return o~=nil and o:IsValid()==true end
local function same(a,b)return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function numeric(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
-- SlateFontInfo.Size is float32; journal the same value the engine will store.
-- Comparing a Lua double target with its float32 result would scale it again.
local function fontSize(n)return string.unpack('f',string.pack('f',n))end
local names,classes,uiNames,uiOwners={},{},{},{}
local richClasses={}
local LIMIT=8192
local richReady=false
local engine,system,fontClass
local fonts,attemptedFonts,wantedFonts={},{},{}
local enqueue
local hooks,records,pending={},{},{}
local queues={{first=1,last=0,items={}},{first=1,last=0,items={}}}
local constructions={first=1,last=0,items={}}
local constructionWake=false
local worker,writing,refreshFont=false,false,false
local recordCount,uiRecordCount=0,0
local observed,observedCount={},0
local observeText
local revisiting=false
local revisitKey
local revisitPhase=1
local lastWasConstruction=false
local currentWorld
local diagnostics={jobs=0,writes=0,seconds=0,maximum=0,last=0,samples=0}
local function uiActive()return cfg.uiPercent~=100 or cfg.uiFontFamily~=2 end
local function queueEmpty()return queues[1].first>queues[1].last and queues[2].first>queues[2].last and constructions.first>constructions.last and not revisiting end
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
    if group=='uiPercent' and classId(label)~=ui[name]then return end
    if richClasses[classId(label)] and not richReady then return end
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
local function applyLabel(label)
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
    local rich=richClasses[classId(label)]
    local override=rich and label.bOverrideDefaultStyle==true
    local font=rich and (override and label.DefaultTextStyleOverride.Font or label.DefaultTextStyle.Font) or label.Font
    local size,fontObject=font.Size,font.FontObject
    if not numeric(size) or size<=0 or not valid(fontObject)then
        report('font-layout','A target widget has an unsupported font; that widget is unchanged.');return
    end
    if not record then
        local count=isUI and uiRecordCount or recordCount-uiRecordCount
        if count>=LIMIT then report(isUI and 'ui-record-limit' or 'record-limit','Target cache is full; additional widgets are unchanged until a later text event.');return end
        record={label=label,owner=owner,world=world,identity=identity,group=group,baseSize=size,baseFont=fontObject,rich=rich,baseOverride=override}
        records[address]=record;recordCount=recordCount+1
        if isUI then uiRecordCount=uiRecordCount+1 end
    else
        record.group=group
        -- Reassigning our existing result is idempotent, even through SetFont.
        if record.lastSize and size~=record.lastSize then record.baseSize=size end
        if record.lastFont and not same(fontObject,record.lastFont)then record.baseFont=fontObject end
        if not record.lastSize then record.baseSize=size end
        if not record.lastFont then record.baseFont=fontObject end
    end
    local targetSize,targetFont=size,fontObject
    if cfg.enabled==1 then
        targetSize=fontSize(math.max(6,math.min(192,math.floor(record.baseSize*cfg[group]/10+0.5)/10)))
        local family=isUI and cfg.uiFontFamily or cfg.fontFamily
        local selected=fonts[family]
        if family~=2 and not valid(selected) and not attemptedFonts[family]then
            -- Load only a font needed by an observed target, in its own worker slice.
            wantedFonts[family]=true;refreshFont=true;enqueue(label,isUI);return
        end
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
            if rich then
                label:SetDefaultFont(font)
                -- SetDefaultFont copies into the widget's override. Leave the
                -- original default style intact when it supplied the input.
                if not override then font.Size=size;font.FontObject=fontObject end
            else label:SetFont(font)end
        end)
        writing=false
        if not ok then
            font.Size=size;font.FontObject=fontObject
            pcall(function()writing=true;if rich then label:SetDefaultFont(font)else label:SetFont(font)end end);writing=false
            report('setfont','Font update failed: '..tostring(err));return
        end
        if cfg.debugLogging==1 then diagnostics.writes=diagnostics.writes+1 end
    end
    if cfg.debugLogging==1 and diagnostics.samples<8 and not record.sampled then
        diagnostics.samples=diagnostics.samples+1;record.sampled=true
        print(string.format('[UIAndSubtitles] text=%s group=%s base=%.4f target=%.4f stored=%.4f\n',identity,group,record.baseSize,targetSize,rich and label.DefaultTextStyleOverride.Font.Size or font.Size))
    end
    if cfg.enabled==1 then record.lastSize=targetSize;record.lastFont=targetFont
    else record.lastSize=nil;record.lastFont=nil end
    if isUI and (cfg.enabled~=1 or not uiActive())then removeRecord(address)end
end
local function neededFont()
    if cfg.enabled~=1 then return end
    for _,selection in ipairs({cfg.fontFamily,cfg.uiFontFamily})do
        if selection~=2 and wantedFonts[selection] and not valid(fonts[selection]) and not attemptedFonts[selection]then return selection end
    end
end
local function loadFont(selection)
    if selection==nil then return end
    attemptedFonts[selection]=true
    local family=selection==0 and 'Afacad' or 'Alegreya'
    local path='/Game/UIAndSubtitles/Fonts/UIS_'..family..'.UIS_'..family
    local start=cfg.debugLogging==1 and os.clock() or nil
    if start then print('[UIAndSubtitles] font-load begin '..family..'\n')end
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
    if start then print(string.format('[UIAndSubtitles] font-load end %s success=%s elapsed=%.3fms\n',family,tostring(ok),(os.clock()-start)*1000))end
end
local pump
local function schedule()
    if worker or constructionWake or (queueEmpty() and not refreshFont)then return end
    worker=true
    ExecuteInGameThreadWithDelay(16,pump)
end
enqueue=function(label,isUI)
    if not valid(label)then return end
    local address=label:GetAddress()
    if pending[address]then return end
    local q=queues[isUI and 2 or 1]
    if q.last-q.first+1>=LIMIT then report(isUI and 'ui-queue-limit' or 'queue-limit','Text event burst exceeds the queue budget; skipped labels retry on their next event.');return end
    local item={label=label,address=address}
    pending[address]=item;q.last=q.last+1;q.items[q.last]=item
    schedule()
end
observeText=function(label)
    if not valid(label) or label:HasAnyFlags(0x30)then return end
    local owner,world,group=classify(label)
    if not owner then return end
    if group~='uiPercent'then enqueue(label,false);return end
    local address=label:GetAddress()
    if not observed[address]then
        if observedCount>=LIMIT then report('observed-limit','Text discovery capacity exceeded. Reopen the affected screen after loading.');return end
        observedCount=observedCount+1
    end
    observed[address]={label=label,world=world}
    enqueue(label,group=='uiPercent')
end
-- Capture label creation, including native text bindings and static text. No
-- UObject access is performed by the construction callback; readiness and all
-- properties are checked in registered game-thread callbacks later.
if type(NotifyOnNewObject)=='function'then
    for _,path in ipairs({
        -- Notifications include derived classes; one registration per base avoids
        -- receiving the same DWW/CommonUI object three times during construction.
        '/Script/UMG.TextBlock','/Script/UMG.RichTextBlock',
    })do
        local ok,err=pcall(NotifyOnNewObject,path,function(label)
            if constructions.last-constructions.first+1>=LIMIT then return end
            constructions.last=constructions.last+1
            constructions.items[constructions.last]={label=label,attempt=1}
            if worker or constructionWake then return end
            constructionWake=true
            ExecuteInGameThread(function()constructionWake=false;schedule()end)
        end)
        if not ok then report('notify-'..path,'Text construction discovery unavailable: '..tostring(err))end
    end
else report('notify','Text construction notifications unavailable; text events remain active.')end
local function step()
    if refreshFont then loadFont(neededFont());refreshFont=neededFont()~=nil;return true
    elseif queues[1].first>queues[1].last and constructions.first<=constructions.last
        and (not lastWasConstruction or queues[2].first>queues[2].last)
        and (not constructions.items[constructions.first].due or constructions.items[constructions.first].due<=os.clock())then
        lastWasConstruction=true
        local item=constructions.items[constructions.first]
        constructions.items[constructions.first]=nil;constructions.first=constructions.first+1
        if constructions.first>constructions.last then constructions.first=1;constructions.last=0 end
        local ok,err=pcall(function()
            if not valid(item.label) or item.label:HasAnyFlags(0x30)then return end
            local name=item.label:GetFName():GetComparisonIndex()
            if not names[name] and not uiNames[name]then return end
            observeText(item.label)
            -- Two finite settling passes cover synchronization after creation.
            -- The engine can initialize bound/style text without a reflected event.
            if item.attempt<3 then
                item.attempt=item.attempt+1
                item.due=os.clock()+0.1
                if constructions.last-constructions.first+1<LIMIT then
                    constructions.last=constructions.last+1;constructions.items[constructions.last]=item
                end
            end
        end)
        if not ok then report('construction','Text discovery stopped: '..tostring(err))end
    elseif queues[1].first<=queues[1].last or queues[2].first<=queues[2].last then
        lastWasConstruction=false
        local q=queues[1].first<=queues[1].last and queues[1] or queues[2]
        local item=q.items[q.first];q.items[q.first]=nil;q.first=q.first+1;pending[item.address]=nil
        local ok,err=pcall(applyLabel,item.label)
        if not ok then report('widget','Widget update stopped: '..tostring(err))end
        if q.first>q.last then q.first=1;q.last=0 end
    elseif revisiting then
        local entries=revisitPhase==1 and observed or records
        local key,item=next(entries,revisitKey);revisitKey=key
        if key==nil then
            if revisitPhase==1 then revisitPhase=2 else revisiting=false end
        elseif not valid(item.label) or not same(item.world,worldNow())then
            if observed[key]then observed[key]=nil;observedCount=observedCount-1 end
            removeRecord(key)
        elseif revisitPhase==1 or item.group~='uiPercent'then enqueue(item.label,revisitPhase==1)end
    end
    return false
end
pump=function()
    local start=cfg.debugLogging==1 and os.clock() or nil
    -- Bounded work across the whole worker, with subtitle priority. Clock reads
    -- here enforce a frame budget even when optional diagnostics are disabled.
    local deadline=os.clock()+0.0005
    for _=1,8 do
        local ok,loaded=pcall(step)
        if not ok then
            report('worker','Text worker stopped this operation: '..tostring(loaded))
            revisiting=false;revisitKey=nil
            break
        end
        if loaded or queueEmpty() or os.clock()>=deadline then break end
    end
    if start then
        local elapsed=os.clock()-start
        diagnostics.jobs=diagnostics.jobs+1;diagnostics.seconds=diagnostics.seconds+elapsed;diagnostics.maximum=math.max(diagnostics.maximum,elapsed)
        if queueEmpty() and (diagnostics.last==0 or os.clock()-diagnostics.last>=30)then
            diagnostics.last=os.clock()
            print(string.format('[UIAndSubtitles] jobs=%d writes=%d total=%.3fms max=%.3fms tracked=%d discovered=%d\n',diagnostics.jobs,diagnostics.writes,diagnostics.seconds*1000,diagnostics.maximum*1000,recordCount,observedCount))
            diagnostics.jobs=0;diagnostics.writes=0;diagnostics.seconds=0;diagnostics.maximum=0
        end
    end
    worker=false;schedule()
end
local function configure(snapshot)
    local changed=false
    for key,value in pairs(snapshot)do if key~='debugLogging' and cfg[key]~=value then changed=true end;cfg[key]=value end
    if not changed then return end
    if cfg.debugLogging==1 then
        print(string.format('[UIAndSubtitles] settings enabled=%d cinematic=%d dialogue=%d gameplay=%d other-ui=%d ui-font=%d\n',cfg.enabled,cfg.subtitlePercent,cfg.dialoguePercent,cfg.gameplayPercent,cfg.uiPercent,cfg.uiFontFamily))
    end
    if cfg.enabled==1 then refreshFont=true;attemptedFonts={};wantedFonts={} end
    -- Visit cached labels incrementally; Apply cannot fill a small queue and
    -- discard the rest of a large inventory/journal screen.
    revisiting=true;revisitKey=nil;revisitPhase=1
    schedule()
end
local function install(path,signature)
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
                    observeText(label)
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
    install('/Script/UMG.TextBlock:SetText',{{'InText','TextProperty'}})
    install('/Script/UMG.TextBlock:SetFont',{{'InFontInfo','StructProperty'}})
    install('/Script/CommonUI.CommonTextBlock:SetStyle',{{'InStyle','ClassProperty'}})
    install('/Script/UMG.RichTextBlock:SetText',{{'InText','TextProperty'}})
    install('/Script/UMG.RichTextBlock:SetDefaultFont',{{'InFontInfo','StructProperty'}})
    richReady=hooks['/Script/UMG.RichTextBlock:SetDefaultFont']~=nil
end
ExecuteInGameThread(function()
    local ok,err=pcall(function()
        for _,name in ipairs({'LineLabel','NameLabel','SubtitleLabel','ChoiceLabel','QuantityLabel'})do names[FName(name):GetComparisonIndex()]=name end
        for _,name in ipairs({'DWW_RichText_C','RichTextBlock','CommonRichTextBlock'})do richClasses[FName(name):GetComparisonIndex()]=true end
        for owner,labels in pairs(require('UITargets'))do
            local allow={}
            for name,textClass in pairs(labels)do
                local id=FName(name):GetComparisonIndex();uiNames[id]=true;allow[id]=FName(textClass):GetComparisonIndex()
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
                    revisiting=true;revisitKey=nil;revisitPhase=1
                    -- A verified player lifecycle event can recover startup capabilities once.
                    if not valid(engine)then engine=FindFirstOf('Engine')end
                    if not valid(system)then system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')end
                    if not valid(fontClass)then fontClass=StaticFindObject('/Script/Engine.Font')end
                    installTextHooks()
                    attemptedFonts={};wantedFonts={};refreshFont=cfg.enabled==1
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
