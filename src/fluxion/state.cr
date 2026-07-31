require "digest/sha256"
require "./core"
require "./host"
require "./state/store"

# What a profile has already done, so a rerun is cheap and an interrupted run
# can be resumed.
module Fluxion::State
end
