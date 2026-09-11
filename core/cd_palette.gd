## Colours for everything Cadmium draws itself -- the piano roll, the playlist,
## the mixer strips, the meters. The Theme carries the same palette for standard
## controls; both come from tools/build_theme.gd.
##
## Neutral grey, square, dense -- Source 2 Hammer by way of Comotion, with the
## primary moved from amber to cadmium red.
class_name CdPalette
extends RefCounted

const WINDOW_BASE := Color("#3f3f3f")
static var WINDOW: Color = WINDOW_BASE
const PANEL_BASE := Color("#454545")
static var PANEL: Color = PANEL_BASE
const PANEL_ALT_BASE := Color("#4d4d4d")
static var PANEL_ALT: Color = PANEL_ALT_BASE
const CAPTION_BASE := Color("#565656")
static var CAPTION: Color = CAPTION_BASE
const RAISED_BASE := Color("#5a5a5a")
static var RAISED: Color = RAISED_BASE
const RAISED_HI_BASE := Color("#6a6a6a")
static var RAISED_HI: Color = RAISED_HI_BASE
const SUNKEN_BASE := Color("#2b2b2b")
static var SUNKEN: Color = SUNKEN_BASE
const WELL_BASE := Color("#252525")
static var WELL: Color = WELL_BASE
const VIEWPORT_BASE := Color("#1e1e1e")
static var VIEWPORT: Color = VIEWPORT_BASE

const RULE_DARK_BASE := Color("#2a2a2a")
static var RULE_DARK: Color = RULE_DARK_BASE
const RULE_LIGHT_BASE := Color("#666666")
static var RULE_LIGHT: Color = RULE_LIGHT_BASE
const BEVEL_HI_BASE := Color("#6e6e6e")
static var BEVEL_HI: Color = BEVEL_HI_BASE
const BEVEL_LO_BASE := Color("#343434")
static var BEVEL_LO: Color = BEVEL_LO_BASE

const TEXT_BASE := Color("#e2e2e2")
static var TEXT: Color = TEXT_BASE
const TEXT_DIM_BASE := Color("#b4b4b4")
static var TEXT_DIM: Color = TEXT_DIM_BASE
const TEXT_MUTE_BASE := Color("#8a8a8a")
static var TEXT_MUTE: Color = TEXT_MUTE_BASE

const ACCENT_DEFAULT := Color("#e0483c")
static var ACCENT: Color = ACCENT_DEFAULT
static var ACCENT_DARK: Color = shade_dark(ACCENT_DEFAULT)
static var ACCENT_SOFT: Color = shade_soft(ACCENT_DEFAULT)

const FOCUS       := Color("#4a90d9")
## The playhead is deliberately not the accent: on a red interface a red
## playhead vanishes into every selected clip it crosses.
const PLAYHEAD    := Color("#f2f2f2")
const RECORD      := Color("#ff5a4a")
const GOOD        := Color("#7fbf5f")
const WARN        := Color("#e8c04d")
const BAD         := Color("#e06666")

## Grid weights, from bar line down to the finest subdivision.
const GRID_BAR_BASE := Color("#1a1a1a")
static var GRID_BAR: Color = GRID_BAR_BASE
const GRID_BEAT_BASE := Color("#232323")
static var GRID_BEAT: Color = GRID_BEAT_BASE
const GRID_STEP_BASE := Color("#2e2e2e")
static var GRID_STEP: Color = GRID_STEP_BASE
const GRID_FINE_BASE := Color("#343434")
static var GRID_FINE: Color = GRID_FINE_BASE

const KEY_WHITE_BASE := Color("#c9c9c9")
static var KEY_WHITE: Color = KEY_WHITE_BASE
const KEY_BLACK_BASE := Color("#3a3a3a")
static var KEY_BLACK: Color = KEY_BLACK_BASE
const ROW_WHITE_BASE := Color("#333333")
static var ROW_WHITE: Color = ROW_WHITE_BASE
const ROW_BLACK_BASE := Color("#2b2b2b")
static var ROW_BLACK: Color = ROW_BLACK_BASE
const ROW_ROOT_BASE := Color("#3a3230")
static var ROW_ROOT: Color = ROW_ROOT_BASE

## Clip and channel colours -- desaturated so a busy playlist stays readable.
const TRACK_COLORS := [
	Color("#c0574c"), Color("#c08a4c"), Color("#b3b04f"), Color("#78b060"),
	Color("#4fb096"), Color("#4f96c0"), Color("#5f74c0"), Color("#8a5fc0"),
	Color("#b85fa8"), Color("#a86b6b"), Color("#7f8f9f"), Color("#8f7f6f"),
]

const METER_LOW   := Color("#5fbf6f")
const METER_MID   := Color("#d8c04a")
const METER_HIGH  := Color("#e0483c")


static func shade_dark(c: Color) -> Color:
	return Color.from_hsv(c.h, minf(c.s * 1.08, 1.0), c.v * 0.72, c.a)


