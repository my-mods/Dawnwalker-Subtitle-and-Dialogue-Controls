-- Menu text inherits persistent class styles and widget-tree defaults.
-- Construction notifications only retain wrappers for the next explicit Apply;
-- they never schedule work, read widget properties or write a font.
local M={}
local function valid(o)return o~=nil and o:IsValid()==true end
local function same(a,b)return valid(a) and valid(b) and a:GetAddress()==b:GetAddress()end
local function number(n)return type(n)=='number' and n==n and n>0 and n<math.huge end
local function size(n)return string.unpack('f',string.pack('f',math.max(6,math.min(192,math.floor(n*10+0.5)/10))))end
function M.new(report)
    local self={}
    local manifest=require('UIAssets')
    local targets=require('UITargets')
    local captured,overflow={},false
    local captureCount=0
    local LIMIT=131072
    if type(NotifyOnNewObject)=='function'then
        for _,path in ipairs({'/Script/UMG.TextBlock','/Script/UMG.RichTextBlock'})do
            local ok,err=pcall(NotifyOnNewObject,path,function(label)
                -- GetAddress returns the wrapper's stored pointer without dereferencing UObject.
                local address=label:GetAddress()
                if captured[address]==nil then
                    if captureCount>=LIMIT then overflow=true;return end
                    captureCount=captureCount+1
                end
                captured[address]=label
            end)
            if not ok then report('ui-capture-'..path,'Open-screen refresh unavailable: '..tostring(err))end
        end
    else report('ui-capture','Open-screen refresh unavailable: NotifyOnNewObject is missing.')end
    local cfg,fonts,system,worldNow
    local styleClass,libraryClass,objectClass
    local setters={}
    local owners,rich={},{DWW_RichText_C=true,RichTextBlock=true,CommonRichTextBlock=true}
    local assets,styles,styleByAddress,styleByClass,templates,templateByOwner,live={},{},{},{},{},{},{}
    local templateOwners,templateCandidates={},{}
    local templateBatch,templateKey=1,nil
    local inlineTemplates={}
    local liveCount=0
    local holders,pins,pinned={},{},{}
    local phase,cursor,key,reason
    -- Freeze construction captures after defaults are ready. New menu openings
    -- inherit those defaults and stay in the next capture set without waking us.
    local batches,batchIndex,batchKey={},1,nil
    local passWorld,ownerCache
    local initialized,prepared,needsRecovery=false,false,false
    local previous
    local passes,writes,seconds,maximum=0,0,0,0
    local measured={}
    local requestStarted
    local function property(o,name,kind)
        local p=o:Reflection():GetProperty(name)
        assert(p and p:IsValid() and p:GetFullName():match('^(%S+)')==kind,'Unsupported '..name..' property')
        return p
    end
    local function setter(path,argument)
        local ok=pcall(function()
            local fn=StaticFindObject(path);assert(valid(fn),'function missing')
            local count=0
            fn:ForEachProperty(function(p)
                count=count+1
                assert(p:GetFName():ToString()==argument and p:GetFullName():match('^StructProperty '),'signature changed')
            end)
            assert(count==1,'parameter count changed')
        end)
        if not ok then report('ui-setter-'..path,'Open-screen font refresh unavailable: '..path)end
        return ok
    end
    function self.pin(object)
        assert(initialized and valid(object),'Persistent asset retention unavailable')
        local address=object:GetAddress()
        if pinned[address]then return end
        local bucket=math.floor(#pins/32)+1
        local holder=holders[bucket]
        if not valid(holder)then
            holder=StaticConstructObject(libraryClass,CreateInvalidObject(),FName(0),EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
            assert(valid(holder) and holder:HasAnyInternalFlags(EInternalObjectFlags.RootSet),'Cannot retain UI assets')
            local inner=property(holder,'Objects','ArrayProperty'):GetInner()
            assert(inner and inner:IsValid() and inner:GetFullName():match('^ObjectProperty '),'Unsupported persistent reference array')
            property(holder,'bUseWeakReferences','BoolProperty')
            holder.bUseWeakReferences=false
            holders[bucket]=holder
        end
        local group={}
        for i=(bucket-1)*32+1,#pins do group[#group+1]=pins[i]end
        group[#group+1]=object
        -- The pinned UE4SS table setter constructs a new array. Empty the old
        -- allocation first; the root remains alive for the entire game session.
        holder.Objects:Empty();holder.Objects=group
        assert(holder.Objects:GetArrayNum()==#group,'Incomplete persistent asset references')
        pins[#pins+1]=object;pinned[address]=true
    end
    function self.initialize(context,loadedFonts,getWorld)
        system=context;fonts=loadedFonts;worldNow=getWorld
        setters.plain=setter('/Script/UMG.TextBlock:SetFont','InFontInfo')
        setters.rich=setter('/Script/UMG.RichTextBlock:SetDefaultFont','InFontInfo')
        if initialized then return true end
        assert(type(StaticConstructObject)=='function' and type(CreateInvalidObject)=='function','Persistent UI requires StaticConstructObject and CreateInvalidObject')
        libraryClass=StaticFindObject('/Script/Engine.ObjectLibrary')
        styleClass=StaticFindObject('/Script/CommonUI.CommonTextStyle')
        objectClass=StaticFindObject('/Script/CoreUObject.Class')
        assert(valid(libraryClass) and valid(styleClass) and valid(objectClass) and valid(system),'Persistent UI classes are not ready')
        for owner,labels in pairs(targets)do
            local allow={}
            for name,class in pairs(labels)do
                allow[FName(name):GetComparisonIndex()]={class=FName(class):GetComparisonIndex(),rich=rich[class]==true,owner=owner,name=name}
            end
            owners[FName(owner):GetComparisonIndex()]=allow
        end
        initialized=true
        return true
    end
    local function load(path)
        local object=StaticFindObject(path)
        local blocking=false
        if not valid(object)then
            blocking=true
            local soft=system:MakeSoftObjectPath(path)
            object=system:LoadAsset_Blocking(system:Conv_SoftObjPathToSoftObjRef(soft))
        end
        assert(valid(object),'UI asset unavailable: '..path)
        self.pin(object)
        return object,blocking
    end
    local function rememberStyle(class,mutable)
        if not valid(class) or not class:IsChildOf(styleClass)then return end
        local classAddress=class:GetAddress()
        local cached=styleByClass[classAddress]
        if cached and valid(cached.object)then return cached end
        local object=class:GetCDO()
        assert(valid(object),'UI style default is unavailable')
        local address=object:GetAddress()
        if styleByAddress[address]then
            styleByClass[classAddress]=styleByAddress[address]
            return styleByAddress[address]
        end
        property(object,'Font','StructProperty')
        local font=object.Font
        assert(number(font.Size) and valid(font.FontObject),'UI style font layout is unsupported')
        self.pin(class);self.pin(object);self.pin(font.FontObject)
        local entry={object=object,baseSize=font.Size,baseFont=font.FontObject,ui=mutable}
        styles[#styles+1]=entry;styleByAddress[address]=entry;styleByClass[classAddress]=entry
        return entry
    end
    local function styleFor(label,isRich)
        local class=isRich and label.DefaultTextStyleOverrideClass or label.Style
        if not valid(class)then return end
        local cached=styleByClass[class:GetAddress()]
        if cached and valid(cached.object)then return cached end
        if not class:IsA(objectClass)then return end
        if not class:IsChildOf(styleClass)then return end
        return styleByAddress[class:GetCDO():GetAddress()]
    end
    local function fontFor(label,isRich)
        if isRich then return label.bOverrideDefaultStyle==true and label.DefaultTextStyleOverride.Font or label.DefaultTextStyle.Font end
        return label.Font
    end
    local function snapshot(label,isRich)
        local style=styleFor(label,isRich)
        local font=style and style.object.Font or fontFor(label,isRich)
        assert(number(font.Size) and valid(font.FontObject),'UI widget font layout is unsupported')
        self.pin(font.FontObject)
        return {object=label,rich=isRich,baseSize=style and style.baseSize or font.Size,baseFont=style and style.baseFont or font.FontObject}
    end
    local function desired(entry)
        if cfg.enabled~=1 then return entry.baseSize,entry.baseFont end
        return size(entry.baseSize*cfg.uiPercent/100),valid(fonts[cfg.uiFontFamily]) and fonts[cfg.uiFontFamily] or entry.baseFont
    end
    local function change(entry,font,newSize,newFont)
        if font.Size==newSize and same(font.FontObject,newFont)then return false end
        font.Size=newSize;font.FontObject=newFont
        if cfg.debugLogging==1 and requestStarted then writes=writes+1 end
        return true
    end
    local function updateStyle(entry)
        if not entry.ui or not valid(entry.object)then return end
        local font=entry.object.Font
        if entry.lastSize and font.Size~=entry.lastSize then entry.baseSize=font.Size end
        if entry.lastFont and not same(font.FontObject,entry.lastFont)then entry.baseFont=font.FontObject;self.pin(entry.baseFont)end
        local newSize,newFont=desired(entry)
        change(entry,font,newSize,newFont)
        entry.lastSize=newSize;entry.lastFont=newFont
    end
    -- Shared UI styles are also referenced by subtitles. Their separate runtime
    -- keeps using the unscaled style baseline, never the UI-scaled result.
    function self.originalFont(class,currentSize,currentFont)
        if not initialized or not valid(class)then return end
        local ok,entry=pcall(function()return styleByAddress[class:GetCDO():GetAddress()]end)
        if ok and entry and entry.lastSize==currentSize and same(entry.lastFont,currentFont)then return entry.baseSize,entry.baseFont end
    end
    local function updateLabel(entry,isTemplate)
        local label=entry.object
        if not valid(label)then return end
        local style=styleFor(label,entry.rich)
        if isTemplate and style and style.ui then return end
        if entry.rich and not setters.rich or not isTemplate and not entry.rich and not setters.plain then return end
        local font=fontFor(label,entry.rich)
        local newSize,newFont
        if style and style.ui then
            -- SynchronizeProperties reads this CDO again whenever the game
            -- rebuilds the widget. Never scale its already-scaled font twice.
            newSize,newFont=style.object.Font.Size,style.object.Font.FontObject
        else
            if entry.lastSize and font.Size~=entry.lastSize then entry.baseSize=font.Size end
            if entry.lastFont and not same(font.FontObject,entry.lastFont)then entry.baseFont=font.FontObject;self.pin(entry.baseFont)end
            newSize,newFont=desired(entry)
        end
        local oldSize,oldFont=font.Size,font.FontObject
        if cfg.enabled~=1 then
            if entry.lastSize and oldSize~=entry.lastSize then newSize=oldSize end
            if entry.lastFont and not same(oldFont,entry.lastFont)then newFont=oldFont end
        end
        local ok,err=pcall(function()
            if change(entry,font,newSize,newFont)then
                if entry.rich then
                    local wasOverride=label.bOverrideDefaultStyle==true
                    label:SetDefaultFont(font)
                    if not wasOverride then font.Size=oldSize;font.FontObject=oldFont end
                elseif not isTemplate then label:SetFont(font)end
            end
        end)
        if not ok then
            font.Size=oldSize;font.FontObject=oldFont
            error(err)
        end
        entry.lastSize=newSize;entry.lastFont=newFont
    end
    local function target(label)
        if not valid(label) or label:HasAnyFlags(0x30)then return end
        local tree=label:GetOuter();if not valid(tree)then return end
        local owner=tree:GetOuter();if not valid(owner) or owner:HasAnyFlags(0x30)then return end
        local address=owner:GetAddress()
        local cached=ownerCache[address]
        if cached==nil then
            local allow=owners[owner:GetClass():GetFName():GetComparisonIndex()]
            cached=allow and {allow=allow,world=owner:GetWorld()} or false
            ownerCache[address]=cached
        end
        if not cached then return end
        local labelType=cached.allow[label:GetFName():GetComparisonIndex()]
        if not labelType or labelType.class~=label:GetClass():GetFName():GetComparisonIndex()then return end
        if not valid(passWorld)then return nil,'defer' end
        if not same(cached.world,passWorld)then return end
        return owner,cached.world,labelType
    end
    local function beginDiscovery()
        if next(captured)then batches[#batches+1]=captured;captured={}end
        phase='discover';key=nil
    end
    function self.request(snapshot,why)
        cfg=snapshot
        if not initialized then return end
        local signature=table.concat({cfg.enabled,cfg.uiPercent,cfg.uiFontFamily},':')
        if signature==previous and why=='settings'then return end
        previous=signature;reason=why;cursor=1;key=nil;passWorld=worldNow()
        -- There is nothing to restore before our first edit. Stock UI settings
        -- must not force every optional screen into memory at startup.
        if not prepared and #styles==0 and (cfg.enabled~=1 or cfg.uiPercent==100 and cfg.uiFontFamily==2) then
            phase=nil;return
        end
        -- An unavailable optional template must not make every Apply redo all
        -- startup work. A load retries preparation, reusing successful entries.
        local prepare=not prepared or why=='load' and needsRecovery
        phase=prepare and 'load-styles' or 'styles'
        if prepare then needsRecovery=false end
        requestStarted=nil
        if cfg.debugLogging==1 then
            passes=passes+1;writes=0;seconds=0;maximum=0;measured={};requestStarted=os.clock()
        end
    end
    function self.busy()return phase~=nil end
    function self.beginBatch()
        -- Owner lookups are reused only within this game-thread callback.
        ownerCache={}
    end
    function self.step()
        if not phase then return false end
        local measuredPhase=phase
        -- Enabling diagnostics mid-pass takes effect on the next complete pass.
        local started=cfg.debugLogging==1 and requestStarted and os.clock() or nil
        local loaded=false
        local ok,err=pcall(function()
            if phase=='load-styles'then
                local row=manifest.styles[cursor]
                if row then
                    if not valid(assets[row.path])then assets[row.path],loaded=load(row.path)end
                    cursor=cursor+1
                else phase='load-widgets';cursor=1 end
            elseif phase=='load-widgets'then
                local row=manifest.widgets[cursor]
                if row then
                    if not valid(assets[row.path])then assets[row.path],loaded=load(row.path)end
                    templateOwners[assets[row.path]:GetAddress()]={object=assets[row.path],owner=row.owner}
                    cursor=cursor+1
                else phase='snapshot-styles';cursor=1 end
            elseif phase=='snapshot-styles'then
                local row=manifest.styles[cursor]
                if row then rememberStyle(assets[row.path],row.ui);cursor=cursor+1
                else
                    -- Loaded widget trees already reached our construction
                    -- capture. Index one label per operation instead of resolving
                    -- every template through another global object search.
                    if next(captured)then batches[#batches+1]=captured;captured={}end
                    phase='index-templates';templateBatch=1;templateKey=nil
                end
            elseif phase=='index-templates'then
                local batch=batches[templateBatch]
                if not batch then phase='snapshot-templates';cursor=1;key=nil
                else
                    local address,label=next(batch,templateKey);templateKey=address
                    if not address then templateBatch=templateBatch+1
                    elseif valid(label)then
                        local tree=label:GetOuter()
                        local owner=valid(tree) and tree:GetOuter() or nil
                        local entry=valid(owner) and templateOwners[owner:GetAddress()] or nil
                        if entry and same(entry.object,owner) and tree:GetFName():ToString()=='WidgetTree'then
                            local name=label:GetFName():ToString()
                            if targets[entry.owner][name]==label:GetClass():GetFName():ToString()then
                                templateCandidates[entry.owner]=templateCandidates[entry.owner] or {}
                                templateCandidates[entry.owner][name]=label
                            end
                        end
                    end
                end
            elseif phase=='snapshot-templates'then
                local row=manifest.widgets[cursor]
                if not row then prepared=true;phase='styles';cursor=1
                else
                    local name,class=next(targets[row.owner],key);key=name
                    if not name then cursor=cursor+1
                    else
                        local entries=templateByOwner[row.owner]
                        local existing=entries and entries[name]
                        if not existing or not valid(existing.object)then
                            local label=templateCandidates[row.owner] and templateCandidates[row.owner][name]
                            if not valid(label)then label=StaticFindObject(row.path..':WidgetTree.'..name)end
                            assert(valid(label) and label:GetClass():GetFName():ToString()==class,'UI template unavailable: '..row.owner..'.'..name)
                            local isRich=rich[class]==true
                            local selected=isRich and label.DefaultTextStyleOverrideClass or label.Style
                            if valid(selected) and selected:IsChildOf(styleClass)then rememberStyle(selected,true)end
                            local entry=snapshot(label,isRich)
                            entry.owner=row.owner;entry.name=name
                            local style=styleFor(label,isRich)
                            entry.inline=not (style and style.ui)
                            if existing then templates[existing.index]=entry;entry.index=existing.index
                            else templates[#templates+1]=entry;entry.index=#templates end
                            templateByOwner[row.owner]=entries or {}
                            templateByOwner[row.owner][name]=entry
                        end
                    end
                end
            elseif phase=='styles'then
                local entry=styles[cursor]
                if entry then updateStyle(entry);cursor=cursor+1
                else
                    -- Pure Lua filtering does not inspect engine objects. Shared
                    -- style templates already inherit the CDO and need no write.
                    inlineTemplates={}
                    for _,entry in ipairs(templates)do if entry.inline then inlineTemplates[#inlineTemplates+1]=entry end end
                    phase='templates';cursor=1
                end
            elseif phase=='templates'then
                local entry=inlineTemplates[cursor]
                if entry then updateLabel(entry,true);cursor=cursor+1
                else beginDiscovery()end
            elseif phase=='discover'then
                local batch=batches[batchIndex]
                if not batch then batches={};batchIndex=1;batchKey=nil;phase='live';key=nil
                else
                    local address,label=next(batch,batchKey);batchKey=address
                    if not address then batchIndex=batchIndex+1
                    else
                        -- No new keys are inserted into a frozen batch; removing
                        -- the consumed key is safe during next() traversal.
                        batch[address]=nil
                        captureCount=captureCount-1
                        local existing=live[address]
                        if not existing or existing.object~=label then
                            local owner,world,labelType=target(label)
                            if owner then
                                if not existing and liveCount>=LIMIT then overflow=true;return end
                                local entry=snapshot(label,labelType.rich)
                                entry.owner=owner;entry.world=world
                                local t=templateByOwner[labelType.owner] and templateByOwner[labelType.owner][labelType.name]
                                if t then entry.baseSize=t.baseSize;entry.baseFont=t.baseFont end
                                live[address]=entry
                                if not existing then liveCount=liveCount+1 end
                            elseif world=='defer'then
                                if not captured[address]then captureCount=captureCount+1;captured[address]=label end
                            elseif existing then live[address]=nil;liveCount=liveCount-1 end
                        end
                    end
                end
            elseif phase=='live'then
                local address,entry=next(live,key);key=address
                if not address then
                    phase=nil
                    if overflow then report('ui-capacity','Open-screen refresh capacity exceeded; restart to reset the cache.');overflow=false end
                elseif not valid(entry.object) or not valid(entry.owner) or valid(passWorld) and not same(entry.world,passWorld)
                    or captured[address] and captured[address]~=entry.object then
                    live[address]=nil
                    liveCount=liveCount-1
                elseif valid(passWorld)then updateLabel(entry,false)end
            end
        end)
        if not ok then
            if measuredPhase:match('^load') or measuredPhase:match('^snapshot')then needsRecovery=true end
            report('ui-'..measuredPhase..'-'..tostring(cursor),'Persistent UI operation failed: '..tostring(err))
            if phase~='snapshot-templates' and phase~='index-templates' and phase~='discover' and phase~='live'then cursor=cursor+1 end
        end
        if started then
            local elapsed=os.clock()-started;seconds=seconds+elapsed;maximum=math.max(maximum,elapsed)
            local timing=measured[measuredPhase] or {count=0,seconds=0}
            timing.count=timing.count+1;timing.seconds=timing.seconds+elapsed;measured[measuredPhase]=timing
            if not phase then
                print(string.format('[UIAndSubtitles] persistent-ui reason=%s passes=%d styles=%d templates=%d labels=%d writes=%d elapsed=%.3fms work=%.3fms max-operation=%.3fms\n',reason,passes,#styles,#templates,liveCount,writes,(os.clock()-requestStarted)*1000,seconds*1000,maximum*1000))
                for _,name in ipairs({'load-styles','load-widgets','snapshot-styles','index-templates','snapshot-templates','styles','templates','discover','live'})do
                    local timing=measured[name]
                    if timing then print(string.format('[UIAndSubtitles] phase=%s operations=%d work=%.3fms\n',name,timing.count,timing.seconds*1000))end
                end
            end
        end
        return loaded
    end
    return self
end
return M
