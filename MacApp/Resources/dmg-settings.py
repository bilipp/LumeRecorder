# dmgbuild settings for LumeRecorder-<version>.dmg: the app next to an
# Applications link, with an arrow between them.
# Used by scripts/build-app.sh: dmgbuild -s dmg-settings.py -D app=… -D icon=…
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821

background = "builtin-arrow"
window_rect = ((200, 200), (640, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
hide_extensions = [app_name]
icon_locations = {
    app_name: (160, 140),
    "Applications": (480, 140),
}
