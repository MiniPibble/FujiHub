--[[
    FujiHub  |  Code Redeemer
    Rebuilt UI (280x360): tab bar (Dashboard / Settings / Console), live stats,
    toast alerts, animated border, floating reopen bubble.

    Hide / show:  RightShift  (or tap the floating "F" bubble)
    Unload:       the X button, or  getgenv().FujiHubUnload()
]]

------------------------------------------------------------
-- SERVICES
------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local function service(name) return cloneref(game:GetService(name)) end

local Players = service("Players")
local ReplicatedStorage = service("ReplicatedStorage")
local RunService = service("RunService")
local UserInputService = service("UserInputService")
local TweenService = service("TweenService")
local HttpService = service("HttpService")
local CoreGui = service("CoreGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local getconn = getconnections or (debug and debug.getconnections)
local getups = (debug and debug.getupvalues) or getupvalues
local setup = (debug and debug.setupvalue) or setupvalue
local genv = (type(getgenv) == "function" and getgenv()) or {}

------------------------------------------------------------
-- CONFIG (saved to file when the executor supports it)
------------------------------------------------------------
local CONFIG_FILE = "fujihub_code_redeemer.json"
local LEGACY_FILE = "levithon_code_redeemer_config.json"

local Config = {
    AutoCode = true,
    AutoSubmit = true,
    SubmitAfter = 3,
    RetypeInvalid = false,
    RiddleSolver = false,
}

local function readJson(path)
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end
    local ok, data = pcall(function()
        if isfile(path) then
            return HttpService:JSONDecode(readfile(path))
        end
    end)
    if ok and type(data) == "table" then return data end
    return nil
end

do
    local saved = readJson(CONFIG_FILE)
    if saved then
        for _, key in ipairs({ "AutoCode", "AutoSubmit", "RetypeInvalid", "RiddleSolver" }) do
            if type(saved[key]) == "boolean" then Config[key] = saved[key] end
        end
        if type(saved.SubmitAfter) == "number" then
            Config.SubmitAfter = math.max(1, math.floor(saved.SubmitAfter))
        end
    else
        local old = readJson(LEGACY_FILE)
        if old then
            if type(old.a) == "boolean" then Config.AutoCode = old.a end
            if type(old.b) == "boolean" then Config.AutoSubmit = old.b end
            if type(old.c) == "number" then Config.SubmitAfter = math.max(1, math.floor(old.c)) end
            if type(old.d) == "boolean" then Config.RetypeInvalid = old.d end
            if type(old.e) == "boolean" then Config.RiddleSolver = old.e end
        end
    end
end

local function saveConfig()
    if type(writefile) ~= "function" then return end
    pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(Config)) end)
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local State = {
    Dead = false,
    Parts = {},
    Dedupe = {},
    Focused = nil,
    CodeBox = nil,
    Tracked = nil,
    TextConn = nil,
    AncConn = nil,
    LastText = "",
    Pending = nil,
    PendingBox = nil,
    PendingExpire = 0,
    PendingToken = 0,
    Stats = { Captured = 0, Submitted = 0, Invalid = 0 },
}

