require "./core"
require "./host"
require "./state"
require "./executor/redaction"
require "./executor/command"
require "./executor/download"
require "./executor/shell_runner"
require "./executor/probe"
require "./executor/step_executor"
require "./executor/orchestrator"

# Runs the work a profile describes.
#
# Everything that touches the outside world lives here: processes, the
# filesystem, the network, and the trust checks that guard them. The layers
# above hand it a validated `Profile` and receive `ExecutionEvent`s back.
module Fluxion::Executor
end
