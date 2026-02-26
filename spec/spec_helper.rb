# Minimaler RSpec-Helper für isolierte Unit-Tests ohne Redmine-Umgebung
require 'rspec'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