local Conns = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    Conns[#Conns + 1] = c
    return c
end

local Unload -- forward declaration
local refreshStatus -- forward declaration

------------------------------------------------------------
-- CLEAN UP OLD INSTANCES
------------------------------------------------------------
local OLD_GUIS = { "FujiHub", "LevithonCodeRedeemer", "ACECodeSniperUI", "AutoTypeCodesUI" }
do
    local roots = { PlayerGui }
    pcall(function() table.insert(roots, CoreGui) end)
    if type(gethui) == "function" then
        pcall(function() table.insert(roots, gethui()) end)
    end
    for _, root in ipairs(roots) do
        pcall(function()
            for _, name in ipairs(OLD_GUIS) do
                local prev = root:FindFirstChild(name)
                if prev then prev:Destroy() end
            end
        end)
    end
    if type(genv.FujiHubUnload) == "function" then pcall(genv.FujiHubUnload) end
end

------------------------------------------------------------
-- THEME + UI HELPERS
------------------------------------------------------------
local C = {
    Bg      = Color3.fromRGB(7, 7, 9),
    Side    = Color3.fromRGB(11, 11, 14),
    Card    = Color3.fromRGB(16, 16, 20),
    Card2   = Color3.fromRGB(26, 26, 32),
    Line    = Color3.fromRGB(38, 38, 46),
    Text    = Color3.fromRGB(244, 244, 248),
    Sub     = Color3.fromRGB(140, 140, 154),
    Accent  = Color3.fromRGB(255, 64, 86),
    Accent2 = Color3.fromRGB(255, 122, 92),
    Good    = Color3.fromRGB(80, 225, 140),
    Bad     = Color3.fromRGB(255, 84, 96),
    Warn    = Color3.fromRGB(255, 196, 80),
    White   = Color3.fromRGB(255, 255, 255),
}

local function new(class, props, kids)
    local obj = Instance.new(class)
    local parent
    for k, v in pairs(props or {}) do
        if k == "Parent" then parent = v else obj[k] = v end
    end
    for _, kid in ipairs(kids or {}) do kid.Parent = obj end
    obj.Parent = parent
    return obj
end

local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end

local function stroke(color, thickness, transparency)
    return new("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function tween(obj, time, props, style, dir)
    local tw = TweenService:Create(
        obj,
        TweenInfo.new(time, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out),
        props
    )
    tw:Play()
    return tw
end

local function label(parent, str, size, color, font, props)
    local p = {
        Text = str,
        TextSize = size,
        TextColor3 = color,
        Font = font or Enum.Font.Gotham,
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = parent,
    }
    for k, v in pairs(props or {}) do p[k] = v end
    return new("TextLabel", p)
end

-- Switch: returns track (position it yourself) and a setter
local function makeSwitch(parent, default, onChange, w, h)
    w, h = w or 40, h or 22
    local ks = h - 6
    local state = default
    local track = new("TextButton", {
        Text = "",
        AutoButtonColor = false,
        Size = UDim2.fromOffset(w, h),
        BackgroundColor3 = state and C.Accent or C.Card2,
        Parent = parent,
    }, { corner(math.floor(h / 2)) })
    local knob = new("Frame", {
        Size = UDim2.fromOffset(ks, ks),
        Position = state and UDim2.new(1, -(3 + ks), 0.5, -ks / 2) or UDim2.new(0, 3, 0.5, -ks / 2),
        BackgroundColor3 = C.White,
        BorderSizePixel = 0,
        Parent = track,
    }, { corner(math.floor(ks / 2)) })

    local function set(v, silent)
        state = v
        tween(track, 0.2, { BackgroundColor3 = v and C.Accent or C.Card2 })
        tween(knob, 0.2, {
            Position = v and UDim2.new(1, -(3 + ks), 0.5, -ks / 2) or UDim2.new(0, 3, 0.5, -ks / 2),
        })
        if not silent and onChange then onChange(v) end
    end

    track.MouseButton1Click:Connect(function() set(not state) end)
    return track, set
end

local function makeDraggable(handle, target)
    local dragging, dragStart, startPos = false, nil, nil
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = target.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    bind(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
end

------------------------------------------------------------
-- SCREEN GUI + WINDOW  (280 x 360, same size as the original)
------------------------------------------------------------
local Gui = new("ScreenGui", {
    Name = "FujiHub",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
do
    local parent = PlayerGui
    if type(gethui) == "function" then
        local ok, r = pcall(gethui)
        if ok and r then parent = r end
    elseif pcall(function() return CoreGui:GetChildren() end) then
        parent = CoreGui
    end
    if not pcall(function() Gui.Parent = parent end) then Gui.Parent = PlayerGui end
end

local Root = new("Frame", {
    Name = "Root",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(280, 360),
    BackgroundTransparency = 1,
    Parent = Gui,
})
local RootScale = new("UIScale", { Scale = 0, Parent = Root })

new("ImageLabel", { -- soft shadow
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.new(1, 70, 1, 70),
    BackgroundTransparency = 1,
    Image = "rbxassetid://6014261993",
    ImageColor3 = Color3.new(0, 0, 0),
    ImageTransparency = 0.35,
    ScaleType = Enum.ScaleType.Slice,
    SliceCenter = Rect.new(49, 49, 450, 450),
    ZIndex = 0,
    Parent = Root,
})

local Main = new("Frame", {
    Name = "Window",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = C.Bg,
    BorderSizePixel = 0,
    Active = true,
    ClipsDescendants = true,
    Parent = Root,
}, { corner(14) })

local MainStroke = stroke(C.Accent, 1.6, 0.1)
MainStroke.Parent = Main
local MainGrad = new("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, C.Accent),
        ColorSequenceKeypoint.new(0.25, Color3.fromRGB(24, 24, 30)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(235, 235, 240)),
        ColorSequenceKeypoint.new(0.75, Color3.fromRGB(24, 24, 30)),
        ColorSequenceKeypoint.new(1, C.Accent),
    }),
    Parent = MainStroke,
})

------------------------------------------------------------
-- HEADER
------------------------------------------------------------
local Header = new("Frame", {
    Size = UDim2.new(1, 0, 0, 44),
    BackgroundTransparency = 1,
    Parent = Main,
})
new("Frame", {
    Position = UDim2.new(0, 10, 1, -1),
    Size = UDim2.new(1, -20, 0, 1),
    BackgroundColor3 = C.Line,
    BorderSizePixel = 0,
    Parent = Header,
})

local Logo = new("Frame", {
    Position = UDim2.fromOffset(10, 8),
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = C.Accent,
    Parent = Header,
}, {
    corner(8),
    new("UIGradient", { Color = ColorSequence.new(C.Accent2, C.Accent), Rotation = 45 }),
})
label(Logo, "F", 16, C.White, Enum.Font.GothamBlack, {
    Size = UDim2.fromScale(1, 1),
    TextXAlignment = Enum.TextXAlignment.Center,
})
label(Header, "FujiHub", 15, C.Text, Enum.Font.GothamBlack, {
    Position = UDim2.fromOffset(46, 6),
    Size = UDim2.fromOffset(80, 18),
})
label(Header, "Code Redeemer", 9, C.Sub, Enum.Font.GothamMedium, {
    Position = UDim2.fromOffset(46, 24),
    Size = UDim2.fromOffset(80, 12),
})

local function topButton(text, xOffset, hover)
    local b = new("TextButton", {
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = C.Sub,
        BackgroundColor3 = C.Card,
        AutoButtonColor = false,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, xOffset, 0.5, 0),
        Size = UDim2.fromOffset(24, 24),
        Parent = Header,
    }, { corner(7), stroke(C.Line, 1) })
    b.MouseEnter:Connect(function()
        tween(b, 0.15, { BackgroundColor3 = hover, TextColor3 = C.White })
    end)
    b.MouseLeave:Connect(function()
        tween(b, 0.15, { BackgroundColor3 = C.Card, TextColor3 = C.Sub })
    end)
    return b
end

local CloseBtn = topButton("×", -10, C.Bad)
local HideBtn = topButton("–", -38, C.Card2)

local Pill = new("Frame", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -68, 0.5, 0),
    Size = UDim2.fromOffset(78, 22),
    BackgroundColor3 = C.Card,
    Parent = Header,
}, { corner(11), stroke(C.Line, 1) })
local PillDot = new("Frame", {
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 9, 0.5, 0),
    Size = UDim2.fromOffset(7, 7),
    BackgroundColor3 = C.Good,
    BorderSizePixel = 0,
    Parent = Pill,
}, { corner(4) })
local PillLabel = label(Pill, "Scanning", 10, C.Good, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(22, 0),
    Size = UDim2.new(1, -24, 1, 0),
})

