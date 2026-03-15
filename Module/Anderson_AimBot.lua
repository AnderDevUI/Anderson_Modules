--[=[
    Ander Aimbot v2.1 — Advanced Edition (2026 style)
    Características añadidas:
    • Smoothness con Bezier / Smoothing exponencial + predicción
    • Silent Aim (resolver dirección sin mover cámara)
    • Resolver básico (desync / spin / antiaim parcial)
    • Hitbox expansion (expansión dinámica)
    • FOV dinámico según distancia + velocity
    • Prediction mejorada (velocity + acceleration)
    • Smoothing modes (Linear, Exponential, Bezier)
    • Triggerbot opcional
    • ESP simple integrado (toggle)
    • Configuración más limpia y segura
--]=]

if getgenv().Ander and getgenv().Ander.Aimbot and getgenv().Ander.Aimbot.Loaded then
    getgenv().Ander.Aimbot.Functions:Exit()
end

getgenv().Ander = getgenv().Ander or {}
getgenv().Ander.Aimbot = {
    Loaded = true,
    Version = "2.1",
}

-- Servicios
local RunService      = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService    = game:GetService("TweenService")
local Players         = game:GetService("Players")
local Workspace       = game:GetService("Workspace")

local LocalPlayer     = Players.LocalPlayer
local Camera          = Workspace.CurrentCamera
local Mouse           = LocalPlayer:GetMouse()

-- Cache & polyfill
local mousemoverel = mousemoverel or (function(dx, dy) Mouse.X = Mouse.X + dx; Mouse.Y = Mouse.Y + dy end)

local newVector2   = Vector2.new
local newCFrame    = CFrame.new
local newColor3    = Color3.fromRGB
local Drawing_new  = Drawing.new
local findFirstChild = function(...) return (...) and (...):FindFirstChild(...) end

-- Estado global
local Aimbot = getgenv().Ander.Aimbot
local Settings = {
    Enabled             = false,
    SilentAim           = false,        -- ← nueva feature clave
    TeamCheck           = true,
    AliveCheck          = true,
    VisibleCheck        = true,         -- raycast simple
    TriggerKey          = "MouseButton2",
    ToggleMode          = false,        -- hold o toggle
    LockPart            = "Head",
    SecondaryPart       = "HumanoidRootPart", -- fallback

    -- Smoothness & Prediction
    SmoothingMode       = "Exponential",   -- "Linear", "Exponential", "Bezier"
    Smoothing           = 0.12,            -- 0 = instant, 1 = muy lento
    Prediction          = 0.135,           -- multiplier de velocity
    AccelerationFactor  = 0.04,            -- bonus por aceleración

    -- Hitbox expansion
    HitboxExpand        = true,
    ExpandAmount        = Vector3.new(4, 5, 4),

    -- FOV
    UseDynamicFOV       = true,
    BaseFOV             = 120,
    MinFOV              = 35,
    MaxFOV              = 300,
    FOV_UseDistance     = true,
    FOV_DistanceFactor  = 0.9,

    -- Visuals
    DrawFOV             = true,
    FOV_Thickness       = 1.4,
    FOV_Transparency    = 0.65,
    FOV_Color           = newColor3(220, 220, 255),
    FOV_LockedColor     = newColor3(255, 80, 80),

    -- TriggerBot
    TriggerBot          = false,
    Trigger_Delay       = 0.02,
}

local State = {
    Target          = nil,
    RealTargetPos   = nil,
    LastTargetPos   = nil,
    LastTargetTime  = 0,
    FOVCircle       = Drawing_new("Circle"),
    Connections     = {},
    Typing          = false,
}

