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
    local assets,styles,styleByAddress,templates,templateByOwner,live={},{},{},{},{},{}
    local holders,pins,pinned={},{},{}
    local phase,cursor,key,reason
    local prune={}
    local initialized,prepared,incomplete=false,false,false
    local previous
    local passes,writes,seconds,maximum=0,0,0,0
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
            for name,class in pairs(labels)do allow[FName(name):GetComparisonIndex()]=FName(class):GetComparisonIndex()end
            owners[FName(owner):GetComparisonIndex()]=allow
        end
        initialized=true
        return true
    end
    local function load(path)
        local object=StaticFindObject(path)
        if not valid(object)then
            local soft=system:MakeSoftObjectPath(path)
            object=system:LoadAsset_Blocking(system:Conv_SoftObjPathToSoftObjRef(soft))
        end
        assert(valid(object),'UI asset unavailable: '..path)
        self.pin(object)
        return object
    end
    local function rememberStyle(class,mutable)
        if not valid(class) or not class:IsChildOf(styleClass)then return end
        local object=class:GetCDO()
        assert(valid(object),'UI style default is unavailable')
        local address=object:GetAddress()
        if styleByAddress[address]then return styleByAddress[address]end
        property(object,'Font','StructProperty')
        local font=object.Font
        assert(number(font.Size) and valid(font.FontObject),'UI style font layout is unsupported')
        self.pin(class);self.pin(font.FontObject)
        local entry={object=object,baseSize=font.Size,baseFont=font.FontObject,ui=mutable}
        styles[#styles+1]=entry;styleByAddress[address]=entry
        return entry
    end
    local function styleFor(label,isRich)
        local class=isRich and label.DefaultTextStyleOverrideClass or label.Style
        if not valid(class) or not class:IsA(objectClass)then return end
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
        return {object=label,rich=isRich,baseSize=font.Size,baseFont=font.FontObject}
    end
    local function desired(entry)
        if cfg.enabled~=1 then return entry.baseSize,entry.baseFont end
        return size(entry.baseSize*cfg.uiPercent/100),valid(fonts[cfg.uiFontFamily]) and fonts[cfg.uiFontFamily] or entry.baseFont
    end
    local function change(entry,font,newSize,newFont)
        if font.Size==newSize and same(font.FontObject,newFont)then return false end
        font.Size=newSize;font.FontObject=newFont
        if cfg.debugLogging==1 then writes=writes+1 end
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
        local allow=owners[owner:GetClass():GetFName():GetComparisonIndex()]
        if not allow or allow[label:GetFName():GetComparisonIndex()]~=label:GetClass():GetFName():GetComparisonIndex()then return end
        if not same(label:GetWorld(),worldNow())then return end
        return true
    end
    function self.request(snapshot,why)
        cfg=snapshot
        if not initialized then return end
        local signature=table.concat({cfg.enabled,cfg.uiPercent,cfg.uiFontFamily},':')
        if signature==previous and why=='settings'then return end
        previous=signature;reason=why;cursor=1;key=nil;incomplete=false;prune={}
        -- Incomplete loading is retried only by another explicit load/Apply.
        phase=prepared and 'styles' or 'load-styles'
        if cfg.debugLogging==1 then passes=passes+1;writes=0;seconds=0;maximum=0 end
    end
    function self.busy()return phase~=nil end
    function self.step()
        if not phase then return false end
        local started=cfg.debugLogging==1 and os.clock() or nil
        local loaded=false
        local ok,err=pcall(function()
            if phase=='load-styles'then
                local row=manifest.styles[cursor]
                if row then assets[row.path]=load(row.path);cursor=cursor+1;loaded=true
                else phase='load-widgets';cursor=1 end
            elseif phase=='load-widgets'then
                local row=manifest.widgets[cursor]
                if row then assets[row.path]=load(row.path);cursor=cursor+1;loaded=true
                else phase='snapshot-styles';cursor=1 end
            elseif phase=='snapshot-styles'then
                local row=manifest.styles[cursor]
                if row then rememberStyle(assets[row.path],row.ui);cursor=cursor+1
                else phase='snapshot-templates';cursor=1;key=nil end
            elseif phase=='snapshot-templates'then
                local row=manifest.widgets[cursor]
                if not row then prepared=not incomplete;phase='styles';cursor=1
                else
                    local name,class=next(targets[row.owner],key);key=name
                    if not name then cursor=cursor+1
                    else
                        local label=StaticFindObject(row.path..':WidgetTree.'..name)
                        assert(valid(label) and label:GetClass():GetFName():ToString()==class,'UI template unavailable: '..row.owner..'.'..name)
                        local isRich=rich[class]==true
                        local selected=isRich and label.DefaultTextStyleOverrideClass or label.Style
                        if valid(selected) and selected:IsChildOf(styleClass)then rememberStyle(selected,true)end
                        if not (templateByOwner[row.owner] and templateByOwner[row.owner][name])then
                            local entry=snapshot(label,isRich)
                            entry.owner=row.owner;entry.name=name
                            templates[#templates+1]=entry
                            templateByOwner[row.owner]=templateByOwner[row.owner] or {}
                            templateByOwner[row.owner][name]=entry
                        end
                    end
                end
            elseif phase=='styles'then
                local entry=styles[cursor]
                if entry then updateStyle(entry);cursor=cursor+1
                else phase='templates';cursor=1 end
            elseif phase=='templates'then
                local entry=templates[cursor]
                if entry then updateLabel(entry,true);cursor=cursor+1
                else phase='live';key=nil end
            elseif phase=='live'then
                local address,label=next(captured,key);key=address
                if not address then
                    phase='prune';cursor=1
                    if overflow then report('ui-capacity','Open-screen refresh capacity exceeded; restart to reset the cache.');overflow=false end
                elseif target(label)then
                    local entry=live[address]
                    local identity=label:GetFullName()
                    if not entry or entry.identity~=identity or entry.object~=label then
                        entry=snapshot(label,rich[label:GetClass():GetFName():ToString()]==true);entry.identity=identity
                        -- Newly created unstyled widgets inherit the edited template.
                        -- Resolve their baseline from that template for Apply/Off.
                        local owner=label:GetOuter():GetOuter():GetClass():GetFName():ToString()
                        local t=templateByOwner[owner] and templateByOwner[owner][label:GetFName():ToString()]
                        if t then entry.baseSize=t.baseSize;entry.baseFont=t.baseFont end
                        live[address]=entry
                    end
                    updateLabel(entry,false)
                else prune[#prune+1]={address=address,label=label};live[address]=nil end
            elseif phase=='prune'then
                local item=prune[cursor]
                if not item then phase=nil;prune={}
                else
                    if captured[item.address]==item.label then captured[item.address]=nil;captureCount=captureCount-1 end
                    cursor=cursor+1
                end
            end
        end)
        if not ok then
            incomplete=true
            report('ui-'..phase..'-'..tostring(cursor),'Persistent UI operation failed: '..tostring(err))
            if phase=='snapshot-templates'then
                -- The offending label was consumed by next(); continue this tree.
            else cursor=cursor+1 end
        end
        if started then
            local elapsed=os.clock()-started;seconds=seconds+elapsed;maximum=math.max(maximum,elapsed)
            if not phase then print(string.format('[UIAndSubtitles] persistent-ui reason=%s passes=%d styles=%d templates=%d writes=%d total=%.3fms max-operation=%.3fms\n',reason,passes,#styles,#templates,writes,seconds*1000,maximum*1000))end
        end
        return loaded
    end
    return self
end
return M
