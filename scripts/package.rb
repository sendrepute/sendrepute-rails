# frozen_string_literal: true

require "fileutils"
require "time"

ROOT = File.expand_path("..", __dir__)
VERSION = File.read(File.join(ROOT, "lib/sendrepute/rails/version.rb"))[/VERSION = "([^"]+)"/, 1]
OUTPUT = File.join(ROOT, "dist", "sendrepute-rails-#{VERSION}.zip")
FILES = %w[
  LICENSE MANIFEST.txt README.md SECURITY.md Gemfile sendrepute-rails.gemspec
  lib/sendrepute-rails.rb
  lib/sendrepute/rails.rb
  lib/sendrepute/rails/client.rb
  lib/sendrepute/rails/configuration.rb
  lib/sendrepute/rails/mailer.rb
  lib/sendrepute/rails/message.rb
  lib/sendrepute/rails/version.rb
].freeze

FileUtils.mkdir_p(File.dirname(OUTPUT))
FileUtils.rm_f(OUTPUT)
epoch = "198001010000.00"
FILES.each { |path| system("touch", "-t", epoch, File.join(ROOT, path), exception: true) }
Dir.chdir(ROOT) do
  system("zip", "-X", "-q", OUTPUT, *FILES.sort, exception: true)
end
puts OUTPUT
