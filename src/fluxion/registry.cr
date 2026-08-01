require "digest/sha256"
require "file_utils"

require "./core"
require "./host"
require "./config"
require "./executor"
require "./registry/manifest"
require "./registry/source"
require "./registry/git"
require "./registry/store"

# Sharing bootstrap configurations through a git repository.
#
# A registry is a repository with a strict shape: one manifest at its root
# listing entries by id, and one folder holding the profiles those entries
# name. Strictness is the point — a registry tells a machine what to install,
# and a layout that is discovered rather than declared cannot be checked.
#
# Locally the two halves stay apart: a disposable git mirror under the cache
# directory, and the configurations the user actually chose under the config
# directory. That separation is what lets `sync` be safe — it can refresh the
# mirror without touching anything the user has edited.
module Fluxion::Registry
end
