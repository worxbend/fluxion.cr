require "./spinner/support"
require "./spinner/linear"
require "./spinner/rect"
require "./spinner/circle"
require "./spinner/bar"
require "./spinner/flux"

# Animated spinner widgets, ported from sorinirimies/tui-spinner.
#
# All six are stateless: they take a tick counter and derive the whole frame
# from it, so a caller keeps one integer and no widget ever has to be stored
# between draws.
module CryTUI::Widgets
end
