# Pet Icon Uploader

A Roblox Studio plugin for making inventory icons quickly. Select a pet model, pick an angle and click **Upload**. The plugin renders the pet with a transparent background, uploads it as an image and gives you the `rbxassetid://` to use in your inventory UI.

## Install

Pick one:

- **Drop-in:** in Studio open the **Plugins** tab, click **Plugins Folder**, copy `PetIconUploader.lua` into that folder and restart Studio.
- **Save as Local Plugin:** paste the contents of `PetIconUploader.lua` into a Script, right-click the Script in the Explorer and choose **Save as Local Plugin...**

The plugin must be installed locally like this. Roblox only allows uploads from local plugins.

A **Pet Icon Uploader** button appears in the Plugins tab. Click it to open the panel.

## Use

1. **Select a pet.** Click it in the viewport or in the Explorer. Pets stored in ReplicatedStorage or ServerStorage work too.
2. **Pick the angle.** Drag the preview to rotate it, or use the **Front / 3/4 L / 3/4 R / Side** buttons. Use **+180°** if the model is facing backwards. The scroll wheel zooms in. The default *Auto-fit* is usually what you want.
3. Click **Upload**. The viewport flashes for about a second while the plugin takes the shot. The image is then uploaded and the ID appears in the panel. To copy it, click the ID and press Ctrl+C.

You can click **Render** first to check how the icon looks before uploading.

### Upload a whole folder at once

Select several pets, or select the folder they're in. A **Upload all N selected** button appears. Every pet is rendered with the same angle and settings and uploaded one after another. When it finishes, the Output window shows a table you can paste into a config module:

```lua
{
	["Dog"] = "rbxassetid://1234567890",
	["Cat"] = "rbxassetid://1234567891",
}
```

Use the `<` `>` buttons to preview each selected pet before uploading.

## Using the icons in your game

By default the plugin also saves the ID to an `Icon` attribute on the pet model. Your inventory UI can read it straight off the model:

```lua
local pet = ReplicatedStorage.Pets[petName]
imageLabel.Image = pet:GetAttribute("Icon") or ""
```

After you re-upload a pet, the attribute holds the new ID, so you don't have to update anything by hand. Remember to save or publish the place.

## Options

| Option | What it does |
| --- | --- |
| Size | 256, 512 or 1024 pixels square. 512 is plenty for most inventory slots. |
| Padding | Empty space around the pet, so pets line up the same way in every slot. |
| Upload to | Your account (**Me**) or a **Group**. Group-owned places default to the group. |
| Bright studio lighting | Uses neutral daytime lighting for the render, so night-time or moody place lighting doesn't make icons dark. Turn it off to use your place's lighting. |
| Save ID to the model's "Icon" attribute | Turn it off if you don't want the plugin to touch your models. |

All settings are remembered between Studio sessions.

## Troubleshooting

- **Upload failed (PermissionDenied)**: make sure the plugin is installed as a local plugin (see Install). When uploading to a group, your group role needs permission to create assets. If your Studio still lists the Lua asset creation API under Beta Features, enable it there.
- **New icons show up blank in game for a bit**: freshly uploaded images go through moderation, which usually takes a few seconds to a minute.
- **"Taking a screenshot timed out"**: the 3D viewport has to be on screen while rendering. Switch back from a script tab, and don't minimize Studio.
- **The icon is a bit blurry at 1024**: the render is taken from your viewport, so make the viewport bigger (or close some panels) for more pixels. The panel tells you when an icon had to be enlarged.
- **Something from Studio's overlay ended up in the icon** (for example the view cube): hide it from the View tab and render again.

## How it works

The plugin copies the pet to an empty spot far above your map. It places a backdrop behind the pet and takes two Studio screenshots with `CaptureService`: one with a black backdrop and one with a white backdrop. A pixel that is part of the pet looks the same in both shots. A background pixel changes completely, and a see-through pixel (glass wings, soft edges) changes partially. That difference gives the exact transparency of every pixel. The result is cropped around the pet, padded, resized, edge-cleaned so it doesn't get a dark outline when scaled down, then uploaded with `AssetService:CreateAssetAsync`.

Your place's lighting, camera and UI are put back exactly as they were afterwards. Nothing is left behind in the place except the optional `Icon` attribute.
