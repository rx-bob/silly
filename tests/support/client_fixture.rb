#!/usr/bin/env ruby
# Local protocol fixture. No outbound network or curl subprocesses.
# The support copy delegates to the client suite fixture so both stay identical.
require_relative "../client/client_fixture"

ClientFixture.run(ARGV[0], ARGV[1], ARGV[2]) if $PROGRAM_NAME == __FILE__
