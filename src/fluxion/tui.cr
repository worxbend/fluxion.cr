require "../crytui"
require "./core"
require "./host"
require "./executor"
require "./tui/theme"
require "./tui/selection"
require "./tui/selector_screen"
require "./tui/execution_screen"
require "./tui/app"

# The terminal UI.
#
# Built on the vendored CryTUI: an immutable cell buffer diffed against the
# previous frame, so only what changed is written. Nothing below this layer
# knows a terminal exists.
module Fluxion::TUI
end