makeDraggable(Header, Root)

------------------------------------------------------------
-- TAB BAR (segmented control)
------------------------------------------------------------
local TabList = new("Frame", {
    Position = UDim2.fromOffset(10, 52),
    Size = UDim2.new(1, -20, 0, 30),
    BackgroundColor3 = C.Card,
    Parent = Main,
}, {
    corner(9),
    stroke(C.Line, 1),
    new("UIPadding", {
        PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3),
        PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3),
    }),
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 2),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Center,
    }),
})

------------------------------------------------------------
-- PAGES
------------------------------------------------------------
local PagesHolder = new("Frame", {
    Position = UDim2.fromOffset(10, 90),
    Size = UDim2.new(1, -20, 1, -100),
    BackgroundTransparency = 1,
    Parent = Main,
})

local Pages = {}
local function newPage(name, class, props)
    local p = {
        Name = name,
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Visible = false,
        Parent = PagesHolder,
    }
    for k, v in pairs(props or {}) do p[k] = v end
    local f = new(class or "Frame", p)
    Pages[name] = f
    return f
end

------------------------------------------------------------
-- DASHBOARD PAGE
------------------------------------------------------------
local Dash = newPage("Dashboard")
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Dash })

local Hero = new("Frame", {
    Size = UDim2.new(1, 0, 0, 62),
    BackgroundColor3 = C.Card,
    LayoutOrder = 1,
    Parent = Dash,
}, {
    corner(12),
    stroke(C.Accent, 1, 0.55),
    new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(46, 16, 24), C.Card), Rotation = 0 }),
})
label(Hero, "Auto Code", 15, C.Text, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(14, 9),
    Size = UDim2.new(1, -80, 0, 20),
})
local HeroSub = label(Hero, "", 10, C.Sub, Enum.Font.Gotham, {
    Position = UDim2.fromOffset(14, 30),
    Size = UDim2.new(1, -80, 0, 26),
    TextWrapped = true,
    TextYAlignment = Enum.TextYAlignment.Top,
})
local HeroSwitch = makeSwitch(Hero, Config.AutoCode, function(v)
    Config.AutoCode = v
    saveConfig()
    refreshStatus()
end, 48, 26)
HeroSwitch.AnchorPoint = Vector2.new(1, 0.5)
HeroSwitch.Position = UDim2.new(1, -14, 0.5, 0)

local StatsRow = new("Frame", {
    Size = UDim2.new(1, 0, 0, 58),
    BackgroundTransparency = 1,
    LayoutOrder = 2,
    Parent = Dash,
}, {
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }),
})

local StatLabels = {}
for i, info in ipairs({
    { Key = "Captured", Caption = "Captured" },
    { Key = "Submitted", Caption = "Submitted" },
    { Key = "Invalid", Caption = "Re-pasted" },
}) do
    local card = new("Frame", {
        Size = UDim2.new(1 / 3, -4, 1, 0),
        BackgroundColor3 = C.Card,
        LayoutOrder = i,
        Parent = StatsRow,
    }, { corner(10), stroke(C.Line, 1) })
    StatLabels[info.Key] = label(card, "0", 20, C.Text, Enum.Font.GothamBlack, {
        Position = UDim2.fromOffset(10, 6),
        Size = UDim2.new(1, -14, 0, 26),
    })
    label(card, info.Caption, 10, C.Sub, Enum.Font.GothamMedium, {
        Position = UDim2.fromOffset(10, 34),
        Size = UDim2.new(1, -14, 0, 14),
    })
end

local LastCard = new("Frame", {
    Size = UDim2.new(1, 0, 0, 124),
    BackgroundColor3 = C.Card,
    LayoutOrder = 3,
    Parent = Dash,
}, { corner(12), stroke(C.Line, 1) })
label(LastCard, "LAST CAPTURED CODE", 9, C.Sub, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(14, 10),
    Size = UDim2.new(0.55, 0, 0, 14),
})
local BoxStatus = label(LastCard, "Click the code box", 10, C.Warn, Enum.Font.GothamMedium, {
    Position = UDim2.new(0.5, 0, 0, 10),
    Size = UDim2.new(0.5, -14, 0, 14),
    TextXAlignment = Enum.TextXAlignment.Right,
})
local LastCode = label(LastCard, "-", 20, C.Text, Enum.Font.Code, {
    Position = UDim2.fromOffset(14, 28),
    Size = UDim2.new(1, -28, 0, 28),
    TextTruncate = Enum.TextTruncate.AtEnd,
})
label(LastCard, "Paste progress", 10, C.Sub, Enum.Font.GothamMedium, {
    Position = UDim2.fromOffset(14, 64),
    Size = UDim2.new(0.5, 0, 0, 14),
})
local ProgressText = label(LastCard, "0/3", 10, C.Text, Enum.Font.GothamBold, {
    Position = UDim2.new(0.5, 0, 0, 64),
    Size = UDim2.new(0.5, -14, 0, 14),
    TextXAlignment = Enum.TextXAlignment.Right,
})
local ProgressBack = new("Frame", {
    Position = UDim2.fromOffset(14, 84),
    Size = UDim2.new(1, -28, 0, 6),
    BackgroundColor3 = C.Card2,
    BorderSizePixel = 0,
    Parent = LastCard,
}, { corner(3) })
local ProgressFill = new("Frame", {
    Size = UDim2.new(0, 0, 1, 0),
    BackgroundColor3 = C.Accent,
    BorderSizePixel = 0,
    Parent = ProgressBack,
}, {
    corner(3),
    new("UIGradient", { Color = ColorSequence.new(C.Accent, C.Accent2) }),
})
label(LastCard, "Click the game's code box once so FujiHub can find it.", 9, C.Sub, Enum.Font.Gotham, {
    Position = UDim2.fromOffset(14, 98),
    Size = UDim2.new(1, -28, 0, 20),
    TextWrapped = true,
    TextYAlignment = Enum.TextYAlignment.Top,
})

