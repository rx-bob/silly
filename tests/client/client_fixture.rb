#!/usr/bin/env ruby
# Local protocol fixture. No outbound network or curl subprocesses.
require_relative "../support/fixture_http"

module ClientFixture
  ORDER_LOCK = Mutex.new
  @order_counter = 0

  def self.next_order(path)
    ORDER_LOCK.synchronize do
      @order_counter = path == "/order/reset" ? 0 : @order_counter + 1
      @order_counter.to_s
    end
  end

  class Handler
    LARGE = (0...131072).map { |index| index % 251 }.pack("C*").freeze

    def initialize(exchange)
      @exchange = exchange
    end

    def respond
      exchange = @exchange
      path = exchange.path
      sleep 2 if path == "/hold"
      sleep 0.7 if path == "/delay"
      body = "hello\x00world".b
      body = ClientFixture.next_order(path).b if path.start_with?("/order/")
      body = LARGE if path == "/large"
      body = "abcdefghij".b if ["/idle", "/total"].include?(path)
      exchange.send_response(200)
      exchange.send_header("Content-Length", path == "/reset" ? "100" : body.bytesize.to_s)
      exchange.send_header("X-Fixture", "local")
      exchange.send_header("X-Large", "x" * 8192) if path == "/headers"
      exchange.end_headers
      if path == "/reset"
        exchange.write("short")
        exchange.flush
        exchange.abort_reset
        return
      end
      if ["/idle", "/total"].include?(path)
        body.each_byte do |byte|
          exchange.write([byte].pack("C"))
          exchange.flush
          sleep(path == "/idle" ? 0.7 : 0.06)
        end
        return
      end
      exchange.write(body)
      exchange.flush
    end
  end

  def self.run(ready_path, certificate, key)
    handler = Handler
    stall = FixtureHTTP::StallServer.new(2).start
    refused = FixtureHTTP.refused_port
    plain = FixtureHTTP::Server.new(handler).start
    secure = FixtureHTTP::Server.new(handler, tls: FixtureHTTP.tls_context(certificate, key)).start
    File.write(ready_path, JSON.generate(
      "http" => plain.port,
      "https" => secure.port,
      "refused" => refused,
      "stall" => stall.port
    ))
    loop { sleep 1 }
  end
end

ClientFixture.run(ARGV[0], ARGV[1], ARGV[2]) if $PROGRAM_NAME == __FILE__
