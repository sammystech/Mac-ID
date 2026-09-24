# dmgbuild settings for the Mac ID installer window.
#
# Written straight into the disk image's .DS_Store by dmgbuild, so no Finder scripting is needed
# (and none of the Automation permission prompts that come with it). Geometry must match
# make_background.py: 660x400 window, app at (170, 200), Applications at (490, 200), 128 px icons.
#
#   dmgbuild -s dmg_settings.py -D app="/path/Mac ID.app" -D background=background.tiff "Mac ID" out.dmg
import os.path

app = defines["app"]                                   # noqa: F821 - provided by dmgbuild
appname = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = None
icon = os.path.join(app, "Contents", "Resources", "MacID.icns")    # the mounted volume's icon

background = defines.get("background", "background.tiff")          # noqa: F821
# 428 tall: the height includes the title bar, and 400 of content is what the background is drawn for.
window_rect = ((200, 160), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
grid_spacing = 100
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {appname: (170, 200), "Applications": (490, 200)}
