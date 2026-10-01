--!strict
--!native
--[[
	Pet Icon Uploader (Roblox Studio plugin)

	Select a pet model, pick an angle, press Upload. You get an rbxassetid:// image back that you
	can drop straight into an ImageLabel in your inventory UI.

	How the render works:
	  * A copy of the model is put far away from your map, in front of a solid backdrop.
	  * The Studio viewport is screenshotted twice, once on a black backdrop and once on a white
	    one. Comparing the two shots shows exactly which pixels belong to the pet, so the icon
	    gets a clean transparent background with soft edges.
	  * The shot is cropped around the pet, padded, resized and uploaded as an Image asset with
	    AssetService:CreateAssetAsync.

	Install: put this file in your local Plugins folder (Plugins tab > Plugins Folder) and restart
	Studio. It has to be a local plugin because Roblox only allows CreateAssetAsync from local
	plugins.
]]

local AssetService = game:GetService("AssetService")
local CaptureService = game:GetService("CaptureService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ContentProvider = game:GetService("ContentProvider")
local CoreGui = game:GetService("CoreGui")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local StarterGui = game:GetService("StarterGui")

local LOG_PREFIX = "[Pet Icon Uploader]"
local SETTINGS_PREFIX = "PetIconUploader_"
local STAGE_NAME = "PetIconUploader_Stage"
local ATTRIBUTE_NAME = "Icon"

local FOV = 30 -- a low field of view means less perspective distortion, which looks better on icons
local FRAME_MARGIN = 0.04 -- breathing room around the pet in the preview and the raw capture
local STAGE_POSITION = Vector3.new(0, 10000, 0) -- far above the map so nothing else ends up in the shot
local SUN_SIDE_ANGLE = math.rad(35) -- the sun lights the pet from behind the camera, turned this far to the side
local SETTLE_TIME = 0.3 -- seconds to let textures and lighting settle before the first screenshot
local PARTICLE_WARMUP = 0.8 -- seconds to let particle emitters fill up before they are frozen
local CAPTURE_TIMEOUT = 10
local MAX_PARTS = 5000
local MAX_PREVIEW_PARTS = 1500
local MAX_TARGETS = 200
local ALPHA_CUTOFF = 0.03 -- alpha below this is background noise, above 1 - this is solid
local BLEED_PASSES = 4 -- how far edge colours are spread into transparent pixels (stops dark fringes)

local SIZES = { 256, 512, 1024 }
local PRESETS = {
	{ label = "Front", yaw = 0, pitch = 10 },
	{ label = "3/4 L", yaw = 35, pitch = 15 },
	{ label = "3/4 R", yaw = -35, pitch = 15 },
	{ label = "Side", yaw = 90, pitch = 5 },
}

-- Lighting used while rendering when "Bright studio lighting" is on, so icons look the same no
-- matter what time of day or mood lighting the place uses.
local STUDIO_LIGHTING: { [string]: any } = {
	ClockTime = 14,
	GeographicLatitude = 0,
	Brightness = 2,
	Ambient = Color3.fromRGB(100, 100, 100),
	OutdoorAmbient = Color3.fromRGB(140, 140, 140),
	ColorShift_Top = Color3.new(0, 0, 0),
	ColorShift_Bottom = Color3.new(0, 0, 0),
	EnvironmentDiffuseScale = 1,
	EnvironmentSpecularScale = 1,
	ExposureCompensation = 0,
	GlobalShadows = true,
	ShadowSoftness = 0.2,
}

--------------------------------------------------------------------------------------------------
-- Settings (saved between Studio sessions)
--------------------------------------------------------------------------------------------------

type Config = {
	yaw: number,
	pitch: number,
	zoom: number, -- 1 = auto-fit, above 1 = manual zoom (the icon is exactly what the preview shows)
	padding: number, -- empty space on each side of the pet, as a fraction of the icon size
	size: number,
	creator: string, -- "User" or "Group"
	groupId: number,
	studioLighting: boolean,
	saveAttribute: boolean,
}

local config: Config = {
	yaw = 35,
	pitch = 15,
	zoom = 1,
	padding = 0.06,
	size = 512,
	creator = "User",
	groupId = 0,
	studioLighting = true,
	saveAttribute = true,
}

do
	local loaded: any = config
	local creatorWasSaved = false
	for key, default in loaded do
		local ok, saved = pcall(function()
			return plugin:GetSetting(SETTINGS_PREFIX .. key)
		end)
		if ok and saved ~= nil and typeof(saved) == typeof(default) then
			loaded[key] = saved
			if key == "creator" then
				creatorWasSaved = true
			end
		end
	end

	config.pitch = math.clamp(config.pitch, -85, 85)
	config.zoom = math.clamp(config.zoom, 1, 4)
	config.padding = math.clamp(config.padding, 0, 0.3)
	if not table.find(SIZES, config.size) then
		config.size = 512
	end
	if config.creator ~= "Group" then
		config.creator = "User"
	end

	-- Group games usually want their icons owned by the group
	if not creatorWasSaved and game.CreatorType == Enum.CreatorType.Group and game.CreatorId > 0 then
		config.creator = "Group"
		config.groupId = game.CreatorId
	end
end

local function saveConfig(key: string)
	local values: any = config
	pcall(function()
		plugin:SetSetting(SETTINGS_PREFIX .. key, values[key])
	end)
end

--------------------------------------------------------------------------------------------------
-- Picking what to render
--------------------------------------------------------------------------------------------------

type Subject = {
	target: Instance,
	basis: CFrame, -- orientation reference, the pet's "front" is basis.LookVector
	center: Vector3,
	points: { Vector3 }, -- world-space corners of every visible part, used for framing
	partCount: number,
}

type Shot = {
	cframe: CFrame, -- the camera, in the subject's original (world) space
	distance: number, -- camera to the framing focus point
	nearDepth: number, -- camera to the closest corner of the subject
	farDepth: number, -- camera to the farthest corner of the subject
}

type Bounds = { minX: number, minY: number, maxX: number, maxY: number }

type Capture = {
	pixels: buffer, -- side x side RGBA8, straight (not premultiplied) alpha
	side: number,
	bounds: Bounds?, -- pixels that belong to the pet
}

type Render = {
	image: EditableImage,
	info: string,
	upscaled: boolean,
}

local CORNER_SIGNS: { Vector3 } = {}
for x = -1, 1, 2 do
	for y = -1, 1, 2 do
		for z = -1, 1, 2 do
			table.insert(CORNER_SIGNS, Vector3.new(x, y, z))
		end
	end
end

-- Turns the current selection into a list of things to render. Clicking a part picks its model,
-- and selecting a folder picks every pet inside it.
local function resolveTargets(selected: { Instance }): { Instance }
	local targets: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	local function add(instance: Instance)
		if not seen[instance] and #targets < MAX_TARGETS then
			seen[instance] = true
			table.insert(targets, instance)
		end
	end

	local function visit(instance: Instance, depth: number)
		if instance == workspace or instance.Parent == game then
			return -- never try to render the whole map or a whole service
		elseif instance:IsA("Model") then
			add(instance)
		elseif instance:IsA("BasePart") then
			if instance:IsA("Terrain") then
				return
			end
			local model = instance:FindFirstAncestorWhichIsA("Model")
			add(if model and model ~= workspace then model else instance)
		elseif instance:IsA("Accessory") then
			if instance:FindFirstChildWhichIsA("BasePart", true) then
				add(instance)
			end
		elseif instance:IsA("Folder") and depth < 3 then
			for _, child in instance:GetChildren() do
				visit(child, depth + 1)
			end
		end
	end

	for _, instance in selected do
		visit(instance, 0)
	end
	return targets
end

local function collectParts(target: Instance): { BasePart }
	local parts: { BasePart } = {}
	if target:IsA("BasePart") then
		table.insert(parts, target)
	end
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function addCorners(part: BasePart, out: { Vector3 })
	local cframe, half = part.CFrame, part.Size / 2
	for _, sign in CORNER_SIGNS do
		table.insert(out, cframe * (half * sign))
	end
end

local function getBasis(target: Instance, parts: { BasePart }): CFrame
	if target:IsA("PVInstance") then
		return target:GetPivot()
	end
	local handle = target:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		return handle.CFrame
	end
	return if parts[1] then parts[1].CFrame else CFrame.identity
end

local function buildSubject(target: Instance): (Subject?, string?)
	local parts = collectParts(target)
	if #parts == 0 then
		return nil, `"{target.Name}" has no parts to render`
	elseif #parts > MAX_PARTS then
		return nil, `"{target.Name}" has too many parts ({#parts}). Select a single pet.`
	end

	-- Invisible hitboxes and root parts would make the pet look tiny, so frame visible parts only
	local points: { Vector3 } = {}
	for _, part in parts do
		if part.Transparency < 0.98 then
			addCorners(part, points)
		end
	end
	if #points == 0 then
		for _, part in parts do
			addCorners(part, points)
		end
	end

	local low, high = points[1], points[1]
	for _, point in points do
		low = low:Min(point)
		high = high:Max(point)
	end

	return {
		target = target,
		basis = getBasis(target, parts),
		center = (low + high) / 2,
		points = points,
		partCount = #parts,
	}, nil
end

-- Places the camera at the chosen angle (relative to the pet's front) as close as possible while
-- still fitting every corner of the pet in a square view.
local function frameSubject(subject: Subject, yaw: number, pitch: number, zoom: number): Shot
	local rotation = subject.basis.Rotation
		* CFrame.Angles(0, math.rad(180 + yaw), 0)
		* CFrame.Angles(math.rad(-pitch), 0, 0)
	local tanHalf = math.tan(math.rad(FOV / 2)) * (1 - FRAME_MARGIN)

	local relative: { Vector3 } = table.create(#subject.points)
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for i, point in subject.points do
		local v = rotation:VectorToObjectSpace(point - subject.center)
		relative[i] = v
		minX, maxX = math.min(minX, v.X), math.max(maxX, v.X)
		minY, maxY = math.min(minY, v.Y), math.max(maxY, v.Y)
	end

	-- Centre the pet on screen, then back up until every corner is inside the view
	local offset = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, 0)
	local distance, minZ, maxZ = 0, math.huge, -math.huge
	for _, v in relative do
		local w = v - offset
		distance = math.max(distance, math.abs(w.X) / tanHalf + w.Z, math.abs(w.Y) / tanHalf + w.Z)
		minZ, maxZ = math.min(minZ, w.Z), math.max(maxZ, w.Z)
	end
	distance = math.max(distance / zoom, maxZ + 0.1)

	local focus = subject.center + rotation:VectorToWorldSpace(offset)
	return {
		cframe = CFrame.new(focus) * rotation * CFrame.new(0, 0, distance),
		distance = distance,
		nearDepth = distance - maxZ,
		farDepth = distance - minZ,
	}
end

-- Makes a copy that's safe to render: no scripts, sounds or name tags, everything anchored.
local function makeRenderCopy(target: Instance): Model
	local wasArchivable = target.Archivable
	if not wasArchivable then
		target.Archivable = true
	end
	local copy = target:Clone()
	if not wasArchivable then
		target.Archivable = false
	end
	if not copy then
		error(`Couldn't copy "{target.Name}"`, 0)
	end

	local model: Model
	if copy:IsA("Model") then
		model = copy
	else
		model = Instance.new("Model")
		model.Name = target.Name
		copy.Parent = model
	end

	for _, descendant in model:GetDescendants() do
		if
			descendant:IsA("LuaSourceContainer")
			or descendant:IsA("Sound")
			or descendant:IsA("BillboardGui")
			or descendant:IsA("ProximityPrompt")
		then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.Locked = true
			if descendant:IsA("MeshPart") then
				pcall(function()
					descendant.RenderFidelity = Enum.RenderFidelity.Precise
				end)
			end
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	return model
end

--------------------------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------------------------

type Stage = {
	folder: Folder,
	model: Model,
	backdrop: Part,
	fill: Frame,
	transform: CFrame, -- maps the subject's original space onto the stage
}

local activeStage: Stage? = nil
local activeRestore: (() -> ())? = nil

-- Temporarily switches off everything that would get in the way of a clean screenshot (UI,
-- post effects, fog, clouds and optionally the place's own lighting). Returns a function that
-- puts it all back.
local function beginSession(): () -> ()
	local camera = workspace.CurrentCamera
	local undo: { () -> () } = {}

	local function set(instance: Instance, property: string, value: any)
		local target: any = instance
		local readOk, old = pcall(function()
			return target[property]
		end)
		if readOk and old ~= value and pcall(function()
			target[property] = value
		end) then
			table.insert(undo, function()
				target[property] = old
			end)
		end
	end

	set(camera, "CameraType", Enum.CameraType.Scriptable)
	local cameraCFrame, cameraFocus, cameraFov = camera.CFrame, camera.Focus, camera.FieldOfView
	table.insert(undo, function()
		camera.CFrame = cameraCFrame
		camera.Focus = cameraFocus
		camera.FieldOfView = cameraFov
	end)

	set(StarterGui, "ShowDevelopmentGui", false)
	pcall(function()
		-- Overlays drawn by other plugins
		for _, child in CoreGui:GetChildren() do
			if child:IsA("ScreenGui") then
				set(child, "Enabled", false)
			end
		end
	end)
	set(Lighting, "FogEnd", 1e6)
	for _, container in { Lighting :: Instance, camera } do
		for _, child in container:GetChildren() do
			if child:IsA("PostEffect") then
				set(child, "Enabled", false)
			elseif child:IsA("Atmosphere") then
				set(child, "Density", 0)
				set(child, "Haze", 0)
				set(child, "Glare", 0)
			end
		end
	end
	for _, child in workspace.Terrain:GetChildren() do
		if child:IsA("Clouds") then
			set(child, "Enabled", false)
		end
	end
	if config.studioLighting then
		for property, value in STUDIO_LIGHTING do
			set(Lighting, property, value)
		end
	end

	return function()
		for i = #undo, 1, -1 do
			pcall(undo[i])
		end
	end
end

local function runCaptureSession<T>(callback: () -> T): T
	if RunService:IsRunning() then
		error("Stop the playtest first. Rendering only works in edit mode.", 0)
	end
	local restore = beginSession()
	activeRestore = restore
	local ok, result = pcall(callback)
	activeRestore = nil
	restore()
	if not ok then
		error(result, 0)
	end
	return result
end

local function headingOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

-- The pet is rendered far away at the stage, turned so the sun always lights it from the front
-- (behind the camera, a bit to the side). That keeps the lighting the same for every pet.
local function stageTransform(cameraCFrame: CFrame): CFrame
	local heading = headingOf(cameraCFrame.LookVector)
	local targetHeading = heading
	local sun = Lighting:GetSunDirection()
	local flat = Vector3.new(sun.X, 0, sun.Z)
	if flat.Magnitude > 1e-3 then
		targetHeading = headingOf(-flat) + SUN_SIDE_ANGLE
	end
	local staged = CFrame.new(STAGE_POSITION) * CFrame.Angles(0, targetHeading - heading, 0) * cameraCFrame.Rotation
	return staged * cameraCFrame:Inverse()
end

local function buildStage(subject: Subject, shot: Shot): Stage
	local folder = Instance.new("Folder")
	folder.Name = STAGE_NAME
	folder.Archivable = false

	local transform = stageTransform(shot.cframe)
	local model = makeRenderCopy(subject.target)
	model:PivotTo(transform * model:GetPivot())
	model.Parent = folder

	-- A GUI ignores lighting and doesn't catch shadows, so the backdrop is always exactly one colour
	local backdrop = Instance.new("Part")
	backdrop.Name = "Backdrop"
	backdrop.Anchored = true
	backdrop.CanCollide = false
	backdrop.CanQuery = false
	backdrop.CanTouch = false
	backdrop.CastShadow = false
	backdrop.Locked = true
	backdrop.Transparency = 1
	backdrop.Parent = folder

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.Brightness = 1
	gui.AlwaysOnTop = false
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(64, 64) -- it's one solid colour, no need for resolution
	pcall(function()
		gui.MaxDistance = 1e6
	end)
	gui.Parent = backdrop

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Color3.new(0, 0, 0)
	fill.Parent = gui

	folder.Parent = workspace
	return { folder = folder, model = model, backdrop = backdrop, fill = fill, transform = transform }
end

local function captureScreen(): EditableImage
	local contentId: string? = nil
	CaptureService:CaptureScreenshot(function(id)
		contentId = id
	end)
	local waited = 0
	while not contentId do
		if waited > CAPTURE_TIMEOUT then
			error("Taking a screenshot timed out. Keep the 3D viewport visible (not a script tab) while rendering.", 0)
		end
		waited += task.wait()
	end
	return AssetService:CreateEditableImageAsync(Content.fromUri(contentId :: string))
end

local function waitFrames(count: number)
	for _ = 1, count do
		task.wait()
	end
end

-- Works out the pet's colour and transparency for every pixel from the black and white shots.
-- On black a pixel is  alpha * colour + (1 - alpha) * black,  on white it's the same with white,
-- so the difference between the two shots tells us the alpha.
local function extractAlpha(black: buffer, white: buffer, side: number, bgBlack: { number }, bgWhite: { number }): Capture
	local pixels = buffer.create(side * side * 4)
	local kr, kg, kb = bgBlack[1], bgBlack[2], bgBlack[3]
	local spread = (bgWhite[1] - kr) + (bgWhite[2] - kg) + (bgWhite[3] - kb)
	local minX, minY, maxX, maxY = side, side, -1, -1

	for y = 0, side - 1 do
		local row = y * side
		for x = 0, side - 1 do
			local i = (row + x) * 4
			local r, g, b = buffer.readu8(black, i), buffer.readu8(black, i + 1), buffer.readu8(black, i + 2)
			local difference = (buffer.readu8(white, i) - r)
				+ (buffer.readu8(white, i + 1) - g)
				+ (buffer.readu8(white, i + 2) - b)
			local alpha = 1 - difference / spread
			if alpha >= ALPHA_CUTOFF then
				if alpha > 1 - ALPHA_CUTOFF then
					alpha = 1
				end
				local rest = 1 - alpha
				buffer.writeu8(pixels, i, math.clamp(math.floor((r - rest * kr) / alpha + 0.5), 0, 255))
				buffer.writeu8(pixels, i + 1, math.clamp(math.floor((g - rest * kg) / alpha + 0.5), 0, 255))
				buffer.writeu8(pixels, i + 2, math.clamp(math.floor((b - rest * kb) / alpha + 0.5), 0, 255))
				buffer.writeu8(pixels, i + 3, math.floor(alpha * 255 + 0.5))
				minX, maxX = math.min(minX, x), math.max(maxX, x)
				minY, maxY = math.min(minY, y), math.max(maxY, y)
			end
		end
		if y % 256 == 255 then
			task.wait()
		end
	end

	local bounds: Bounds? = nil
	if maxX >= 0 then
		bounds = { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
	end
	return { pixels = pixels, side = side, bounds = bounds }
end

local function readColor(image: EditableImage, position: Vector2): { number }
	local pixel = image:ReadPixelsBuffer(position, Vector2.one)
	return { buffer.readu8(pixel, 0), buffer.readu8(pixel, 1), buffer.readu8(pixel, 2) }
end

type Cropped = { black: buffer, white: buffer, side: number, bgBlack: { number }, bgWhite: { number } }

-- Cuts the middle square out of both shots and measures the backdrop colours
local function cropShots(onBlack: EditableImage, onWhite: EditableImage): (Cropped?, string?)
	local size = onBlack.Size
	if onWhite.Size ~= size then
		return nil, "The viewport changed size while rendering. Try again."
	end
	local side = math.min(size.X, size.Y)
	local origin = Vector2.new((size.X - side) // 2, (size.Y - side) // 2)

	-- Studio overlays (like the view cube) and the pet look the same in both shots, so the sample
	-- that changed the most between them is pure backdrop.
	local samples = {
		Vector2.zero,
		Vector2.new(size.X - 1, 0),
		Vector2.new(0, size.Y - 1),
		Vector2.new(size.X - 1, size.Y - 1),
		Vector2.new(0, size.Y // 2),
		Vector2.new(size.X - 1, size.Y // 2),
		origin,
		origin + Vector2.new(side - 1, 0),
		origin + Vector2.new(0, side - 1),
		origin + Vector2.new(side - 1, side - 1),
	}
	local bestSpread, bgBlack, bgWhite = -math.huge, { 0, 0, 0 }, { 255, 255, 255 }
	for _, position in samples do
		local k, w = readColor(onBlack, position), readColor(onWhite, position)
		local spread = (w[1] - k[1]) + (w[2] - k[2]) + (w[3] - k[3])
		if spread > bestSpread then
			bestSpread, bgBlack, bgWhite = spread, k, w
		end
	end
	if bestSpread < 300 then
		return nil, "Couldn't separate the pet from the background. Make sure the 3D viewport is visible and try again."
	end

	local square = Vector2.new(side, side)
	return {
		black = onBlack:ReadPixelsBuffer(origin, square),
		white = onWhite:ReadPixelsBuffer(origin, square),
		side = side,
		bgBlack = bgBlack,
		bgWhite = bgWhite,
	}, nil
end

local function captureShot(stage: Stage, shot: Shot): Capture
	local camera = workspace.CurrentCamera
	local viewport = camera.ViewportSize
	if math.min(viewport.X, viewport.Y) < 64 then
		error("The 3D viewport is too small to render in. Make it bigger and try again.", 0)
	end

	-- The icon is cut from the middle square of the viewport, so set the field of view so that
	-- square sees exactly FOV degrees, the same as the preview.
	local squareFraction = math.min(viewport.X, viewport.Y) / viewport.Y
	local fullFov = math.clamp(2 * math.deg(math.atan(math.tan(math.rad(FOV / 2)) / squareFraction)), 1, 120)
	local cameraCFrame = stage.transform * shot.cframe
	camera.FieldOfView = fullFov
	camera.CFrame = cameraCFrame
	camera.Focus = cameraCFrame * CFrame.new(0, 0, -shot.distance)

	-- Put the backdrop just behind the pet, big enough to cover the whole viewport
	local depth = shot.farDepth + math.max(1, shot.farDepth * 0.25)
	local halfHeight = depth * math.tan(math.rad(fullFov / 2)) * 1.3
	local halfWidth = halfHeight * viewport.X / viewport.Y
	stage.backdrop.Size = Vector3.new(math.min(halfWidth * 2, 2048), math.min(halfHeight * 2, 2048), 0.05)
	stage.backdrop.CFrame = cameraCFrame * CFrame.new(0, 0, -depth) * CFrame.Angles(0, math.pi, 0)

	stage.fill.BackgroundColor3 = Color3.new(0, 0, 0)
	waitFrames(4)
	local onBlack = captureScreen()
	stage.fill.BackgroundColor3 = Color3.new(1, 1, 1)
	waitFrames(4)
	local ok, onWhite = pcall(captureScreen)
	if not ok then
		onBlack:Destroy()
		error(onWhite, 0)
	end

	local cropOk, cropped, problem = pcall(cropShots, onBlack, onWhite)
	-- Free the full-screen shots before the slow per-pixel work
	onBlack:Destroy()
	onWhite:Destroy()
	if not cropOk then
		error(cropped, 0)
	elseif not cropped then
		error(problem, 0)
	end
	return extractAlpha(cropped.black, cropped.white, cropped.side, cropped.bgBlack, cropped.bgWhite)
end

-- Fixes the framing after a test shot: backs up if part of the pet went off screen (e.g. a
-- SpecialMesh that's bigger than its part), or moves closer if the pet came out tiny.
local function refineShot(shot: Shot, capture: Capture): Shot?
	local bounds = capture.bounds
	if not bounds then
		return nil
	end
	local side = capture.side
	local touchesEdge = bounds.minX <= 0 or bounds.minY <= 0 or bounds.maxX >= side - 1 or bounds.maxY >= side - 1
	if touchesEdge then
		local back = shot.distance * 0.75
		return {
			cframe = shot.cframe * CFrame.new(0, 0, back),
			distance = shot.distance + back,
			nearDepth = shot.nearDepth + back,
			farDepth = shot.farDepth + back,
		}
	end

	local extent = math.max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY) + 1
	if extent >= side * 0.6 then
		return nil
	end
	local half = side / 2
	local tanHalf = math.tan(math.rad(FOV / 2))
	local shiftX = ((bounds.minX + bounds.maxX + 1) / 2 - half) / half * shot.distance * tanHalf
	local shiftY = (half - (bounds.minY + bounds.maxY + 1) / 2) / half * shot.distance * tanHalf
	local forward = math.min(shot.distance - shot.distance * extent / (side * 0.85), shot.nearDepth - 0.2)
	if forward <= 0 then
		return nil
	end
	return {
		cframe = shot.cframe * CFrame.new(shiftX, shiftY, -forward),
		distance = shot.distance - forward,
		nearDepth = shot.nearDepth - forward,
		farDepth = shot.farDepth - forward,
	}
end

-- Resizes the square region (x0, y0, box) of the capture to size x size. Shrinking averages
-- every source pixel (smooth edges); enlarging uses bilinear filtering.
local function resample(source: buffer, side: number, x0: number, y0: number, box: number, size: number): buffer
	local out = buffer.create(size * size * 4)
	local step = box / size

	if step >= 1 then
		local columnStart: { number } = table.create(size)
		local columnEnd: { number } = table.create(size)
		for o = 0, size - 1 do
			local a = math.floor(x0 + o * step)
			columnStart[o + 1] = a
			columnEnd[o + 1] = math.max(a + 1, math.floor(x0 + (o + 1) * step))
		end

		for oy = 0, size - 1 do
			local ya = math.floor(y0 + oy * step)
			local yb = math.max(ya + 1, math.floor(y0 + (oy + 1) * step))
			local yFirst, yLast = math.max(ya, 0), math.min(yb, side) - 1
			for ox = 0, size - 1 do
				local xa, xb = columnStart[ox + 1], columnEnd[ox + 1]
				local xFirst, xLast = math.max(xa, 0), math.min(xb, side) - 1
				local sa, sr, sg, sb = 0, 0, 0, 0
				for sy = yFirst, yLast do
					local row = sy * side
					for sx = xFirst, xLast do
						local i = (row + sx) * 4
						local a = buffer.readu8(source, i + 3)
						if a > 0 then
							sa += a
							sr += buffer.readu8(source, i) * a
							sg += buffer.readu8(source, i + 1) * a
							sb += buffer.readu8(source, i + 2) * a
						end
					end
				end
				if sa > 0 then
					local o = (oy * size + ox) * 4
					buffer.writeu8(out, o, math.floor(sr / sa + 0.5))
					buffer.writeu8(out, o + 1, math.floor(sg / sa + 0.5))
					buffer.writeu8(out, o + 2, math.floor(sb / sa + 0.5))
					buffer.writeu8(out, o + 3, math.floor(sa / ((yb - ya) * (xb - xa)) + 0.5))
				end
			end
			if oy % 128 == 127 then
				task.wait()
			end
		end
	else
		local function texel(x: number, y: number): (number, number, number, number)
			if x < 0 or y < 0 or x >= side or y >= side then
				return 0, 0, 0, 0
			end
			local i = (y * side + x) * 4
			local a = buffer.readu8(source, i + 3)
			return buffer.readu8(source, i) * a, buffer.readu8(source, i + 1) * a, buffer.readu8(source, i + 2) * a, a
		end

		for oy = 0, size - 1 do
			local fy = y0 + (oy + 0.5) * step - 0.5
			local y = math.floor(fy)
			local ty = fy - y
			for ox = 0, size - 1 do
				local fx = x0 + (ox + 0.5) * step - 0.5
				local x = math.floor(fx)
				local tx = fx - x
				local r1, g1, b1, a1 = texel(x, y)
				local r2, g2, b2, a2 = texel(x + 1, y)
				local r3, g3, b3, a3 = texel(x, y + 1)
				local r4, g4, b4, a4 = texel(x + 1, y + 1)
				local w1, w2, w3, w4 = (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty
				local a = a1 * w1 + a2 * w2 + a3 * w3 + a4 * w4
				if a > 0 then
					local o = (oy * size + ox) * 4
					buffer.writeu8(out, o, math.clamp(math.floor((r1 * w1 + r2 * w2 + r3 * w3 + r4 * w4) / a + 0.5), 0, 255))
					buffer.writeu8(out, o + 1, math.clamp(math.floor((g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / a + 0.5), 0, 255))
					buffer.writeu8(out, o + 2, math.clamp(math.floor((b1 * w1 + b2 * w2 + b3 * w3 + b4 * w4) / a + 0.5), 0, 255))
					buffer.writeu8(out, o + 3, math.clamp(math.floor(a + 0.5), 0, 255))
				end
			end
			if oy % 128 == 127 then
				task.wait()
			end
		end
	end
	return out
end

-- Transparent pixels still have a colour, and when Roblox scales the icon down it blends that
-- colour into the edges. Copying edge colours outwards (and the pet's average colour everywhere
-- else) stops the dark outline you'd otherwise get.
local function bleedEdges(pixels: buffer, size: number)
	local count = size * size
	local filled = buffer.create(count)
	local queued = buffer.create(count)
	local sumR, sumG, sumB, visible = 0, 0, 0, 0

	for p = 0, count - 1 do
		local i = p * 4
		if buffer.readu8(pixels, i + 3) > 0 then
			buffer.writeu8(filled, p, 1)
			sumR += buffer.readu8(pixels, i)
			sumG += buffer.readu8(pixels, i + 1)
			sumB += buffer.readu8(pixels, i + 2)
			visible += 1
		end
	end
	if visible == 0 then
		return
	end

	local function enqueueNeighbours(p: number, list: { number })
		local x = p % size
		local neighbours = {
			if x > 0 then p - 1 else -1,
			if x < size - 1 then p + 1 else -1,
			p - size,
			p + size,
		}
		for _, q in neighbours do
			if q >= 0 and q < count and buffer.readu8(filled, q) == 0 and buffer.readu8(queued, q) == 0 then
				buffer.writeu8(queued, q, 1)
				table.insert(list, q)
			end
		end
	end

	local frontier: { number } = {}
	for p = 0, count - 1 do
		if buffer.readu8(filled, p) == 1 then
			enqueueNeighbours(p, frontier)
		end
	end

	for _ = 1, BLEED_PASSES do
		local colors: { number } = table.create(#frontier * 3, 0)
		for n, p in frontier do
			local x = p % size
			local r, g, b, found = 0, 0, 0, 0
			for dy = -1, 1 do
				for dx = -1, 1 do
					local qx, q = x + dx, p + dy * size + dx
					if qx >= 0 and qx < size and q >= 0 and q < count and buffer.readu8(filled, q) == 1 then
						local i = q * 4
						r += buffer.readu8(pixels, i)
						g += buffer.readu8(pixels, i + 1)
						b += buffer.readu8(pixels, i + 2)
						found += 1
					end
				end
			end
			local c = (n - 1) * 3
			colors[c + 1], colors[c + 2], colors[c + 3] = r / found, g / found, b / found
		end

		local nextFrontier: { number } = {}
		for n, p in frontier do
			local i, c = p * 4, (n - 1) * 3
			buffer.writeu8(pixels, i, math.floor(colors[c + 1] + 0.5))
			buffer.writeu8(pixels, i + 1, math.floor(colors[c + 2] + 0.5))
			buffer.writeu8(pixels, i + 2, math.floor(colors[c + 3] + 0.5))
			buffer.writeu8(filled, p, 1)
		end
		for _, p in frontier do
			enqueueNeighbours(p, nextFrontier)
		end
		frontier = nextFrontier
	end

	local avgR = math.floor(sumR / visible + 0.5)
	local avgG = math.floor(sumG / visible + 0.5)
	local avgB = math.floor(sumB / visible + 0.5)
	for p = 0, count - 1 do
		if buffer.readu8(filled, p) == 0 then
			local i = p * 4
			buffer.writeu8(pixels, i, avgR)
			buffer.writeu8(pixels, i + 1, avgG)
			buffer.writeu8(pixels, i + 2, avgB)
		end
	end
end

local function composeIcon(capture: Capture, manualZoom: boolean): Render
	local bounds = capture.bounds
	if not bounds then
		error("Nothing showed up in the render. Is the model invisible?", 0)
	end

	local size = config.size
	local x0, y0, box = 0, 0, capture.side
	if not manualZoom then
		-- Auto-fit: crop tightly around the pet, then add the padding back evenly on every side
		local width = bounds.maxX - bounds.minX + 1
		local height = bounds.maxY - bounds.minY + 1
		box = math.max(width, height) / (1 - 2 * config.padding)
		x0 = (bounds.minX + bounds.maxX + 1) / 2 - box / 2
		y0 = (bounds.minY + bounds.maxY + 1) / 2 - box / 2
	end

	local pixels = resample(capture.pixels, capture.side, x0, y0, box, size)
	bleedEdges(pixels, size)

	local image = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	if not image then
		error("Roblox refused to create the image (out of EditableImage memory). Restart Studio and try again.", 0)
	end
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), pixels)

	local sourceSize = math.floor(box + 0.5)
	return {
		image = image,
		info = `{size}x{size}, rendered from {sourceSize}px`,
		upscaled = sourceSize < size,
	}
end

local function renderSubject(subject: Subject): Render
	local manualZoom = config.zoom > 1.001
	local shot = frameSubject(subject, config.yaw, config.pitch, config.zoom)
	local stage = buildStage(subject, shot)
	activeStage = stage

	local ok, result = pcall(function(): Capture
		pcall(function()
			ContentProvider:PreloadAsync({ stage.model })
		end)

		local emitters: { ParticleEmitter } = {}
		for _, descendant in stage.model:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				table.insert(emitters, descendant)
			end
		end
		task.wait(if #emitters > 0 then math.max(SETTLE_TIME, PARTICLE_WARMUP) else SETTLE_TIME)
		for _, emitter in emitters do
			emitter.TimeScale = 0 -- freeze particles so both screenshots match
		end

		local capture = captureShot(stage, shot)
		if not manualZoom then
			for _ = 1, 2 do
				local refined = refineShot(shot, capture)
				if not refined then
					break
				end
				shot = refined
				capture = captureShot(stage, shot)
			end
		end
		return capture
	end)

	activeStage = nil
	stage.folder:Destroy()
	if not ok then
		error(result, 0)
	end
	return composeIcon(result, manualZoom)
end

local function renderTarget(target: Instance): Render
	local subject, problem = buildSubject(target)
	if not subject then
		error(problem, 0)
	end
	return renderSubject(subject)
end

--------------------------------------------------------------------------------------------------
-- Uploading
--------------------------------------------------------------------------------------------------

local function uploadImage(image: EditableImage, name: string): number
	local request: { [string]: any } = {
		Name = string.sub(`{name} Icon`, 1, 50),
		Description = "Inventory icon made with the Pet Icon Uploader plugin.",
	}
	if config.creator == "Group" then
		if config.groupId <= 0 then
			error("Type your group ID in the box next to Group (or switch to Me).", 0)
		end
		request.CreatorId = config.groupId
		request.CreatorType = Enum.AssetCreatorType.Group
	end

	local ok, result, value = pcall(function()
		return AssetService:CreateAssetAsync(image, Enum.AssetType.Image, request)
	end)
	if not ok then
		error(`Upload failed: {result}`, 0)
	elseif result ~= Enum.CreateAssetResult.Success then
		error(`Upload failed ({tostring(result)}): {tostring(value)}`, 0)
	end
	return tonumber(value) :: number
end

local function saveIconAttribute(target: Instance, assetUri: string): boolean
	local recording = ChangeHistoryService:TryBeginRecording("PetIconUploader", "Set pet icon")
	local ok = pcall(function()
		target:SetAttribute(ATTRIBUTE_NAME, assetUri)
	end)
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	return ok
end

--------------------------------------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------------------------------------

local Color = Enum.StudioStyleGuideColor

type ThemeBinding = { instance: Instance, property: string, color: Enum.StudioStyleGuideColor }
local themeBindings: { ThemeBinding } = {}
local themeRefreshers: { () -> () } = {}

local function getTheme(): StudioTheme
	return settings().Studio.Theme :: StudioTheme
end

local function bindColor(instance: Instance, property: string, color: Enum.StudioStyleGuideColor)
	table.insert(themeBindings, { instance = instance, property = property, color = color })
	local target: any = instance
	target[property] = getTheme():GetColor(color)
end

local function applyTheme()
	local theme = getTheme()
	for _, binding in themeBindings do
		local target: any = binding.instance
		target[binding.property] = theme:GetColor(binding.color)
	end
	for _, refresh in themeRefreshers do
		refresh()
	end
end

local function create(className: string, properties: { [string]: any }?, parent: Instance?): any
	local instance: any = Instance.new(className)
	if properties then
		for key, value in properties do
			instance[key] = value
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function corner(parent: Instance, radius: number)
	create("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function makeLabel(parent: Instance, text: string, properties: { [string]: any }?, color: Enum.StudioStyleGuideColor?): any
	local label = create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		Text = text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	if properties then
		for key, value in properties do
			label[key] = value
		end
	end
	bindColor(label, "TextColor3", color or Color.MainText)
	return label
end

local function makeButton(parent: Instance, text: string, size: UDim2, primary: boolean?): any
	local button = create("TextButton", {
		AutoButtonColor = true,
		BorderSizePixel = 0,
		Size = size,
		Text = text,
		TextSize = 14,
	}, parent)
	corner(button, 4)
	local stroke = create("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, button)
	bindColor(button, "BackgroundColor3", if primary then Color.DialogMainButton else Color.Button)
	bindColor(button, "TextColor3", if primary then Color.DialogMainButtonText else Color.ButtonText)
	bindColor(stroke, "Color", if primary then Color.DialogMainButton else Color.ButtonBorder)
	return button
end

local function setButtonEnabled(button: any, enabled: boolean)
	button.Interactable = enabled
	button.TextTransparency = if enabled then 0 else 0.6
	button.BackgroundTransparency = if enabled then 0 else 0.5
end

local function makeRow(parent: Instance, height: number, order: number): any
	local row = create("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, height),
	}, parent)
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, row)
	return row
end

-- Width of one of `count` equal items in a row with 6px gaps
local function share(count: number, height: number?): UDim2
	return UDim2.new(1 / count, -6 * (count - 1) / count, 0, height or 26)
end

local function makeSegmented(parent: Instance, labels: { string }, isSelected: (number) -> boolean, onSelect: (number) -> ()): () -> ()
	local entries: { { button: any, stroke: any } } = {}
	for i, text in labels do
		local button = create("TextButton", {
			AutoButtonColor = true,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Size = share(#labels),
			Text = text,
			TextSize = 13,
		}, parent)
		corner(button, 4)
		local stroke = create("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, button)
		entries[i] = { button = button, stroke = stroke }
		button.Activated:Connect(function()
			onSelect(i)
		end)
	end

	local function refresh()
		local theme = getTheme()
		for i, entry in entries do
			local selected = isSelected(i)
			entry.button.BackgroundColor3 = theme:GetColor(if selected then Color.DialogMainButton else Color.Button)
			entry.button.TextColor3 = theme:GetColor(if selected then Color.DialogMainButtonText else Color.ButtonText)
			entry.stroke.Color = theme:GetColor(if selected then Color.DialogMainButton else Color.ButtonBorder)
		end
	end
	table.insert(themeRefreshers, refresh)
	refresh()
	return refresh
end

local function makeCheckbox(parent: Instance, text: string, order: number, get: () -> boolean, set: (boolean) -> ())
	local button = create("TextButton", {
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 20),
		Text = "",
	}, parent)
	local box = create("Frame", {
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0.5, -8),
		Size = UDim2.fromOffset(16, 16),
	}, button)
	corner(box, 3)
	local stroke = create("UIStroke", {}, box)
	local mark = create("Frame", {
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.fromOffset(8, 8),
	}, box)
	corner(mark, 2)
	makeLabel(button, text, { Position = UDim2.fromOffset(24, 0), Size = UDim2.new(1, -24, 1, 0) })
	bindColor(box, "BackgroundColor3", Color.CheckedFieldBackground)
	bindColor(stroke, "Color", Color.CheckedFieldBorder)
	bindColor(mark, "BackgroundColor3", Color.CheckedFieldIndicator)

	local function refresh()
		mark.Visible = get()
	end
	refresh()
	button.Activated:Connect(function()
		set(not get())
		refresh()
	end)
end

local function makeCheckerContent(): Content?
	local ok, image = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(2, 2) })
	end)
	if not ok or not image then
		return nil
	end
	local pixels = buffer.create(16)
	for i = 0, 3 do
		local shade = if i == 0 or i == 3 then 205 else 165
		buffer.writeu8(pixels, i * 4, shade)
		buffer.writeu8(pixels, i * 4 + 1, shade)
		buffer.writeu8(pixels, i * 4 + 2, shade)
		buffer.writeu8(pixels, i * 4 + 3, 255)
	end
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(2, 2), pixels)
	return Content.fromObject(image)
end

--------------------------------------------------------------------------------------------------
-- Widget
--------------------------------------------------------------------------------------------------

-- Clean up a stage left behind if Studio or the plugin crashed mid-render
for _, child in workspace:GetChildren() do
	if child.Name == STAGE_NAME then
		child:Destroy()
	end
end

local toolbar = plugin:CreateToolbar("Pet Icons")
local toggleButton = toolbar:CreateButton(
	"PetIconUploader",
	"Render pet models and upload them as inventory icons",
	"",
	"Pet Icon Uploader"
)
toggleButton.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"PetIconUploader",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 320, 680, 260, 400)
)
widget.Title = "Pet Icon Uploader"
widget.Name = "PetIconUploader"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local root = create("ScrollingFrame", {
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 6,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Size = UDim2.fromScale(1, 1),
}, widget)
bindColor(root, "BackgroundColor3", Color.MainBackground)
bindColor(root, "ScrollBarImageColor3", Color.ScrollBar)
create("UIPadding", {
	PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 10),
	PaddingRight = UDim.new(0, 12),
	PaddingTop = UDim.new(0, 10),
}, root)
create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, root)

local layoutOrder = 0
local function nextOrder(): number
	layoutOrder += 1
	return layoutOrder
end

-- Preview ---------------------------------------------------------------------------------------

local previewHolder = create("Frame", {
	BackgroundTransparency = 1,
	LayoutOrder = nextOrder(),
	Size = UDim2.new(1, 0, 0, 240),
}, root)

local viewport = create("ViewportFrame", {
	Active = true,
	Ambient = Color3.fromRGB(150, 150, 150),
	AnchorPoint = Vector2.new(0.5, 0),
	BorderSizePixel = 0,
	LightColor = Color3.fromRGB(235, 235, 235),
	Position = UDim2.fromScale(0.5, 0),
	Size = UDim2.fromOffset(240, 240),
}, previewHolder)
corner(viewport, 6)
bindColor(viewport, "BackgroundColor3", Color.ViewPortBackground)

local previewCamera = Instance.new("Camera")
previewCamera.FieldOfView = FOV
previewCamera.Parent = viewport
viewport.CurrentCamera = previewCamera

local previewWorld = Instance.new("WorldModel")
previewWorld.Parent = viewport

local previewHint = makeLabel(viewport, "Select a pet model\n(click it in the viewport or the Explorer)", {
	Size = UDim2.new(1, -20, 1, 0),
	Position = UDim2.fromOffset(10, 0),
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Center,
}, Color.DimmedText)

local dragHint = makeLabel(viewport, "Drag to rotate · Scroll to zoom", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 8, 1, -4),
	Size = UDim2.new(1, -16, 0, 16),
	TextSize = 12,
}, Color.DimmedText)