local function setProgress(count)
    local total = math.max(1, Config.SubmitAfter)
    ProgressText.Text = ("%d/%d"):format(count, total)
    tween(ProgressFill, 0.3, { Size = UDim2.new(math.clamp(count / total, 0, 1), 0, 1, 0) })
end
local function updateProgress() setProgress(#State.Parts) end

local function refreshStats()
    for key, lbl in pairs(StatLabels) do lbl.Text = tostring(State.Stats[key]) end
end

local function setLastCode(code) LastCode.Text = code end

local function setBoxStatus(ok)
    BoxStatus.Text = ok and "Code box detected" or "Click the code box"
    BoxStatus.TextColor3 = ok and C.Good or C.Warn
end

refreshStatus = function()
    local on = Config.AutoCode
    PillLabel.Text = on and "Scanning" or "Paused"
    PillLabel.TextColor3 = on and C.Good or C.Bad
    PillDot.BackgroundColor3 = on and C.Good or C.Bad
    HeroSub.Text = on and "Listening for codes and pasting them for you."
        or "Paused. Turn on to capture codes."
end

------------------------------------------------------------
-- SETTINGS PAGE
------------------------------------------------------------
local Settings = newPage("Settings", "ScrollingFrame", {
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.Accent,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Settings })

local function settingRow(order, title, desc)
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = C.Card,
        LayoutOrder = order,
        Parent = Settings,
    }, { corner(10), stroke(C.Line, 1) })
    label(row, title, 12, C.Text, Enum.Font.GothamBold, {
        Position = UDim2.fromOffset(12, 6),
        Size = UDim2.new(1, -100, 0, 16),
    })
    label(row, desc, 10, C.Sub, Enum.Font.Gotham, {
        Position = UDim2.fromOffset(12, 24),
        Size = UDim2.new(1, -100, 0, 14),
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    return row
end

local function switchRow(order, title, desc, key)
    local row = settingRow(order, title, desc)
    local sw = makeSwitch(row, Config[key], function(v)
        Config[key] = v
        saveConfig()
    end)
    sw.AnchorPoint = Vector2.new(1, 0.5)
    sw.Position = UDim2.new(1, -12, 0.5, 0)
end

switchRow(1, "Auto submit", "Press redeem automatically", "AutoSubmit")

do -- stepper
    local row = settingRow(2, "Submit after", "Captures to combine")
    local function stepBtn(text, xOffset)
        local b = new("TextButton", {
            Text = text,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextColor3 = C.Text,
            BackgroundColor3 = C.Card2,
            AutoButtonColor = false,
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, xOffset, 0.5, 0),
            Size = UDim2.fromOffset(24, 24),
            Parent = row,
        }, { corner(7) })
        b.MouseEnter:Connect(function() tween(b, 0.15, { BackgroundColor3 = C.Accent }) end)
        b.MouseLeave:Connect(function() tween(b, 0.15, { BackgroundColor3 = C.Card2 }) end)
        return b
    end
    local plus = stepBtn("+", -12)
    local value = label(row, tostring(Config.SubmitAfter), 13, C.Text, Enum.Font.GothamBold, {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -38, 0.5, 0),
        Size = UDim2.fromOffset(26, 24),
        TextXAlignment = Enum.TextXAlignment.Center,
    })
    local minus = stepBtn("-", -66)
    local function apply()
        value.Text = tostring(Config.SubmitAfter)
        saveConfig()
        updateProgress()
    end
    minus.MouseButton1Click:Connect(function()
        Config.SubmitAfter = math.max(1, Config.SubmitAfter - 1)
        apply()
    end)
    plus.MouseButton1Click:Connect(function()
        Config.SubmitAfter = Config.SubmitAfter + 1
        apply()
    end)
end

switchRow(3, "Retype invalid", "Re-paste if game rejects", "RetypeInvalid")
switchRow(4, "Riddle solver", "Experimental", "RiddleSolver")

do -- reset stats
    local row = settingRow(5, "Reset stats", "Clear dashboard counters")
    local btn = new("TextButton", {
        Text = "Reset",
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = C.Text,
        BackgroundColor3 = C.Card2,
        AutoButtonColor = false,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(58, 26),
        Parent = row,
    }, { corner(7) })
    btn.MouseEnter:Connect(function() tween(btn, 0.15, { BackgroundColor3 = C.Accent }) end)
    btn.MouseLeave:Connect(function() tween(btn, 0.15, { BackgroundColor3 = C.Card2 }) end)
    btn.MouseButton1Click:Connect(function()
        State.Stats = { Captured = 0, Submitted = 0, Invalid = 0 }
        refreshStats()
    end)
end

------------------------------------------------------------
-- CONSOLE PAGE
------------------------------------------------------------
local ConsolePage = newPage("Console")

label(ConsolePage, "Activity", 11, C.Sub, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(2, 0),
    Size = UDim2.new(0.5, 0, 0, 22),
})
local ClearBtn = new("TextButton", {
    Text = "Clear",
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    TextColor3 = C.Text,
    BackgroundColor3 = C.Card2,
    AutoButtonColor = false,
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, 0, 0, 0),
    Size = UDim2.fromOffset(50, 22),
    Parent = ConsolePage,
}, { corner(7) })
ClearBtn.MouseEnter:Connect(function() tween(ClearBtn, 0.15, { BackgroundColor3 = C.Accent }) end)
ClearBtn.MouseLeave:Connect(function() tween(ClearBtn, 0.15, { BackgroundColor3 = C.Card2 }) end)

