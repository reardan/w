# The two words graphics.ui and graphics.control share
# (docs/projects/wdrive.md, "Accessibility tree"). graphics.control
# answers an a11y_tree request by raising gfx_control_a11y_request;
# graphics.ui's ui_begin_window captures that frame's accessibility
# snapshot, and ui_end leaves its JSON in gfx_control_a11y_reply for
# the control channel to send. Kept import-free so every ui target,
# wasm included, links it without pulling in the channel itself.


# 0 idle, 1 wanted (set by graphics.control), 2 a ui frame is capturing.
int gfx_control_a11y_request


# Malloc'd JSON object for the captured tree, or 0. graphics.control
# takes and frees it.
char* gfx_control_a11y_reply
