#!/usr/bin/env ruby
# Local methods, upload, response-metadata and content-decoding fixture.
require_relative "../support/fixture_http"

module ClientHTTPFixture
  PAYLOAD = ("compressed\x00payload\xff".b * 128).freeze
  GZIP = FixtureHTTP.gzip(PAYLOAD).freeze
  DEFLATE = FixtureHTTP.deflate(PAYLOAD).freeze
  LARGE = (0...131072).map { |index| index % 251 }.pack("C*").freeze

  class Handler
    def initialize(exchange)
      @exchange = exchange
    end

    def respond
      exchange = @exchange
      path = exchange.path.split("?", 2)[0]
      if path == "/duplex"
        duplex(exchange)
        return
      end
      sleep 0.15 if path == "/slow-upload"
      incoming = exchange.request_body
      status = 200
      body = "ok".b
      fields = []
      chunked = false
      case path
      when "/echo", "/slow-upload"
        body = incoming
        fields = [
          ["X-Method", exchange.command],
          ["X-Request-Type", exchange.headers.get("Content-Type", "none")],
          ["X-Accept-Encoding", exchange.headers.get("Accept-Encoding", "none")],
          ["X-Repeat", exchange.headers.get_all("X-Repeat").join("|")],
          ["X-Empty", exchange.headers.include?("X-Empty") ? "present" : "absent"],
          ["X-Request-TE", exchange.headers.get("Transfer-Encoding", "none")],
          ["X-Request-Length", exchange.headers.get("Content-Length", "none")]
        ]
      when "/interim"
        exchange.write("HTTP/1.1 100 Continue\r\nX-Interim: first\r\n\r\n")
        exchange.write("HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n")
        body = "final\x00bytes".b
        fields = [
          ["X-Repeat", "first"],
          ["X-Repeat", "second"],
          ["Content-Type", "application/octet-stream"]
        ]
      when "/gzip-large", "/deflate-large"
        coding = path == "/gzip-large" ? "gzip" : "deflate"
        body = coding == "gzip" ? FixtureHTTP.gzip(LARGE) : FixtureHTTP.deflate(LARGE)
        fields = [["Content-Encoding", coding]]
        chunked = true
      when "/gzip", "/gzip-chunked", "/gzip-bytes"
        body = GZIP
        fields << ["Content-Encoding", "gzip"] unless path == "/gzip-bytes"
        chunked = path.end_with?("chunked")
      when "/deflate", "/deflate-chunked", "/deflate-bytes"
        body = DEFLATE
        fields << ["Content-Encoding", "deflate"] unless path == "/deflate-bytes"
        chunked = path.end_with?("chunked")
      when "/gzip-empty"
        body = FixtureHTTP.gzip("")
        fields = [["Content-Encoding", "gzip"]]
      when "/gzip-empty-members"
        body = FixtureHTTP.gzip("") * 256 + FixtureHTTP.gzip("last")
        fields = [["Content-Encoding", "gzip"]]
      when "/switch"
        exchange.write("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: test\r\n\r\n")
        exchange.flush
        exchange.close_connection = true
        return
      when "/gzip-concatenated"
        body = GZIP + GZIP
        fields = [["Content-Encoding", "gzip"]]
      when "/gzip-crc"
        damaged = GZIP.dup
        at = damaged.bytesize - 8
        damaged.setbyte(at, damaged.getbyte(at) ^ 1)
        body = damaged
        fields = [["Content-Encoding", "gzip"]]
      when "/truncated-deflate"
        body = DEFLATE.byteslice(0, DEFLATE.bytesize - 2)
        fields = [["Content-Encoding", "deflate"]]
      when "/truncated-gzip"
        body = GZIP.byteslice(0, GZIP.bytesize - 8)
        fields = [["Content-Encoding", "gzip"]]
      when "/bad-gzip"
        body = "not gzip at all".b
        fields = [["Content-Encoding", "gzip"]]
      when "/head"
        body = "x" * 99
        fields = [["Content-Encoding", "gzip"], ["Content-Type", "application/test"]]
      when "/204", "/304"
        status = path[1..].to_i
        body = status == 204 ? "".b : "x" * 99
        fields = [["Content-Encoding", "gzip"]]
      when "/error"
        status = 418
        body = "error\x00\xff".b
      when "/redirect"
        status = 302
        body = "redirect body".b
        fields = [["Location", "/auth?redirected=1"]]
      when "/auth"
        body = exchange.headers.get("Authorization", "none").b
      end
      exchange.send_response(status)
      fields.each { |name, value| exchange.send_header(name, value) }
      if chunked
        exchange.send_header("Transfer-Encoding", "chunked")
        exchange.send_header("Trailer", "X-Trailer")
      else
        exchange.send_header("Content-Length", body.bytesize.to_s)
      end
      exchange.end_headers
      return if exchange.command == "HEAD" || status == 204 || status == 304

      if chunked
        offset = 0
        while offset < body.bytesize
          chunk = body.byteslice(offset, 7)
          exchange.write(chunk.bytesize.to_s(16) + "\r\n" + chunk + "\r\n")
          offset += chunk.bytesize
        end
        exchange.write("0\r\nX-Trailer: excluded\r\n\r\n")
      else
        exchange.write(body)
      end
      exchange.flush
    end

    private

    # Answer with a chunk before the request upload completes.
    def duplex(exchange)
      exchange.send_response(200)
      exchange.send_header("Transfer-Encoding", "chunked")
      exchange.end_headers
      prefix = "p" * 32768
      exchange.write(prefix.bytesize.to_s(16) + "\r\n" + prefix + "\r\n")
      exchange.flush
      incoming = exchange.request_body
      exchange.write(incoming.bytesize.to_s(16) + "\r\n" + incoming + "\r\n0\r\n\r\n")
      exchange.flush
    end
  end

  def self.run(ready_path)
    server = FixtureHTTP::Server.new(Handler).start
    File.write(ready_path, JSON.generate("http" => server.port))
    loop { sleep 1 }
  end
end

ClientHTTPFixture.run(ARGV[0]) if $PROGRAM_NAME == __FILE__