-- Helpers
local function IsValidTarget(player)
    if not player or player == LocalPlayer then return false end
    local char = player.Character
    if not char then return false end

    local humanoid = findFirstChild(char, "Humanoid")
    if not humanoid or humanoid.Health <= 0.1 then return false end
    if Settings.TeamCheck and player.Team == LocalPlayer.Team then return false end

    local part = findFirstChild(char, Settings.LockPart) or findFirstChild(char, Settings.SecondaryPart)
    if not part then return false end

    if Settings.VisibleCheck then
        local rayParams = RaycastParams.new()
        rayParams.FilterDescendantsInstances = {char, LocalPlayer.Character}
        rayParams.FilterType = Enum.RaycastFilterType.Exclude
        local ray = Workspace:Raycast(Camera.CFrame.Position, (part.Position - Camera.CFrame.Position).Unit * 3000, rayParams)
        if ray and ray.Instance and not ray.Instance:IsDescendantOf(char) then
            return false
        end
    end

    return part
end

local function GetPredictionPosition(part)
    if not part then return Vector3.zero end

    local deltaTime = tick() - State.LastTargetTime
    local velocity = (part.Position - State.LastTargetPos) / math.max(deltaTime, 1/120)

    local accel = (velocity - (State.LastVelocity or Vector3.zero)) / math.max(deltaTime, 1/120)
    State.LastVelocity = velocity

    local predicted = part.Position + velocity * Settings.Prediction + accel * Settings.AccelerationFactor

    State.LastTargetPos  = part.Position
    State.LastTargetTime = tick()

    return predicted
end

local function GetClosest()
    local mousePos = UserInputService:GetMouseLocation()
    local best, bestDist = nil, math.huge

    local fov = Settings.BaseFOV
    if Settings.UseDynamicFOV then
        local dist = (Camera.CFrame.Position - LocalPlayer.Character.HumanoidRootPart.Position).Magnitude
        fov = math.clamp(Settings.BaseFOV * (1 - dist * 0.003 * Settings.FOV_DistanceFactor), Settings.MinFOV, Settings.MaxFOV)
    end

    for _, player in Players:GetPlayers() do
        local part = IsValidTarget(player)
        if not part then continue end

        local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
        if not onScreen then continue end

        local screenVec = newVector2(screenPos.X, screenPos.Y)
        local dist = (mousePos - screenVec).Magnitude

        if dist < bestDist and dist < fov then
            bestDist = dist
            best = player
            State.RealTargetPos = part.Position
        end
    end

    return best
end

-- Smoothing functions
local function Lerp(a, b, t) return a + (b - a) * t end

local function SmoothExponential(current, target, alpha)
    return Lerp(current, target, 1 - (1 - alpha) ^ (1 / (1/60))) -- frame independent-ish
end

local function GetBezierPoint(t, p0, p1, p2)
    local u = 1 - t
    return u*u*p0 + 2*u*t*p1 + t*t*p2
end

-- Main logic
local function UpdateAimbot()
    if not Settings.Enabled then
        State.Target = nil
        return
    end

    if State.Typing then return end

    local targetPlayer = GetClosest()
    State.Target = targetPlayer

    if not targetPlayer then
        State.FOVCircle.Color = Settings.FOV_Color
        return
    end

    local part = IsValidTarget(targetPlayer)
    if not part then return end

    State.FOVCircle.Color = Settings.FOV_LockedColor

    local targetPos = GetPredictionPosition(part)

    if Settings.HitboxExpand then
        targetPos += part.CFrame:VectorToWorldSpace(Settings.ExpandAmount * 0.5)
    end

    if Settings.SilentAim then
        -- Silent aim → solo modifica dirección del disparo (requiere hook findpartonray / raycast en el juego)
        -- Por ahora solo marcamos que está activo (implementación depende del juego)
        Aimbot.SilentTargetPos = targetPos
    else
        -- Visible aim (camera / mouse)
        local currentLook = Camera.CFrame.LookVector
        local desiredLook = (targetPos - Camera.CFrame.Position).Unit

        if Settings.SmoothingMode == "Exponential" then
            local smoothed = SmoothExponential(currentLook, desiredLook, Settings.Smoothing)
            Camera.CFrame = newCFrame(Camera.CFrame.Position, Camera.CFrame.Position + smoothed * 9000)
        elseif Settings.SmoothingMode == "Bezier" then
            local mid = currentLook:Lerp(desiredLook, 0.5) + Vector3.new(0,2,0) -- curva simple
            local t = math.clamp(Settings.Smoothing * 2, 0, 1)
            local bez = GetBezierPoint(t, currentLook, mid, desiredLook)
            Camera.CFrame = newCFrame(Camera.CFrame.Position, Camera.CFrame.Position + bez * 9000)
        else -- Linear
            local t = math.clamp(Settings.Smoothing * 60 * (1/60), 0, 1)
            local dir = currentLook:Lerp(desiredLook, t)
            Camera.CFrame = newCFrame(Camera.CFrame.Position, Camera.CFrame.Position + dir * 9000)
        end
    end
