module Fluxion::TUI
  # What a previous run of this profile already finished.
  #
  # The selector offers this as a starting point — "carry on from where the
  # last run stopped" — rather than applying it silently. A resume that happens
  # without being asked for is a resume that skips work the user wanted redone,
  # and they have no way to see that it happened.
  #
  # A phase counts as done only while its fingerprint still matches the profile
  # on disk, which is the same rule the executor uses: editing a package list
  # makes the phase run again rather than staying quietly "completed".
  struct Resume
    # Phases a previous run completed and that have not been edited since.
    getter completed_phases : Set(String)

    # Where the previous run said it would pick up, when it stopped early.
    getter next_phase : String?

    getter last_run_at : Time?

    def initialize(@completed_phases : Set(String) = Set(String).new,
                   @next_phase : String? = nil,
                   @last_run_at : Time? = nil)
    end

    # Nothing to resume from — the shape used when there is no state file, or
    # when reading it failed.
    def self.none : self
      new
    end

    # Reads the state file for `profile_name` and works out which of this
    # profile's phases it still vouches for.
    #
    # A state file that cannot be read is not an error here. The selector's job
    # is to offer a shortcut; if the shortcut is unavailable the run should
    # still be startable, so a broken or unreadable file simply means "nothing
    # to resume from".
    def self.load(store : State::Store, profile : Profile, profile_name : String) : self
      return none unless store.exists?(profile_name)

      document = store.load(profile_name)
      completed = Set(String).new
      profile.phases.each do |phase|
        next unless document.phase_completed?(phase.name, State::Fingerprint.of(phase))
        completed << phase.name
      end

      new(completed, document.next_phase, document.last_run_at)
    rescue Error
      none
    end

    def available? : Bool
      !@completed_phases.empty? || !@next_phase.nil?
    end

    def completed?(phase : String) : Bool
      @completed_phases.includes?(phase)
    end

    # A short description for the selector's header, so the offer says what it
    # would actually do rather than just that it exists.
    def summary : String
      return "no saved state for this profile" unless available?

      parts = [] of String
      parts << "#{Text.pluralize(@completed_phases.size, "phase")} already done"
      @next_phase.try { |phase| parts << "stopped before #{phase}" }
      @last_run_at.try { |time| parts << "last run #{time.to_s("%Y-%m-%d %H:%M")}" }
      parts.join(" · ")
    end
  end
end
