# frozen_string_literal: true

require 'faraday'
require 'faraday/multipart'

module Catbox
  class Api
    CATBOX_HOST = 'https://catbox.moe/user/api.php'
    LITTER_HOST = 'https://litterbox.catbox.moe/resources/internals/api.php'
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    class ApiError < StandardError
    end

    def request(host:, reqtype:, fields: {}, file: nil)
      payload = fields.merge(reqtype: reqtype)
      payload[:fileToUpload] = upload_io(file) if file

      response = connection.post(host, payload)
      body = response.body.to_s.strip
      return body if response.success?

      raise ApiError, body.empty? ? "HTTP #{response.status}" : body
    rescue Faraday::Error => e
      raise ApiError, e.message
    end

    private

    def connection
      @connection ||= Faraday.new do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.timeout = READ_TIMEOUT
        faraday.request :multipart
        faraday.request :url_encoded
        faraday.adapter Faraday.default_adapter
      end
    end

    def upload_io(path)
      return Faraday::Multipart::FilePart.new($stdin, 'application/octet-stream', 'stdin') if path == '-'

      Faraday::Multipart::FilePart.new(path, 'application/octet-stream')
    end
  end
end