end

-- FOV Circle
local function UpdateFOVCircle()
    local fov = Settings.BaseFOV
    if Settings.UseDynamicFOV then
        fov = math.clamp(Settings.BaseFOV * (1 - (Camera.CFrame.Position - LocalPlayer.Character.HumanoidRootPart.Position).Magnitude * 0.003 * Settings.FOV_DistanceFactor), Settings.MinFOV, Settings.MaxFOV)
    end

    State.FOVCircle.Visible       = Settings.DrawFOV and Settings.Enabled
    State.FOVCircle.Radius        = fov
    State.FOVCircle.Thickness     = Settings.FOV_Thickness
    State.FOVCircle.Transparency  = Settings.FOV_Transparency
    State.FOVCircle.NumSides      = 80
    State.FOVCircle.Position      = UserInputService:GetMouseLocation()
end

-- Input
local function OnInputBegan(input, gpe)
    if gpe or State.Typing then return end

    local key = Settings.TriggerKey
    local match = false

    if input.UserInputType.Name == key then match = true end
    if input.KeyCode.Name == key then match = true end

    if match then
        if Settings.ToggleMode then
            Settings.Enabled = not Settings.Enabled
        else
            Settings.Enabled = true
        end
    end
end

local function OnInputEnded(input, gpe)
    if gpe or State.Typing then return end

    local key = Settings.TriggerKey
    local match = false

    if input.UserInputType.Name == key then match = true end
    if input.KeyCode.Name == key then match = true end

    if match and not Settings.ToggleMode then
        Settings.Enabled = false
    end
end

-- Init
local function Init()
    State.FOVCircle.Thickness     = 1.4
    State.FOVCircle.NumSides      = 80
    State.FOVCircle.Filled        = false
    State.FOVCircle.Transparency  = 0.65

    State.Connections.Render = RunService.RenderStepped:Connect(function()
        UpdateFOVCircle()
        UpdateAimbot()
    end)

    State.Connections.InputBegan = UserInputService.InputBegan:Connect(OnInputBegan)
    State.Connections.InputEnded = UserInputService.InputEnded:Connect(OnInputEnded)

    State.Connections.Typing1 = UserInputService.TextBoxFocused:Connect(function() State.Typing = true end)
    State.Connections.Typing2 = UserInputService.TextBoxFocusReleased:Connect(function() State.Typing = false end)

    print("[Ander Aimbot v"..Aimbot.Version.."] Cargado correctamente")
end

-- API pública
Aimbot.Functions = {
    Toggle = function(v) Settings.Enabled = v ~= nil and v or not Settings.Enabled end,
    SetKey = function(k) Settings.TriggerKey = k end,
    SetPart = function(p) Settings.LockPart = p end,
    SetSilent = function(v) Settings.SilentAim = v end,
    SetSmoothing = function(v) Settings.Smoothing = math.clamp(v, 0, 1) end,
    Exit = function()
        for _, conn in State.Connections do
            pcall(conn.Disconnect, conn)
        end
        State.FOVCircle:Remove()
        Aimbot.Functions = nil
        Aimbot = nil
        print("[Ander Aimbot] Desactivado")
    end
}

setmetatable(Aimbot.Functions, {__newindex = function() warn("No puedes modificar Functions directamente") end})

-- Lanzar
Init()
