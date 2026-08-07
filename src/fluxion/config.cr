require "yaml"
require "./core"
require "./host"
require "./config/node"
require "./config/context"
require "./config/condition_parser"
require "./config/step_parser"
require "./config/step_parser/repositories"
require "./config/step_parser/binaries"
require "./config/step_parser/shell"
require "./config/step_parser/system"
require "./config/step_parser/manifest_entries"
require "./config/plan_kinds"
require "./config/interpolator"
require "./config/manifest"
require "./config/loader"

# Reads YAML profiles and maps them onto the domain model.
#
# One frontend: the `WorkstationProfile` manifest, whose `spec.phases` become
# the `Profile` phase DAG. Diagnostics are collected rather than raised so a
# profile with several mistakes takes one run to fix.
module Fluxion::Config
end