static func shade_soft(c: Color) -> Color:
	return Color.from_hsv(c.h, c.s * 0.52, minf(c.v * 1.05 + 0.06, 1.0), c.a)


## Every neutral in the interface, as it was drawn. The secondary colour moves
## all of them together: same relative brightness, the hue and saturation of
## whatever was picked. Grey in, grey out.
const SECONDARY_DEFAULT := PANEL_BASE
static var SECONDARY: Color = SECONDARY_DEFAULT
## Icons are drawn with three neutral inks besides the accent; these follow the
## secondary too, or an icon stays grey on a blue interface.
static var INK_DARK: Color = Color("#1b1d20")
static var INK_MID: Color = Color("#9aa0a6")
static var INK_LIGHT: Color = Color("#d6d9dc")
const INK_DARK_BASE := Color("#1b1d20")
const INK_MID_BASE := Color("#9aa0a6")
const INK_LIGHT_BASE := Color("#d6d9dc")


## Moves a neutral to the secondary's hue and saturation, keeping how light or
## dark it was relative to the grey the interface was drawn in.
static func tint_neutral(base: Color, sec: Color) -> Color:
	var ref := SECONDARY_DEFAULT.v
	var v: float = clampf(base.v * (sec.v / maxf(0.01, ref)), 0.0, 1.0)
	if sec.s < 0.005:
		return Color(v, v, v, base.a)
	# Dark greys take less colour than light ones, which is what keeps a tinted
	# interface from turning into a wash.
	var s: float = clampf(sec.s * (0.35 + base.v * 0.9), 0.0, 1.0)
	return Color.from_hsv(sec.h, s, v, base.a)


static func set_secondary(c: Color) -> void:
	SECONDARY = Color(c.r, c.g, c.b, 1.0)
	WINDOW = tint_neutral(WINDOW_BASE, SECONDARY)
	PANEL = tint_neutral(PANEL_BASE, SECONDARY)
	PANEL_ALT = tint_neutral(PANEL_ALT_BASE, SECONDARY)
	CAPTION = tint_neutral(CAPTION_BASE, SECONDARY)
	RAISED = tint_neutral(RAISED_BASE, SECONDARY)
	RAISED_HI = tint_neutral(RAISED_HI_BASE, SECONDARY)
	SUNKEN = tint_neutral(SUNKEN_BASE, SECONDARY)
	WELL = tint_neutral(WELL_BASE, SECONDARY)
	VIEWPORT = tint_neutral(VIEWPORT_BASE, SECONDARY)
	RULE_DARK = tint_neutral(RULE_DARK_BASE, SECONDARY)
	RULE_LIGHT = tint_neutral(RULE_LIGHT_BASE, SECONDARY)
	BEVEL_HI = tint_neutral(BEVEL_HI_BASE, SECONDARY)
	BEVEL_LO = tint_neutral(BEVEL_LO_BASE, SECONDARY)
	TEXT = tint_neutral(TEXT_BASE, SECONDARY)
	TEXT_DIM = tint_neutral(TEXT_DIM_BASE, SECONDARY)
	TEXT_MUTE = tint_neutral(TEXT_MUTE_BASE, SECONDARY)
	GRID_BAR = tint_neutral(GRID_BAR_BASE, SECONDARY)
	GRID_BEAT = tint_neutral(GRID_BEAT_BASE, SECONDARY)
	GRID_STEP = tint_neutral(GRID_STEP_BASE, SECONDARY)
	GRID_FINE = tint_neutral(GRID_FINE_BASE, SECONDARY)
	KEY_WHITE = tint_neutral(KEY_WHITE_BASE, SECONDARY)
	KEY_BLACK = tint_neutral(KEY_BLACK_BASE, SECONDARY)
	ROW_WHITE = tint_neutral(ROW_WHITE_BASE, SECONDARY)
	ROW_BLACK = tint_neutral(ROW_BLACK_BASE, SECONDARY)
	ROW_ROOT = tint_neutral(ROW_ROOT_BASE, SECONDARY)
	INK_DARK = tint_neutral(INK_DARK_BASE, SECONDARY)
	INK_MID = tint_neutral(INK_MID_BASE, SECONDARY)
	INK_LIGHT = tint_neutral(INK_LIGHT_BASE, SECONDARY)


static func set_accent(c: Color) -> void:
	ACCENT = Color(c.r, c.g, c.b, 1.0)
	ACCENT_DARK = shade_dark(ACCENT)
	ACCENT_SOFT = shade_soft(ACCENT)


static func track_color(i: int) -> Color:
	return TRACK_COLORS[posmod(i, TRACK_COLORS.size())]


## Green below -12 dBFS, amber to -3, red above: the convention every engineer
## already reads without a legend.
static func meter_color(db: float) -> Color:
	if db > -3.0:
		return METER_HIGH
	if db > -12.0:
		return METER_MID
	return METER_LOW


static func note_color(vel: float, selected: bool) -> Color:
	var c := ACCENT.lerp(Color("#ffd9d2"), clampf(vel, 0.0, 1.0) * 0.35)
	if selected:
		return c.lightened(0.35)
	return c
