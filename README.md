# dvdstim
A bouncing DVD logo for Wayland. It renders on the overlay layer but is
click-through (empty input region, no keyboard grab), so you can keep working
underneath it.

Built as a learning project for libwayland and Zig.

## Requirements
- Zig 0.16.0+
- A wlroots-based compositor (Sway, Hyprland, river, ...) for `wlr-layer-shell` support
- `wayland-client` dev headers
- `wayland-scanner` (generates the protocol glue at build time)

## Build and run
```sh
zig build run
```
Runs until killed.

## Example usage
Toggle on Hyprland:
```lua
hl.bind("SUPER + D", hl.dsp.exec_cmd(
    [[sh -c 'pgrep -x dvdstim >/dev/null && pkill -x dvdstim || dvdstim &']]))
```
