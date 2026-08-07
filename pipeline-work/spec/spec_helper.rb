# frozen_string_literal: true

require "pathname"
ROOT = Pathname.new(File.expand_path("..", __dir__))
$LOAD_PATH.unshift(ROOT + "lib")
