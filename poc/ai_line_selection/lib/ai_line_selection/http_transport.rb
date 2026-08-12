# frozen_string_literal: true

require "net/http"
require "uri"

module AiLineSelection
  class HttpTransport
    def post(url:, headers:, body:, timeout_seconds:, provider:)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri.request_uri, headers)
      request.body = body
      response = http_for(uri, timeout_seconds).request(request)
      HttpResponse.new(
        status: response.code.to_i,
        headers: response.each_header.to_h.transform_keys(&:downcase),
        body: response.body.to_s
      )
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      raise ProviderTimeoutError.new(provider)
    rescue SocketError, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise ProviderNetworkError.new(provider, error_class: e.class.name)
    end

    private

    def http_for(uri, timeout_seconds)
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout_seconds
        http.read_timeout = timeout_seconds
        http.write_timeout = timeout_seconds if http.respond_to?(:write_timeout=)
      end
    end
  end
end
