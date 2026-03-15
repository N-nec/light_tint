# light_tint

This mod fakes colored light by temporarily tinting nearby safe nodes.

## What It Does

- Auto-detects colored light nodes by name (`red`, `blue`, `green`, etc.) if they emit light.
- Finds those lights near players.
- Temporarily swaps nearby simple nodes to tinted variants.
- Restores original nodes when the light is gone or out of range.

## Important Limits

- This is not true engine RGB lighting.
- To avoid breaking machines/containers, only simple, safe nodes are tinted.
- Heavy settings can affect server performance.

## Settings

- `light_tint_enable` (default: `true`)
- `light_tint_interval` (default: `0.7`)
- `light_tint_scan_radius` (default: `12`)
- `light_tint_max_lights_per_player` (default: `24`)
- `light_tint_max_tints_per_step` (default: `2600`)
- `light_tint_ttl` (default: `1.5`)
- `light_tint_max_effect_radius` (default: `10`)
- `light_tint_radius_bonus` (default: `5`)
- `light_tint_alpha` (default: `72`)
- `light_tint_max_registered_variants` (default: `9000`)
- `light_tint_include_furniture` (default: `true`)
- `light_tint_player_overlay` (default: `true`)
- `light_tint_player_overlay_max_alpha` (default: `50`)
- `light_tint_only_exposed_nodes` (default: `true`)
- `light_tint_tint_any_node` (default: `true`)

## API For Other Mods

Other mods can register explicit colored lights:

```lua
if light_tint and light_tint.register_colored_light then
    light_tint.register_colored_light("my_mod:my_blue_lamp", "blue", 4)
end
```

Supported colors:

- `red`
- `orange`
- `yellow`
- `green`
- `blue`
- `cyan`
- `purple`
- `pink`
