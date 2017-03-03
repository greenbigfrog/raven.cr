require "base64"
require "json"
require "zlib"

module Raven
  # Encodes events and sends them to the Sentry server.
  class Client
    PROTOCOL_VERSION = 7
    USER_AGENT       = "raven.cr/#{Raven::VERSION}"

    property configuration : Configuration
    delegate logger, to: configuration

    # FIXME: why do i need to use "!"?
    protected getter! processors : Array(Processor)
    # FIXME: why do i need to use "!"?
    protected getter! state : State

    getter transport : Transport do
      case configuration.scheme
      when "http", "https"
        Transport::HTTP.new(configuration)
      when "dummy"
        Transport::Dummy.new(configuration)
      else
        raise "Unknown transport scheme '#{configuration.scheme}'"
      end
    end

    def initialize(@configuration)
      @processors = @configuration.processors.map &.new(self)
      @state = State.new
    end

    def send_event(event)
      return false unless configuration.capture_allowed?(event)

      unless state.should_try?
        failed_send nil, event
        return
      end
      logger.info "Sending event #{event.id} to Sentry"
      # pp event.to_hash

      content_type, encoded_data = encode(event)
      begin
        options = {content_type: content_type}
        transport.send_event(generate_auth_header, encoded_data, **options).tap do
          successful_send
        end
      rescue e
        failed_send e, event
      end
    end

    private def encode(event)
      data = event.to_hash
      data = processors.reduce(data) { |v, p| p.process(v) }
      encoded = data.to_json

      case configuration.encoding
      when .gzip?
        io_encoded = IO::Memory.new(encoded)
        io_gzipped = IO::Memory.new
        Gzip::Writer.open(io_gzipped) do |deflate|
          IO.copy(io_encoded, deflate)
        end
        {"application/octet-stream", Base64.strict_encode(io_gzipped)}
      when .json?
        {"application/json", encoded}
      else
        raise "Invalid configuration encoding"
      end
    end

    private def generate_auth_header
      fields = {
        "sentry_version": PROTOCOL_VERSION,
        "sentry_client":  USER_AGENT,
        "sentry_key":     configuration.public_key,
        "sentry_secret":  configuration.secret_key,
      }
      "Sentry " + fields.map { |key, value| "#{key}=#{value}" }.join(", ")
    end

    private def successful_send
      state.success
    end

    private def failed_send(e, event)
      state.failure
      if e
        logger.error "Unable to record event with remote Sentry server \
          (#{e.class} - #{e.message}): #{e.backtrace[0..10].join('\n')}"
      else
        logger.error "Not sending event due to previous failure(s)"
      end
      logger.error "Failed to submit event: #{event.message || "<no message value>"}"
      configuration.transport_failure_callback.try &.call(event)
    end
  end
end