local zoomLabel = makeLabel(viewport, "Auto-fit", {
	Position = UDim2.fromOffset(8, 4),
	Size = UDim2.new(1, -16, 0, 16),
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Right,
}, Color.DimmedText)

-- Covers the whole widget while dragging so the rotation keeps going when the mouse leaves the preview
local dragCatcher = create("Frame", {
	Active = true,
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	Visible = false,
	ZIndex = 100,
}, widget)

-- Target picker ---------------------------------------------------------------------------------

local targetRow = makeRow(root, 26, nextOrder())
local previousButton = makeButton(targetRow, "<", UDim2.fromOffset(26, 26))
previousButton.LayoutOrder = 1
local targetLabel = makeLabel(targetRow, "Nothing selected", {
	LayoutOrder = 2,
	Size = UDim2.new(1, -64, 1, 0),
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextXAlignment = Enum.TextXAlignment.Center,
})
local nextButton = makeButton(targetRow, ">", UDim2.fromOffset(26, 26))
nextButton.LayoutOrder = 3

-- Angle presets ---------------------------------------------------------------------------------

local presetRow = makeRow(root, 26, nextOrder())
local presetButtons = {}
for i, preset in PRESETS do
	local button = makeButton(presetRow, preset.label, share(#PRESETS + 1))
	button.LayoutOrder = i
	button.TextSize = 13
	presetButtons[i] = button
end
local flipButton = makeButton(presetRow, "+180°", share(#PRESETS + 1))
flipButton.LayoutOrder = #PRESETS + 1
flipButton.TextSize = 13

-- Options ---------------------------------------------------------------------------------------

local sizeRow = makeRow(root, 26, nextOrder())
makeLabel(sizeRow, "Size", { LayoutOrder = 0, Size = UDim2.new(0, 70, 1, 0) })
local sizeChoices = makeRow(sizeRow, 26, 1)
sizeChoices.Size = UDim2.new(1, -76, 1, 0)

local paddingRow = makeRow(root, 26, nextOrder())
makeLabel(paddingRow, "Padding", { LayoutOrder = 0, Size = UDim2.new(0, 70, 1, 0) })
local paddingControls = makeRow(paddingRow, 26, 1)
paddingControls.Size = UDim2.new(1, -76, 1, 0)
local paddingDown = makeButton(paddingControls, "-", share(3))
paddingDown.LayoutOrder = 1
local paddingLabel = makeLabel(paddingControls, "", {
	LayoutOrder = 2,
	Size = share(3),
	TextXAlignment = Enum.TextXAlignment.Center,
})
local paddingUp = makeButton(paddingControls, "+", share(3))
paddingUp.LayoutOrder = 3

local creatorRow = makeRow(root, 26, nextOrder())
makeLabel(creatorRow, "Upload to", { LayoutOrder = 0, Size = UDim2.new(0, 70, 1, 0) })
local creatorChoices = makeRow(creatorRow, 26, 1)
creatorChoices.Size = UDim2.new(1, -76, 1, 0)

local groupRow = makeRow(root, 26, nextOrder())
makeLabel(groupRow, "Group ID", { LayoutOrder = 0, Size = UDim2.new(0, 70, 1, 0) })
local groupBox = create("TextBox", {
	BorderSizePixel = 0,
	ClearTextOnFocus = false,
	LayoutOrder = 1,
	PlaceholderText = "e.g. 1234567",
	Size = UDim2.new(1, -76, 1, 0),
	Text = if config.groupId > 0 then tostring(config.groupId) else "",
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, groupRow)
corner(groupBox, 4)
create("UIPadding", { PaddingLeft = UDim.new(0, 6) }, groupBox)
bindColor(groupBox, "BackgroundColor3", Color.InputFieldBackground)
bindColor(groupBox, "TextColor3", Color.MainText)
bindColor(groupBox, "PlaceholderColor3", Color.DimmedText)

local checkboxOrder = nextOrder()
local checkboxHolder = create("Frame", {
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = checkboxOrder,
	Size = UDim2.new(1, 0, 0, 0),
}, root)
create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, checkboxHolder)

-- Actions ---------------------------------------------------------------------------------------

local actionRow = makeRow(root, 32, nextOrder())
local renderButton = makeButton(actionRow, "Render", share(2, 32))
renderButton.LayoutOrder = 1
local uploadButton = makeButton(actionRow, "Upload", share(2, 32), true)
uploadButton.LayoutOrder = 2

local uploadAllButton = makeButton(root, "Upload all selected", UDim2.new(1, 0, 0, 32), true)
uploadAllButton.LayoutOrder = nextOrder()

-- Result ----------------------------------------------------------------------------------------

local resultArea = create("Frame", {
	BackgroundTransparency = 1,
	LayoutOrder = nextOrder(),
	Size = UDim2.new(1, 0, 0, 96),
}, root)

local checker = create("ImageLabel", {
	BorderSizePixel = 0,
	ResampleMode = Enum.ResamplerMode.Pixelated,
	ScaleType = Enum.ScaleType.Tile,
	Size = UDim2.fromOffset(96, 96),
	TileSize = UDim2.fromOffset(12, 12),
}, resultArea)
corner(checker, 4)
bindColor(checker, "BackgroundColor3", Color.InputFieldBackground)
local checkerContent = makeCheckerContent()
if checkerContent then
	checker.ImageContent = checkerContent
end

local resultImage = create("ImageLabel", {
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
}, checker)

local resultInfo = makeLabel(resultArea, "No render yet", {
	Position = UDim2.fromOffset(106, 0),
	Size = UDim2.new(1, -106, 0, 34),
	TextSize = 13,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
}, Color.SubText)

local idBox = create("TextBox", {
	BorderSizePixel = 0,
	ClearTextOnFocus = false,
	PlaceholderText = "Asset ID shows up here",
	Position = UDim2.fromOffset(106, 40),
	Size = UDim2.new(1, -106, 0, 26),
	Text = "",
	TextEditable = false,
	TextSize = 13,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextXAlignment = Enum.TextXAlignment.Left,
}, resultArea)
corner(idBox, 4)
create("UIPadding", { PaddingLeft = UDim.new(0, 6) }, idBox)
bindColor(idBox, "BackgroundColor3", Color.InputFieldBackground)
bindColor(idBox, "TextColor3", Color.MainText)
bindColor(idBox, "PlaceholderColor3", Color.DimmedText)

makeLabel(resultArea, "Click the ID, then Ctrl+C", {
	Position = UDim2.fromOffset(106, 70),
	Size = UDim2.new(1, -106, 0, 16),
	TextSize = 12,
}, Color.DimmedText)

local statusLabel = create("TextLabel", {
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = nextOrder(),
	Size = UDim2.new(1, 0, 0, 0),
	Text = "",
	TextSize = 13,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
}, root)

--------------------------------------------------------------------------------------------------
-- State and behaviour
--------------------------------------------------------------------------------------------------

type Result = { target: Instance, key: string, image: EditableImage, info: string, upscaled: boolean }

local targets: { Instance } = {}
local targetIndex = 1
local previewSubject: Subject? = nil
local busy = false
local lastResult: Result? = nil
local dragging = false
local lastDragPosition = Vector2.zero

local function currentTarget(): Instance?
	return targets[targetIndex]
end

-- Everything that changes how a render looks, so we know when an old render is out of date
local function renderKey(): string
	return string.format(
		"%.2f|%.2f|%.3f|%.3f|%d|%s",
		config.yaw,
		config.pitch,
		config.zoom,
		config.padding,
		config.size,
		tostring(config.studioLighting)
	)
end

local statusColor = Color.MainText

local function setStatus(text: string, kind: string?)
	statusLabel.Text = text
	statusColor = if kind == "error" then Color.ErrorText elseif kind == "warning" then Color.WarningText else Color.MainText
	statusLabel.TextColor3 = getTheme():GetColor(statusColor)
end

table.insert(themeRefreshers, function()
	statusLabel.TextColor3 = getTheme():GetColor(statusColor)
end)

local function isResultCurrent(): boolean
	return lastResult ~= nil and lastResult.target == currentTarget() and lastResult.key == renderKey()
end

local function refreshResult()
	if not lastResult then
		resultImage.ImageContent = Content.none
		resultInfo.Text = "No render yet"
		return
	end
	resultImage.ImageContent = Content.fromObject(lastResult.image)
	if isResultCurrent() then
		resultImage.ImageTransparency = 0
		resultInfo.Text = `{lastResult.target.Name}: {lastResult.info}`
	else
		resultImage.ImageTransparency = 0.6
		resultInfo.Text = "Out of date. Upload will render it again."
	end
end

local function showResult(target: Instance, render: Render)
	local old = lastResult
	lastResult = {
		target = target,
		key = renderKey(),
		image = render.image,
		info = render.info,
		upscaled = render.upscaled,
	}
	refreshResult()
	if old and old.image ~= render.image then
		old.image:Destroy()
	end
end

local function refreshControls()
	local hasTarget = currentTarget() ~= nil
	setButtonEnabled(renderButton, hasTarget and not busy)
	setButtonEnabled(uploadButton, hasTarget and not busy)
	setButtonEnabled(uploadAllButton, #targets > 1 and not busy)
	setButtonEnabled(previousButton, #targets > 1)
	setButtonEnabled(nextButton, #targets > 1)
	uploadAllButton.Visible = #targets > 1
	uploadAllButton.Text = `Upload all {#targets} selected`
	groupRow.Visible = config.creator == "Group"
	paddingLabel.Text = `{math.floor(config.padding * 100 + 0.5)}%`

	local target = currentTarget()
	if not target then
		targetLabel.Text = "Nothing selected"
	elseif #targets > 1 then
		targetLabel.Text = `{target.Name}  ({targetIndex}/{#targets})`
	else
		targetLabel.Text = target.Name
	end
	refreshResult()
end

local function updatePreviewCamera()
	zoomLabel.Text = if config.zoom > 1.001 then string.format("Zoom %.1fx", config.zoom) else "Auto-fit"
	local subject = previewSubject
	if not subject then
		return
	end
	local shot = frameSubject(subject, config.yaw, config.pitch, config.zoom)
	previewCamera.CFrame = shot.cframe
	-- Light from behind the camera, up and to the left, roughly like the real render
	viewport.LightDirection = shot.cframe:VectorToWorldSpace(Vector3.new(0.4, -0.7, -0.58)).Unit
end

local function loadPreview()
	previewWorld:ClearAllChildren()
	previewSubject = nil
	dragHint.Visible = false
	zoomLabel.Visible = false

	local target = currentTarget()
	if not target then
		previewHint.Text = "Select a pet model\n(click it in the viewport or the Explorer)"
		previewHint.Visible = true
		return
	end

	local subject, problem = buildSubject(target)
	if not subject then
		previewHint.Text = problem or "Can't preview this"
		previewHint.Visible = true
		return
	end
	if subject.partCount > MAX_PREVIEW_PARTS then
		previewHint.Text = `Too many parts to preview ({subject.partCount})`
		previewHint.Visible = true
		return
	end

	local ok, copy = pcall(makeRenderCopy, target)
	if not ok then
		previewHint.Text = tostring(copy)
		previewHint.Visible = true
		return
	end
	copy.Parent = previewWorld
	previewSubject = subject
	previewHint.Visible = false
	dragHint.Visible = true
	zoomLabel.Visible = true
	updatePreviewCamera()
end

local function refreshTargets()
	local previous = currentTarget()
	targets = resolveTargets(Selection:Get())
	targetIndex = math.max(1, table.find(targets, previous :: any) or 1)
	loadPreview()
	refreshControls()
end

local function onSettingsChanged(...: string)
	for _, key in { ... } do
		saveConfig(key)
	end
	updatePreviewCamera()
	refreshControls()
end

local function finishUpload(target: Instance, assetId: number): string
	local assetUri = `rbxassetid://{assetId}`
	idBox.Text = assetUri
	print(`{LOG_PREFIX} {target:GetFullName()} -> {assetUri}`)
	if config.saveAttribute and target.Parent and not saveIconAttribute(target, assetUri) then
		warn(`{LOG_PREFIX} Couldn't save the "{ATTRIBUTE_NAME}" attribute on {target:GetFullName()}`)
	end
	return assetUri
end

local function runBusy(work: () -> ())
	if busy then
		return
	end
	busy = true
	refreshControls()
	local ok, err = pcall(function()
		work()
		return nil
	end)
	busy = false
	refreshControls()
	if not ok then
		setStatus(tostring(err), "error")
	end
end

local function renderCurrent(): Result
	local target = currentTarget()
	if not target then
		error("Select a pet model first.", 0)
	end
	setStatus(`Rendering {target.Name}... (the viewport flashes for a moment, that's normal)`)
	local render = runCaptureSession(function()
		return renderTarget(target)
	end)
	showResult(target, render)
	return lastResult :: Result
end

local function upscaleNote(result: Result): string
	if result.upscaled then
		return " Tip: make the 3D viewport bigger for a sharper icon."
	end
	return ""
end

renderButton.Activated:Connect(function()
	runBusy(function()
		local result = renderCurrent()
		setStatus(`Rendered {result.target.Name}. Click Upload if it looks good.{upscaleNote(result)}`)
	end)
end)

uploadButton.Activated:Connect(function()
	runBusy(function()
		local result = if isResultCurrent() then lastResult :: Result else renderCurrent()
		setStatus(`Uploading {result.target.Name}...`)
		local assetId = uploadImage(result.image, result.target.Name)
		local assetUri = finishUpload(result.target, assetId)
		local saved = if config.saveAttribute then ` Saved to its "{ATTRIBUTE_NAME}" attribute.` else ""
		setStatus(`Uploaded {result.target.Name}: {assetUri}.{saved} New images can take a minute to pass moderation.`)
	end)
end)

uploadAllButton.Activated:Connect(function()
	runBusy(function()
		local queue = table.clone(targets)
		local uploaded: { { name: string, uri: string } } = {}
		local failed = 0

		runCaptureSession(function()
			for i, target in queue do
				local ok, err = pcall(function()
					setStatus(`({i}/{#queue}) Rendering {target.Name}...`)
					local render = renderTarget(target)
					showResult(target, render)
					setStatus(`({i}/{#queue}) Uploading {target.Name}...`)
					local assetId = uploadImage(render.image, target.Name)
					table.insert(uploaded, { name = target.Name, uri = finishUpload(target, assetId) })
				end)
				if not ok then
					failed += 1
					warn(`{LOG_PREFIX} {target:GetFullName()}: {err}`)
				end
			end
			return nil
		end)

		if #uploaded > 0 then
			local lines = { `{LOG_PREFIX} Uploaded {#uploaded} icons:`, "{" }
			for _, entry in uploaded do
				table.insert(lines, `\t[{string.format("%q", entry.name)}] = "{entry.uri}",`)
			end
			table.insert(lines, "}")
			print(table.concat(lines, "\n"))
		end

		if failed > 0 then
			setStatus(`Uploaded {#uploaded}/{#queue} icons. {failed} failed, see the Output window.`, "warning")
		else
			setStatus(`Uploaded all {#uploaded} icons! A ready-to-paste table of IDs is in the Output window.`)
		end
	end)
end)

previousButton.Activated:Connect(function()
	if #targets > 1 then
		targetIndex = (targetIndex - 2) % #targets + 1
		loadPreview()
		refreshControls()
	end
end)

nextButton.Activated:Connect(function()
	if #targets > 1 then
		targetIndex = targetIndex % #targets + 1
		loadPreview()
		refreshControls()
	end
end)

for i, preset in PRESETS do
	presetButtons[i].Activated:Connect(function()
		config.yaw = preset.yaw
		config.pitch = preset.pitch
		onSettingsChanged("yaw", "pitch")
	end)
end

flipButton.Activated:Connect(function()
	config.yaw = (config.yaw + 180 + 180) % 360 - 180
	onSettingsChanged("yaw")
end)

local sizeLabels = {}
for i, size in SIZES do
	sizeLabels[i] = tostring(size)
end
local refreshSizes: () -> () = function() end
refreshSizes = makeSegmented(sizeChoices, sizeLabels, function(i)
	return SIZES[i] == config.size
end, function(i)
	config.size = SIZES[i]
	refreshSizes()
	onSettingsChanged("size")
end)

paddingDown.Activated:Connect(function()
	config.padding = math.max(0, config.padding - 0.02)
	onSettingsChanged("padding")
end)

paddingUp.Activated:Connect(function()
	config.padding = math.min(0.3, config.padding + 0.02)
	onSettingsChanged("padding")
end)

local refreshCreator: () -> () = function() end
refreshCreator = makeSegmented(creatorChoices, { "Me", "Group" }, function(i)
	return (i == 2) == (config.creator == "Group")
end, function(i)
	config.creator = if i == 2 then "Group" else "User"
	refreshCreator()
	onSettingsChanged("creator")
end)

groupBox.FocusLost:Connect(function()
	local digits = string.gsub(groupBox.Text, "%D", "")
	config.groupId = tonumber(digits) or 0
	groupBox.Text = if config.groupId > 0 then tostring(config.groupId) else ""
	onSettingsChanged("groupId")
end)

makeCheckbox(checkboxHolder, "Bright studio lighting", 1, function()
	return config.studioLighting
end, function(value)
	config.studioLighting = value
	onSettingsChanged("studioLighting")
end)

makeCheckbox(checkboxHolder, `Save ID to the model's "{ATTRIBUTE_NAME}" attribute`, 2, function()
	return config.saveAttribute
end, function(value)
	config.saveAttribute = value
	onSettingsChanged("saveAttribute")
end)

idBox.Focused:Connect(function()
	task.defer(function()
		idBox.SelectionStart = 1
		idBox.CursorPosition = #idBox.Text + 1
	end)
end)

-- Preview interaction ---------------------------------------------------------------------------

local function endDrag()
	if dragging then
		dragging = false
		dragCatcher.Visible = false
		onSettingsChanged("yaw", "pitch")
	end
end

viewport.InputBegan:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and previewSubject then
		dragging = true
		lastDragPosition = Vector2.new(input.Position.X, input.Position.Y)
		dragCatcher.Visible = true
	end
end)

viewport.InputChanged:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseWheel and previewSubject then
		local factor = if input.Position.Z > 0 then 1.1 else 1 / 1.1
		config.zoom = math.clamp(config.zoom * factor, 1, 4)
		if config.zoom < 1.05 then
			config.zoom = 1 -- snap back to auto-fit
		end
		onSettingsChanged("zoom")
	end
end)

-- The scroll wheel zooms the preview instead of scrolling the panel while the mouse is over it
viewport.MouseEnter:Connect(function()
	root.ScrollingEnabled = false
end)
viewport.MouseLeave:Connect(function()
	root.ScrollingEnabled = true
end)

dragCatcher.InputChanged:Connect(function(input: InputObject)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local position = Vector2.new(input.Position.X, input.Position.Y)
		local delta = position - lastDragPosition
		lastDragPosition = position
		config.yaw = (config.yaw - delta.X * 0.6 + 180) % 360 - 180
		config.pitch = math.clamp(config.pitch + delta.Y * 0.6, -85, 85)
		updatePreviewCamera()
	end
end)

dragCatcher.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		endDrag()
	end
end)
dragCatcher.MouseLeave:Connect(endDrag)

-- Keep the preview square and as wide as the panel
local function resizePreview()
	local side = math.clamp(root.AbsoluteSize.X - 22, 120, 360)
	previewHolder.Size = UDim2.new(1, 0, 0, side)
	viewport.Size = UDim2.fromOffset(side, side)
end
root:GetPropertyChangedSignal("AbsoluteSize"):Connect(resizePreview)
resizePreview()

-- Wiring ----------------------------------------------------------------------------------------

Selection.SelectionChanged:Connect(function()
	if widget.Enabled then
		refreshTargets()
	end
end)

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
	if widget.Enabled then
		refreshTargets()
	else
		previewWorld:ClearAllChildren()
		previewSubject = nil
	end
end)

settings().Studio.ThemeChanged:Connect(applyTheme)

plugin.Unloading:Connect(function()
	local stage = activeStage
	if stage then
		stage.folder:Destroy()
	end
	local restore = activeRestore
	if restore then
		restore()
	end
	if lastResult then
		lastResult.image:Destroy()
	end
end)

toggleButton:SetActive(widget.Enabled)
refreshControls()
setStatus("Select a pet, pick an angle, then hit Upload.")
if widget.Enabled then
	refreshTargets()
end