local LogCard = new("Frame", {
    Position = UDim2.fromOffset(0, 28),
    Size = UDim2.new(1, 0, 1, -28),
    BackgroundColor3 = Color3.fromRGB(5, 5, 7),
    Parent = ConsolePage,
}, { corner(10), stroke(C.Line, 1) })

local LogScroll = new("ScrollingFrame", {
    Position = UDim2.fromOffset(6, 6),
    Size = UDim2.new(1, -12, 1, -12),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.Accent,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Parent = LogCard,
})
local LogLayout = new("UIListLayout", {
    Padding = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = LogScroll,
})
LogLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    LogScroll.CanvasPosition = Vector2.new(0, math.max(0, LogLayout.AbsoluteContentSize.Y - LogScroll.AbsoluteSize.Y + 8))
end)

local LOG_COLORS = { info = C.Sub, good = C.Good, bad = C.Bad, warn = C.Warn }
local logEntries, logCount, lastLog = {}, 0, nil

local function Log(msg, kind, force)
    if State.Dead then return end
    if not force and not Config.AutoCode then return end
    if msg == lastLog then return end
    lastLog = msg
    logCount = logCount + 1
    local entry = label(LogScroll, ("[%s] %s"):format(os.date("%H:%M:%S"), msg), 10,
        LOG_COLORS[kind or "info"] or C.Sub, Enum.Font.Code, {
            Size = UDim2.new(1, -6, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            TextWrapped = true,
            TextYAlignment = Enum.TextYAlignment.Top,
            LayoutOrder = logCount,
        })
    logEntries[#logEntries + 1] = entry
    if #logEntries > 100 then
        table.remove(logEntries, 1):Destroy()
    end
end

ClearBtn.MouseButton1Click:Connect(function()
    for _, e in ipairs(logEntries) do e:Destroy() end
    logEntries, lastLog = {}, nil
end)

------------------------------------------------------------
-- TOASTS
------------------------------------------------------------
local currentToast
local function Toast(title, body, color)
    if State.Dead then return end
    if currentToast then currentToast:Destroy() end
    color = color or C.Accent
    local t = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, 70),
        Size = UDim2.new(1, -24, 0, 48),
        BackgroundColor3 = C.Card2,
        ZIndex = 50,
        Parent = Main,
    }, { corner(10), stroke(color, 1, 0.45) })
    new("Frame", {
        Position = UDim2.fromOffset(0, 9),
        Size = UDim2.fromOffset(3, 30),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        ZIndex = 51,
        Parent = t,
    }, { corner(2) })
    label(t, title, 12, C.Text, Enum.Font.GothamBold, {
        Position = UDim2.fromOffset(14, 6),
        Size = UDim2.new(1, -22, 0, 18),
        ZIndex = 51,
    })
    label(t, body, 10, C.Sub, Enum.Font.Code, {
        Position = UDim2.fromOffset(14, 25),
        Size = UDim2.new(1, -22, 0, 16),
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 51,
    })
    currentToast = t
    tween(t, 0.4, { Position = UDim2.new(0.5, 0, 1, -12) }, Enum.EasingStyle.Back)
    task.delay(2.8, function()
        if t.Parent then
            tween(t, 0.3, { Position = UDim2.new(0.5, 0, 1, 70) })
            task.delay(0.35, function() t:Destroy() end)
        end
    end)
end

------------------------------------------------------------
-- TABS
------------------------------------------------------------
local TAB_META = { { Name = "Dashboard" }, { Name = "Settings" }, { Name = "Console" } }
local TabButtons = {}
local CurrentPage

local function showPage(name)
    if CurrentPage == name then return end
    CurrentPage = name
    for _, meta in ipairs(TAB_META) do
        local active = meta.Name == name
        local page = Pages[meta.Name]
        local tb = TabButtons[meta.Name]
        page.Visible = active
        if active then
            page.Position = UDim2.fromOffset(0, 8)
            tween(page, 0.3, { Position = UDim2.fromOffset(0, 0) })
        end
        tween(tb.Button, 0.2, { BackgroundTransparency = active and 0 or 1 })
        tween(tb.Label, 0.2, { TextColor3 = active and C.White or C.Sub })
    end
end

for i, meta in ipairs(TAB_META) do
    local btn = new("TextButton", {
        Name = meta.Name,
        Text = "",
        AutoButtonColor = false,
        BackgroundColor3 = C.Accent,
        BackgroundTransparency = 1,
        Size = UDim2.new(1 / 3, -2, 1, 0),
        LayoutOrder = i,
        Parent = TabList,
    }, { corner(7) })
    local lbl = label(btn, meta.Name, 11, C.Sub, Enum.Font.GothamBold, {
        Size = UDim2.fromScale(1, 1),
        TextXAlignment = Enum.TextXAlignment.Center,
    })
    TabButtons[meta.Name] = { Button = btn, Label = lbl }

    btn.MouseEnter:Connect(function()
        if CurrentPage ~= meta.Name then tween(lbl, 0.15, { TextColor3 = C.Text }) end
    end)
    btn.MouseLeave:Connect(function()
        if CurrentPage ~= meta.Name then tween(lbl, 0.15, { TextColor3 = C.Sub }) end
    end)
    btn.MouseButton1Click:Connect(function() showPage(meta.Name) end)
end

------------------------------------------------------------
-- WINDOW CONTROLS (hide / bubble / unload)
------------------------------------------------------------
local Bubble = new("TextButton", {
    Text = "F",
    Font = Enum.Font.GothamBlack,
    TextSize = 20,
    TextColor3 = C.White,
    BackgroundColor3 = C.Accent,
    AutoButtonColor = false,
    Position = UDim2.new(0, 16, 0.5, -23),
    Size = UDim2.fromOffset(46, 46),
    Visible = false,
    ZIndex = 100,
    Parent = Gui,
}, {
    corner(23),
    stroke(C.White, 1.5, 0.7),
    new("UIGradient", { Color = ColorSequence.new(C.Accent2, C.Accent), Rotation = 45 }),
})

