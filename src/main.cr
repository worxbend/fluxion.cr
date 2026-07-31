require "./fluxion"

exit Fluxion::CLI::App.new.run(ARGV).value
