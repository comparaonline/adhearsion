begin
  require 'thor/group'
rescue LoadError
  puts "Thor is not available.\nIf you ran this command from a git checkout " \
       "of Adhearsion, please make sure thor is installed,\nand run this command " \
       "as `ruby #{$0} #{(ARGV | ['--dev']).join(" ")}`"
  exit
end

module Adhearsion
  module Generators

    class Generator < Thor::Group
      include Thor::Actions

      def require_arguments?
        false
      end

    end
  end
end