local windowShown = true
local function setShown(v)
    windowShown = v
    if v then
        Bubble.Visible = false
        Root.Visible = true
        tween(RootScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
    else
        tween(RootScale, 0.25, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        task.delay(0.26, function()
            if not windowShown and not State.Dead then
                Root.Visible = false
                Bubble.Visible = true
            end
        end)
    end
end

HideBtn.MouseButton1Click:Connect(function() setShown(false) end)
Bubble.MouseButton1Click:Connect(function() setShown(true) end)
CloseBtn.MouseButton1Click:Connect(function() Unload() end)

bind(UserInputService.InputBegan, function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        setShown(not windowShown)
    end
end)

------------------------------------------------------------
-- LOGIC HELPERS
------------------------------------------------------------
local function isOwn(obj) return obj:IsDescendantOf(Gui) end

local function isShown(obj)
    local cur = obj
    while cur do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("ScreenGui") then return cur.Enabled end
        cur = cur.Parent
    end
    return true
end

local function getTextBoxes(pg)
    local r = {}
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") and g.Enabled and not isOwn(g) then
            for _, d in ipairs(g:GetDescendants()) do
                if d:IsA("TextBox") and not isOwn(d) then r[#r + 1] = d end
            end
        end
    end
    return r
end

local function getRedeemButtons(pg)
    local r = {}
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") and g.Enabled and not isOwn(g) then
            for _, d in ipairs(g:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwn(d) then
                    local n = d.Name:lower()
                    local pn = (d.Parent and d.Parent.Name or ""):lower()
                    if (n:find("code") or n:find("redeem") or pn:find("code") or pn:find("redeem")) and isShown(d) then
                        r[#r + 1] = d
                    end
                end
            end
        end
    end
    return r
end

local function findCodeBox()
    for _, b in ipairs(getTextBoxes(PlayerGui)) do
        if isShown(b) then return b end
    end
    return nil
end

local function fireButton(btn)
    if not btn then return false end
    local methods = {}
    if typeof(firesignal) == "function" then
        methods[#methods + 1] = function() firesignal(btn.MouseButton1Click) end
        methods[#methods + 1] = function() firesignal(btn.Activated) end
    end
    if typeof(getconn) == "function" then
        methods[#methods + 1] = function()
            for _, sig in ipairs({ btn.MouseButton1Click, btn.Activated }) do
                local ok, cs = pcall(getconn, sig)
                if ok and type(cs) == "table" then
                    for _, c in ipairs(cs) do pcall(function() c:Fire() end) end
                end
            end
        end
    end
    if typeof(fireclick) == "function" then
        methods[#methods + 1] = function() fireclick(btn) end
    end
    local any = false
    for _, f in ipairs(methods) do
        local ok = pcall(f)
        any = any or ok
    end
    return any
end

local function fireFocusLost(box)
    if not box then return false end
    local any = false
    if typeof(firesignal) == "function" then
        local ok = pcall(firesignal, box.FocusLost, true)
        any = any or ok
    end
    if typeof(getconn) == "function" then
        local ok, cs = pcall(getconn, box.FocusLost)
        if ok and type(cs) == "table" then
            for _, c in ipairs(cs) do
                local fn
                pcall(function() fn = c.Function end)
                if fn and typeof(getups) == "function" and typeof(setup) == "function" then
                    local uok, ups = pcall(getups, fn)
                    if uok and type(ups) == "table" then
                        for i, v in pairs(ups) do
                            if type(v) == "boolean" and v == true then pcall(setup, fn, i, false) end
                        end
                    end
                end
                local fok = pcall(function()
                    if c.Enabled ~= false then c:Fire(true) end
                end)
                any = any or fok
            end
        end
    end
    return any
end

local SUBMIT_NAMES = { "submit", "redeem", "claim", "confirm", "enter", "send", "apply", "ok", "use", "go", "check" }

local function submitCode(code)
    local pg = PlayerGui or LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return false, "no PlayerGui" end

    -- Fast path: PlayerGui.Codes
    local codesGui = pg:FindFirstChild("Codes")
    if codesGui then
        if codesGui:IsA("ScreenGui") then codesGui.Enabled = true end
        local frame = codesGui:FindFirstChild("Codes") or codesGui
        if frame:IsA("GuiObject") then frame.Visible = true end
        local cur = frame
        while cur and cur ~= codesGui do
            if cur:IsA("GuiObject") then cur.Visible = true end
            cur = cur.Parent
        end

        local box
        for _, d in ipairs(frame:GetDescendants()) do
            if d:IsA("TextBox") and not isOwn(d) then
                box = d
                break
            end
        end

        local btn
        for _, d in ipairs(frame:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwn(d) then
                local n = d.Name:lower()
                local t = ""
                pcall(function() t = d.Text:lower() end)
                if n:find("submit") or t:find("submit") or n:find("redeem") or t:find("redeem")
                    or n:find("claim") or t:find("confirm") or n:find("enter") then
                    btn = d
                    break
                end
            end
        end
        if not btn then
            for _, d in ipairs(frame:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwn(d) then
                    local n = d.Name:lower()
                    if not n:find("close") and not n:find("x") and not n:find("toggle") then
                        btn = d
                        break
                    end
                end
            end
        end

        if box then
            pcall(function() box.Text = code end)
            task.wait(0.05)
            if btn then fireButton(btn) end
            fireFocusLost(box)
            return true, "submitted via PlayerGui.Codes"
        end
    end

    -- Dynamic path
    for _, b in ipairs(getRedeemButtons(pg)) do
        fireButton(b)
        task.wait(0.05)
    end
    task.wait(0.2)

    local box
    local deadline = os.clock() + 2
    while os.clock() < deadline do
        local all = getTextBoxes(pg)
        for _, d in ipairs(all) do
            if isShown(d) then
                local n = d.Name:lower()
                local pn = (d.Parent and d.Parent.Name or ""):lower()
                if n:find("code") or pn:find("code") or n:find("redeem") or pn:find("redeem")
                    or n:find("input") or pn:find("textbox") or n:find("enter") then
                    box = d
                    break
                end
            end
        end
        if not box then
            for _, d in ipairs(all) do
                if isShown(d) then
                    box = d
                    break
                end
            end
        end
        if box then break end
        task.wait(0.1)
    end
    if not box then return false, "no codebox visible" end

    pcall(function() box.Text = code end)
    task.wait(0.05)

    local btn
    local p = box.Parent
    for _ = 1, 8 do
        if not p then break end
        for _, d in ipairs(p:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOwn(d) and d ~= box then
                local n = d.Name:lower()
                local t = ""
                pcall(function() t = d.Text:lower() end)
                for _, sn in ipairs(SUBMIT_NAMES) do
                    if n:find(sn) or t:find(sn) then
                        if isShown(d) then
                            btn = d
                            break
                        end
                    end
                end
                if btn then break end
            end
        end
        if btn then break end
        p = p.Parent
    end
    if btn then fireButton(btn) end
    fireFocusLost(box)
    return true, "submitted via dynamic search"
end

------------------------------------------------------------
-- CODE BOX TRACKING
------------------------------------------------------------
local function resetParts()
    State.Parts = {}
    updateProgress()
end

local function untrack()
    if State.TextConn then pcall(function() State.TextConn:Disconnect() end) end
    if State.AncConn then pcall(function() State.AncConn:Disconnect() end) end
    State.TextConn, State.AncConn, State.Tracked = nil, nil, nil
end

local function track(box)
    if not box or State.Tracked == box then return end
    untrack()
    State.Tracked = box
    if box.Text ~= "" then State.LastText = box.Text end
    State.TextConn = box:GetPropertyChangedSignal("Text"):Connect(function()
        if box.Text == "" then resetParts() else State.LastText = box.Text end
    end)
    State.AncConn = box.AncestryChanged:Connect(function(_, parent)
        if not parent then
            resetParts()
            untrack()
        end
    end)
end

------------------------------------------------------------
-- RETYPE INVALID
------------------------------------------------------------
local function clearPending()
    State.Pending, State.PendingBox, State.PendingExpire = nil, nil, 0
end

local function retypeCode(box, text)
    if not Config.RetypeInvalid or not text or text == "" then return false end
    RunService.Heartbeat:Wait()
    local target = findCodeBox() or box
    if not target or not isShown(target) then return false end
    local ok = pcall(function() target.Text = text end)
    if ok then
        State.CodeBox = target
        track(target)
    end
    return ok
end

local REJECT_PHRASES = {
    "invalid code", "code is invalid", "expired", "already redeemed", "already used",
    "doesn't exist", "does not exist", "not found", "rejected",
}

local function onTextSeen(text, obj)
    if State.Dead or not Config.RetypeInvalid or not State.Pending then return end
    if os.clock() > State.PendingExpire then
        clearPending()
        return
    end
    if obj and isOwn(obj) then return end
    local lower = tostring(text or ""):lower()
    local rejected = false
    for _, phrase in ipairs(REJECT_PHRASES) do
        if lower:find(phrase, 1, true) then
            rejected = true
            break
        end
    end
    if not rejected then return end

    local pendingText, pendingBox = State.Pending, State.PendingBox
    clearPending()
    if retypeCode(pendingBox, pendingText) then
        State.Stats.Invalid = State.Stats.Invalid + 1
        refreshStats()
        Log("Invalid - repasted: " .. pendingText, "info")
    end
end

local function watchText(obj)
    if not (obj:IsA("TextLabel") or obj:IsA("TextButton")) then return end
    if isOwn(obj) then return end
    onTextSeen(obj.Text or "", obj)
    obj:GetPropertyChangedSignal("Text"):Connect(function()
        onTextSeen(obj.Text or "", obj)
    end)
end

------------------------------------------------------------
-- CAPTURE FLOW
------------------------------------------------------------
local function handleCapture(text)
    if State.Dead or not text or text == "" or not Config.AutoCode then return end
    if State.Tracked and not isShown(State.Tracked) then
        resetParts()
        untrack()
    end

    local box = findCodeBox()
    State.Parts[#State.Parts + 1] = text
    local combined = table.concat(State.Parts)
    local count = #State.Parts

    if box then
        State.CodeBox = box
        setBoxStatus(true)
        track(box)
        local focused = UserInputService:GetFocusedTextBox() == box
        box.Text = combined
        if focused then
            pcall(function()
                local pos = #combined + 1
                box.CursorPosition = pos
                box.SelectionStart = pos
            end)
        end
    else
        Log("Captured; opening UI...", "info")
    end

    setProgress(count)
    Log(("Pasted %d/%d"):format(count, Config.SubmitAfter), "good")

    if count >= Config.SubmitAfter then
        State.Parts = {}
        task.delay(1.2, updateProgress)

        if Config.AutoSubmit then
            task.spawn(function()
                local pok, ok, msg = pcall(submitCode, combined)
                if pok and ok then
                    State.Stats.Submitted = State.Stats.Submitted + 1
                    refreshStats()
                    Log("Submitted: " .. combined, "good")
                    Toast("Code submitted", combined, C.Good)
                else
                    if retypeCode(box, combined) then
                        Log("Invalid - repasted: " .. combined, "info")
                    else
                        Log("Failed: " .. tostring(pok and msg or ok), "bad")
                        Toast("Submit failed", tostring(pok and msg or ok), C.Bad)
                    end
                end
            end)
        end
    end
end

local function stripTags(t)
    if type(t) ~= "string" then return tostring(t) end
    return (t:gsub("<[^>]->", ""))
end

local Words = {}
local WORDS_NEEDED = 1

local function onNotify(...)
    if State.Dead or not Config.AutoCode then return end
    local text = stripTags(tostring((...) or ""))
    text = text:match("^%s*(.-)%s*$") or ""
    if text == "" or text:find("%s") then return end

    for word in text:gmatch("[%w_]+") do Words[#Words + 1] = word end
    if #Words < WORDS_NEEDED then return end

    local parts = {}
    for i = 1, math.min(#Words, WORDS_NEEDED) do parts[i] = Words[i] end
    Words = {}

    local captured = table.concat(parts)
    if captured == "" or State.Dedupe[captured] then return end
    State.Dedupe[captured] = true
    task.delay(1.25, function() State.Dedupe[captured] = nil end)

    State.Stats.Captured = State.Stats.Captured + 1
    refreshStats()
    setLastCode(captured)
    Toast("Code captured", captured, C.Accent)
    handleCapture(captured)
end

------------------------------------------------------------
-- TEXTBOX FOCUS EVENTS
------------------------------------------------------------
bind(UserInputService.TextBoxFocused, function(box)
    if isOwn(box) then return end
    if box ~= findCodeBox() then return end
    State.Focused = box
    State.CodeBox = box
    setBoxStatus(true)
    track(box)
    if Config.AutoCode then Log("Ready", "good") end
end)

bind(UserInputService.TextBoxFocusReleased, function(box)
    if isOwn(box) then return end
    local current = findCodeBox()
    if box ~= current and box ~= State.CodeBox then return end

    if Config.RetypeInvalid and (box == current or box == State.CodeBox) then
        local text = box.Text ~= "" and box.Text or State.LastText
        if State.Pending and os.clock() <= State.PendingExpire then return end
        State.PendingToken = State.PendingToken + 1
        local token = State.PendingToken
        State.Pending = text
        State.PendingBox = box
        State.PendingExpire = os.clock() + 8
        task.delay(8, function()
            if token == State.PendingToken then clearPending() end
        end)
    end

    if State.Focused == box then
        State.Focused = nil
        if Config.AutoCode then
            local ok = State.CodeBox and State.CodeBox.Parent
            Log(ok and "Ready" or "Click code box first", ok and "good" or "info")
        end
    end
end)

for _, obj in ipairs(PlayerGui:GetDescendants()) do watchText(obj) end
bind(PlayerGui.DescendantAdded, function(obj)
    task.wait(0.04)
    if not State.Dead then watchText(obj) end
end)

------------------------------------------------------------
-- NOTIFICATION HOOK
------------------------------------------------------------
local function findNotifyRemote()
    if genv.PhiNotifyRemote then return genv.PhiNotifyRemote end
    local packages = ReplicatedStorage:WaitForChild("Packages", 8)
    local net = packages and packages:WaitForChild("Net", 8)
    if not net then return nil end

    local info = debug and (debug.getinfo or debug.info)
    if getgc and info and getconn then
        for _, d in ipairs(net:GetDescendants()) do
            if d:IsA("RemoteEvent") then
                local ok, cs = pcall(getconn, d.OnClientEvent)
                if ok and type(cs) == "table" then
                    for _, c in ipairs(cs) do
                        local fok, fn = pcall(function() return c.Function end)
                        if fok and type(fn) == "function" then
                            local iok, inf = pcall(info, fn)
                            if iok and type(inf) == "table"
                                and tostring(inf.short_src or inf.source or ""):find("NotificationController", 1, true) then
                                return d
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local NotifyConn
task.spawn(function()
    local remote = findNotifyRemote()
    if State.Dead then return end
    if not remote then
        Log("Notification remote not found - capture unavailable", "bad", true)
        Toast("Hook failed", "Notification remote not found", C.Bad)
        return
    end
    for _, key in ipairs({ "FujiHubNotifyConnection", "LevithonCodeRedeemerNotifyConnection" }) do
        if genv[key] then
            pcall(function() genv[key]:Disconnect() end)
            genv[key] = nil
        end
    end
    NotifyConn = remote.OnClientEvent:Connect(function(...) pcall(onNotify, ...) end)
    genv.FujiHubNotifyConnection = NotifyConn
    Log("Hooked notification remote", "good", true)
end)

------------------------------------------------------------
-- ANIMATION LOOP
------------------------------------------------------------
bind(RunService.Heartbeat, function(dt)
    MainGrad.Rotation = (MainGrad.Rotation + 90 * dt) % 360
    if Config.AutoCode then
        PillDot.BackgroundTransparency = (0.5 + 0.5 * math.sin(os.clock() * 4)) * 0.65
    else
        PillDot.BackgroundTransparency = 0
    end
end)

------------------------------------------------------------
-- UNLOAD
------------------------------------------------------------
Unload = function()
    if State.Dead then return end
    State.Dead = true
    for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
    Conns = {}
    untrack()
    if NotifyConn then pcall(function() NotifyConn:Disconnect() end) end
    genv.FujiHubNotifyConnection = nil
    genv.FujiHubUnload = nil
    genv.StopAura = nil
    if Gui then Gui:Destroy() end
end

genv.FujiHubUnload = Unload
genv.StopAura = Unload

------------------------------------------------------------
-- START
------------------------------------------------------------
refreshStatus()
refreshStats()
setProgress(0)
showPage("Dashboard")
Log("FujiHub loaded", "good", true)
Log(Config.AutoCode and "Auto Code enabled" or "Auto Code paused", Config.AutoCode and "good" or "warn", true)
tween(RootScale, 0.55, { Scale = 1 }, Enum.EasingStyle.Back)
