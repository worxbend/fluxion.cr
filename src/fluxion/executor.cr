require "./core"
require "./host"
require "./paths"
require "./state"
require "./executor/redaction"
require "./executor/command"
require "./executor/download"
require "./executor/archive"
require "./executor/installer"
require "./executor/shell_runner"
require "./executor/probe"
require "./executor/probe_sweep"
require "./executor/item_types"
require "./executor/step_executor"
# downloads.cr first: it defines `DownloadSupport`, which the shell and
# repository executors include.
require "./executor/executors/downloads"
require "./executor/executors/packages"
require "./executor/executors/system"
require "./executor/executors/shell"
require "./executor/executors/repositories"
require "./executor/executors/tools"
require "./executor/run_options"
require "./executor/orchestrator"

# Runs the work a profile describes.
#
# Everything that touches the outside world lives here: processes, the
# filesystem, the network, and the trust checks that guard them. The layers
# above hand it a validated `Profile` and receive `ExecutionEvent`s back.
module Fluxion::Executor
end
