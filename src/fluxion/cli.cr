require "json"
require "option_parser"

require "./core"
require "./config"
require "./executor"
require "./cli/style"
require "./cli/exit_code"
require "./cli/command"
require "./cli/reporter"
require "./cli/commands/validate"
require "./cli/commands/plan"
require "./cli/commands/apply"
require "./cli/commands/status"
require "./cli/commands/doctor"
require "./cli/commands/state"
require "./cli/commands/generate"
require "./cli/app"

# The command-line interface.
#
# Commands own their own option parsing and rendering; everything below this
# layer is unaware that a terminal exists.
module Fluxion::CLI
end
