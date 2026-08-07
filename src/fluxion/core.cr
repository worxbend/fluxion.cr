require "uri"

require "./core/errors"
require "./core/diagnostic"
require "./core/public_url"
require "./core/os"
require "./core/package_manager"
require "./core/shell"
require "./core/trust"
require "./core/item_type"
require "./core/results"
require "./core/condition"
require "./core/restart_policy"
require "./core/step"
require "./core/events"
require "./core/steps/packages"
require "./core/steps/repositories"
require "./core/steps/binaries"
require "./core/steps/shell"
require "./core/steps/system"
require "./core/phase"

# The domain model: validated data describing what a profile asks for, with no
# knowledge of processes, terminals, YAML, or the network.
#
# Everything above this layer depends on it; it depends on nothing. That is
# what lets `plan`, `dry-run`, `explain`, and `apply` share one description of
# the work and disagree only about whether to carry it out.
module Fluxion
end
