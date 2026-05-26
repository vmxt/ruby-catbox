# frozen_string_literal: true

module Catbox
  module Clipboard
    module_function

    def copy(text)
      require 'clipboard'
      ::Clipboard.copy(text.to_s)
    rescue LoadError, StandardError
      nil
    end
  end
end
