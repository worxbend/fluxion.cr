require "json"
require "option_parser"

# Every layer this one actually uses. The list doubles as this file's statement
# of what `cli` depends on, so an omission makes the dependency graph read as
# smaller than it is — `version`, `registry` and `state` were all reached
# through another file's requires rather than declared here.
require "./version"
require "./core"
require "./host"
require "./paths"
require "./config"
require "./state"
require "./executor"
require "./registry"
require "./spinners"
require "./tui"
require "./cli/style"
require "./cli/exit_code"
require "./cli/command"
require "./cli/group_command"
require "./cli/spinner"
require "./cli/reporter"
require "./cli/commands/validate"
require "./cli/commands/plan"
require "./cli/commands/apply"
require "./cli/commands/status"
require "./cli/commands/doctor"
require "./cli/commands/state"
require "./cli/commands/report"
require "./cli/commands/tools"
require "./cli/commands/generate"
require "./cli/commands/registry"
require "./cli/commands/spinners"
require "./cli/app"

# The command-line interface.
#
# Commands own their own option parsing and rendering; everything below this
# layer is unaware that a terminal exists.
module Fluxion::CLI
end
