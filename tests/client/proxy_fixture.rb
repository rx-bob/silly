#!/usr/bin/env ruby
# Disposable proxy upstream and downstream integration driver; no external targets.
require "tmpdir"
require_relative "../support/fixture_http"

module ProxyFixture
  PAYLOAD = ((0..255).to_a.pack("C*") * 512).freeze
  COMPRESSED = FixtureHTTP.gzip(PAYLOAD).freeze
  PREFIX = ("p" * 262144).freeze

  class Upstream
    def initialize(exchange)
      @exchange = exchange
    end

    def respond
      exchange = @exchange
      path = exchange.path.split("?", 2)[0]
      case path
      when "/stall-header"
        sleep 2
        fixed("late".b)
        return
      when "/stall-upload"
        sleep 2
        exchange.request_body
        fixed("uploaded".b)
        return
      when "/stall-body"
        exchange.send_response(200)
        exchange.send_header("Content-Length", "1000000")
        exchange.end_headers
        exchange.write("initial")
        exchange.flush
        sleep 2
        exchange.write("later")
        return
      when "/reset"
        exchange.send_response(200)
        exchange.send_header("Content-Length", "1000000")
        exchange.end_headers
        exchange.write("before-reset")
        exchange.flush
        sleep 0.15
        exchange.abort_reset
        return
      when "/duplex"
        exchange.send_response(200)
        exchange.send_header("Transfer-Encoding", "chunked")
        exchange.end_headers
        exchange.write(PREFIX.bytesize.to_s(16) + "\r\n" + PREFIX + "\r\n")
        exchange.flush
        body = exchange.request_body
        exchange.write(body.bytesize.to_s(16) + "\r\n" + body + "\r\n0\r\n\r\n")
        exchange.flush
        return
      end
      exchange.request_body
      case path
      when "/health"
        fixed("healthy".b)
      when "/gzip"
        fixed(COMPRESSED, 200, [
          ["Content-Encoding", "gzip"],
          ["Content-Type", "application/octet-stream"]
        ])
      when "/audit"
        fixed("audited".b, 200, [["X-Audit", "visible"]])
      when "/large"
        fixed(PAYLOAD)
      when "/empty"
        fixed("".b, 204)
      when "/head"
        exchange.send_response(200)
        exchange.send_header("Content-Length", "123")
        exchange.send_header("Content-Encoding", "gzip")
        exchange.end_headers
      else
        fixed("unknown".b, 404)
      end
    end

    def fixed(body, code = 200, headers = [])
      exchange = @exchange
      exchange.send_response(code)
      exchange.send_header("Content-Length", body.bytesize.to_s)
      headers.each { |name, value| exchange.send_header(name, value) }
      exchange.end_headers
      return if exchange.command == "HEAD"

      exchange.write(body)
      exchange.flush
    end
  end

  class EchoUpstream < Upstream
    def respond
      if @exchange.path.start_with?("/echo")
        body = @exchange.request_body
        payload = JSON.generate(
          "method" => @exchange.command,
          "path" => @exchange.path,
          "headers" => @exchange.headers.raw_items,
          "body" => Base64.strict_encode64(body)
        ).b
        fixed(payload, 200, [
          ["Content-Type", "application/json"],
          ["Connection", "X-Response-Hop, close"],
          ["X-Response-Hop", "secret"],
          ["Set-Cookie", "a=1"],
          ["Set-Cookie", "b=2"]
        ])
      else
        super
      end
    end
  end

  def self.exchange(port, path, method = "GET", body = nil, headers = nil, chunks: nil)
    FixtureHTTP.request(port, method, path, (headers || {}).to_a,
      body: body, chunks: chunks,
      host: "127.0.0.1:#{port}",
      accept_encoding: "identity",
      close: true)
  end

  def self.fields(headers)
    result = {}
    headers.each { |name, value| result[name.downcase] = value }
    result
  end

  def self.healthy(port)
    deadline = FixtureHTTP.monotonic + 3
    while FixtureHTTP.monotonic < deadline
      begin
        status, _, body = exchange(port, "/health")
        return if status == 200 && body == "healthy"
      rescue StandardError
        # Retry until the upstream slot is released.
      end
      sleep 0.01
    end
    raise "upstream capacity was not reclaimed after downstream completion/cancellation"
  end

  def self.echo_cases(port, upstream)
    binary = (0..255).to_a.pack("C*") * 1024
    [
      ["/echo?x=1&x=2&empty=", nil, "127.0.0.1:#{upstream}"],
      ["/incoming/echo", "Bearer incoming", "downstream.example"],
      ["/override/echo", "Bearer supplied", "custom.upstream"]
    ].each do |path, auth, host|
      status, headers, body = exchange(port, path, "PATCH", binary,
        "Host" => "downstream.example",
        "Authorization" => "Bearer incoming",
        "X-Override" => "incoming",
        "X-Request-Hop" => "drop-me",
        "Connection" => "X-Request-Hop, close",
        "X-End-To-End" => "kept",
        "Content-Type" => "application/octet-stream")
      raise "#{path} status #{status}: #{body.inspect}" unless status == 200

      value = JSON.parse(body)
      seen = fields(value["headers"])
      unless value["method"] == "PATCH" && Base64.decode64(value["body"]) == binary
        raise "#{path} did not echo the request method or body"
      end
      raise "#{path} authorization #{seen.inspect}" unless seen["authorization"] == auth
      unless seen["host"] == host && seen["x-override"] == "configured"
        raise "#{path} host/override #{seen.inspect}"
      end
      unless !seen.key?("x-request-hop") && seen["x-end-to-end"] == "kept"
        raise "#{path} hop-by-hop forwarding #{seen.inspect}"
      end
      if fields(headers).key?("x-response-hop")
        raise "#{path} forwarded the nominated response hop header"
      end
      cookies = headers.select { |name, _| name.downcase == "set-cookie" }.map { |_, value| value }
      raise "#{path} cookies #{cookies.inspect}" unless cookies == ["a=1", "b=2"]
      if path.start_with?("/echo?") && value["path"] != "/echo?x=1&x=2&empty="
        raise "#{path} target #{value["path"].inspect}"
      end
    end
    status, _, body = exchange(port, "/rewrite/nested?q=one&q=two", "PUT", "rewrite".b)
    unless status == 200 && JSON.parse(body)["path"] == "/echo/nested?q=one&q=two"
      raise "rewrite target #{status} #{body.inspect}"
    end
    status, _, body = exchange(port, "/buffered", "POST", "\x00buffered\xff".b)
    unless status == 200 && Base64.decode64(JSON.parse(body)["body"]) == "\x00buffered\xff".b
      raise "buffered upload #{status} #{body.inspect}"
    end
    # Unknown-length downstream body exercises dechunked upload and recomputed framing.
    status, _, body = exchange(port, "/echo", "POST", nil, nil,
      chunks: ["chunk\x00".b, "ed\xff".b])
    unless status == 200 && Base64.decode64(JSON.parse(body)["body"]) == "chunk\x00ed\xff".b
      raise "dechunked upload #{status} #{body.inspect}"
    end
  end

  def self.response_cases(port)
    status, headers, body = exchange(port, "/gzip", "GET", nil, "Accept-Encoding" => "gzip")
    unless status == 200 && body == COMPRESSED && fields(headers)["content-encoding"] == "gzip"
      raise "gzip passthrough #{status} #{fields(headers).inspect}"
    end
    raise "gzip passthrough kept an upstream length" if fields(headers).key?("content-length")

    status, headers, body = exchange(port, "/auto/gzip", "GET", nil, "Accept-Encoding" => "gzip")
    raise "auto gzip body #{body.bytesize}" unless status == 200 && body == PAYLOAD
    if fields(headers).key?("content-encoding") || fields(headers).key?("content-length")
      raise "auto gzip framing #{fields(headers).inspect}"
    end

    status, headers, body = exchange(port, "/head", "HEAD")
    unless status == 200 && body == "".b && fields(headers)["content-length"] == "123"
      raise "head #{status} #{fields(headers).inspect}"
    end
    status, _, body = exchange(port, "/empty")
    raise "empty #{status} #{body.inspect}" unless status == 204 && body == "".b
    status, _, body = exchange(port, "/audit")
    raise "audit #{status} #{body.inspect}" unless status == 201 && body == "audited"
    status, _, body = exchange(port, "/cap")
    raise "cap #{status} #{body.inspect}" unless status == 502 && body == "upstream failure"
    status, _, body = exchange(port, "/mapped")
    raise "mapped #{status} #{body.inspect}" unless status == 599 && body == "mapped failure"
    status, _, body = exchange(port, "/__stats")
    unless status == 200 && body.split(",")[0, 2] == ["1", "7"]
      raise "stats #{status} #{body.inspect}"
    end
  end

  def self.duplex(port)
    body = (0..255).to_a.pack("C*") * 4096
    socket = TCPSocket.new("127.0.0.1", port)
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 2048)
    socket.write("POST /duplex HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
    socket.write(body.byteslice(0, 1))
    # A response must arrive before upload completion; ordinary forwarding is incremental.
    code, headers = FixtureHTTP.read_head(socket)
    raise "duplex status #{code}" unless code == 200

    sleep 0.1
    failures = []
    sender = Thread.new do
      begin
        socket.write(body.byteslice(1, body.bytesize - 1))
      rescue StandardError => error
        failures << error
      end
    end
    sleep 0.1
    received = FixtureHTTP.read_body(socket, code, headers, "POST")
    sender.join(10)
    raise "duplex uploader still blocked" if sender.alive?
    raise "duplex upload failed: #{failures.first.inspect}" unless failures.empty?

    expected = PREFIX + body
    raise "duplex body #{received.bytesize} != #{expected.bytesize}" unless received == expected
  ensure
    begin
      socket.close
    rescue StandardError
      # Already closed.
    end if socket
  end

  def self.reset_and_cancel(port)
    # Health retries can themselves fail admission while the previous slot is being released.
    # Each deliberate abort has its own retained proxy tag; unrelated cleanup cannot affect it.
    before = exchange(port, "/__stats")[2].split(",").map(&:to_i)[6, 9]
    raise "abort tags must start unused: #{before.inspect}" unless before == [0] * 9

    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("GET /reset HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    data = "".b
    loop do
      begin
        part = socket.readpartial(4096)
      rescue EOFError, Errno::ECONNRESET
        break
      end
      data << part
    end
    socket.close
    unless data.start_with?("HTTP/1.1 200 ") && data.include?("before-reset")
      raise "reset framing #{data.inspect}"
    end
    unless data.scan("HTTP/1.1").length == 1 && !data.end_with?("0\r\n\r\n")
      raise "reset framing #{data.inspect}"
    end
    healthy(port)
    ["/connect-stall", "/stall-upload", "/stall-header", "/stall-body"].each do |path|
      2.times do
        socket = TCPSocket.new("127.0.0.1", port)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
        if path == "/stall-upload"
          socket.write("POST /stall-upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\nabc")
        else
          socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n")
        end
        if path == "/stall-body"
          unless socket.readpartial(1024).start_with?("HTTP/1.1 200 ")
            raise "stall body did not start a response"
          end
        else
          sleep 0.05
        end
        socket.close
        healthy(port)
      end
    end
    after = exchange(port, "/__stats")[2].split(",").map(&:to_i)[6, 9]
    unless after == [1] * 9
      raise "exactly one cancellation for each tagged aborted stream: #{after.inspect}"
    end
  end

  def self.run(executable, work)
    server = FixtureHTTP::Server.new(EchoUpstream).start
    stall = FixtureHTTP::DrainServer.new(5).start
    refused = FixtureHTTP.refused_port
    ready = File.join(work, "ready")
    stop = File.join(work, "stop")
    env = {
      "SILLY_PROXY_UPSTREAM" => "http://127.0.0.1:#{server.port}",
      "SILLY_PROXY_REFUSED" => "http://127.0.0.1:#{refused}",
      "SILLY_PROXY_STALL" => "https://127.0.0.1:#{stall.port}",
      "SILLY_PROXY_READY" => ready,
      "SILLY_PROXY_STOP" => stop
    }
    child = FixtureHTTP::Child.new(executable, env)
    shutdown_socket = nil
    begin
      deadline = FixtureHTTP.monotonic + 10
      port = nil
      while child.running? && FixtureHTTP.monotonic < deadline
        begin
          text = File.read(ready).strip
          if text.match?(/\A\d+\z/) && text.to_i.between?(1, 65_535)
            port = text.to_i
            break
          end
        rescue Errno::ENOENT
          # Not published yet.
        end
        sleep 0.01
      end
      raise "proxy did not publish a complete port (#{child.poll.inspect})" if port.nil?

      healthy(port)
      echo_cases(port, server.port)
      response_cases(port)
      duplex(port)
      reset_and_cancel(port)
      # Stop the server with an active response; fixture main must drain the client worker.
      shutdown_socket = TCPSocket.new("127.0.0.1", port)
      shutdown_socket.write("GET /stall-body HTTP/1.1\r\nHost: localhost\r\n\r\n")
      unless shutdown_socket.readpartial(1024).start_with?("HTTP/1.1 200 ")
        raise "shutdown response did not start"
      end
      puts "proxy streaming, policies, framing, inspection and cancellation passed"
      $stdout.flush
    ensure
      File.write(stop, "")
      begin
        child.wait(15)
      rescue FixtureHTTP::Error
        child.kill
        child.wait(5)
        raise
      end
      begin
        shutdown_socket.close
      rescue StandardError
        # Already closed.
      end if shutdown_socket
      server.shutdown
      stall.shutdown
    end
    raise "proxy exit status #{child.exitstatus.inspect}" unless child.exitstatus.zero?
  end
end

if $PROGRAM_NAME == __FILE__
  Dir.mktmpdir("silly-proxy-fixture-") do |directory|
    ProxyFixture.run(ARGV[0], directory)
  end
end
