#!/usr/bin/env ruby
# Disposable source-derived Portal/MCP contract upstreams; loopback only.
require_relative "../../support/fixture_http"

module PromptNookProxyFixture
  PAYLOAD = ("portal binary\x00\xff response".b * 100).freeze
  COMPRESSED = FixtureHTTP.gzip(PAYLOAD).freeze
  AUDIT = '{"meta":{"response_kind":"lookup","lookup":{"identifier":"node-7"}},' \
          '"error":{"message":"safe error","code":"NOT_FOUND"}}'.freeze

  class Upstream
    def initialize(exchange)
      @exchange = exchange
    end

    def respond
      exchange = @exchange
      body = exchange.request_body
      path = exchange.path.split("?", 2)[0]
      status = 200
      reason = nil
      payload = "".b
      encoding = nil
      case path
      when "/mcp-ok"
        unless exchange.headers.get("Authorization") == "Bearer inert-mcp-token"
          raise "mcp authorization #{exchange.headers.raw_items.inspect}"
        end
        unless exchange.headers.get("Accept") == "application/json, text/plain;q=0.9, */*;q=0.8"
          raise "mcp accept #{exchange.headers.raw_items.inspect}"
        end
        payload = "ok".b
      when "/mcp-redirect"
        status = 302
        payload = "redirect".b
      when "/mcp-forbidden"
        status = 403
        payload = "forbidden".b
      when "/mcp-auth"
        status = 401
        payload = "authentication required".b
      when "/mcp-error"
        status = 418
        reason = "Custom Teapot"
        payload = "not the reason phrase".b
      when "/mcp-large"
        payload = "x" * 70_000
      else
        if path.end_with?("/gzip")
          payload = COMPRESSED
          encoding = "gzip"
        elsif path.end_with?("/audit")
          status = 404
          payload = AUDIT.b
        elsif path.end_with?("/cap")
          payload = "x" * 5000
        else
          payload = JSON.generate(
            "method" => exchange.command,
            "path" => exchange.path,
            "headers" => exchange.headers.items,
            "body" => Base64.strict_encode64(body)
          ).b
        end
      end
      exchange.send_response(status, reason)
      exchange.send_header("Content-Type", "application/json")
      exchange.send_header("Content-Length", payload.bytesize.to_s)
      exchange.send_header("Location", "/mcp-ok") if path == "/mcp-redirect"
      exchange.send_header("Content-Encoding", encoding) if encoding
      exchange.end_headers
      begin
        exchange.write(payload)
        exchange.flush
      rescue StandardError
        # Downstream cancelled the response.
      end
    end
  end

  def self.exchange(port, path, method = "GET", body = nil, headers = nil)
    FixtureHTTP.request(port, method, path, (headers || {}).to_a,
      body: body, host: "portal.inert")
  end

  def self.fields(headers)
    result = {}
    headers.each { |name, value| result[name.downcase] = value }
    result
  end

  def self.echo(port, path, expected_path, auth = nil, headers = nil, method = "GET", body = nil)
    supplied = headers || {}
    status, _, payload = exchange(port, path, method, body, headers)
    raise "#{path} status #{status}: #{payload.inspect}" unless status == 200

    result = JSON.parse(payload)
    seen = fields(result["headers"])
    raise "#{path} target #{result["path"].inspect}" unless result["path"] == expected_path
    raise "#{path} authorization #{seen.inspect}" unless seen["authorization"] == auth
    raise "#{path} host #{seen.inspect}" unless seen["host"] == supplied.fetch("Host", "portal.inert")
    unless seen["user-agent"] == supplied.fetch("User-Agent", "Crystal")
      raise "#{path} user-agent #{seen.inspect}"
    end
    if supplied.key?("Accept")
      raise "#{path} accept #{seen.inspect}" unless seen["accept"] == supplied["Accept"]
    elsif seen.key?("accept")
      raise "#{path} unexpected accept #{seen.inspect}"
    end
    raise "#{path} method #{result["method"].inspect}" unless result["method"] == method
    raise "#{path} body #{result["body"].inspect}" unless Base64.decode64(result["body"]) == (body || "".b)
    seen
  end

  def self.portal_cases(port)
    echo(port, "/portal-api/echo", "/api/admin/echo", "Bearer configured-token")
    echo(port, "/portal-api", "/api/admin/", "Bearer configured-token")
    echo(port, "/portal-api///echo?environment=secure&x=1&y=2&x=3&ENVIRONMENT=bad&empty&z=a+b&bad=%ZZ",
      "/secure/base/echo?x=1&x=3&y=2&empty=&z=a+b&bad=%25ZZ", "Bearer secure-token")
    echo(port, "/portal-api/echo?environment=incoming", "/api/admin/echo", "Bearer incoming",
      "Authorization" => "Bearer   incoming  ", "Host" => "custom.inert",
      "User-Agent" => "custom-agent", "Accept" => "text/plain")
    echo(port, "/portal-api/echo?environment=empty", "/api/admin/echo", "Bearer   incoming  ",
      "Authorization" => "Bearer   incoming  ")
    echo(port, "/portal-api/echo?environment=empty", "/api/admin/echo", "Basic inert",
      "Authorization" => "Basic inert")
    echo(port, "/portal-api/echo?environment=incoming", "/api/admin/echo", "Basic inert",
      "Authorization" => "Basic inert")
    echo(port, "/portal-api/echo?environment=axiom&environment=secure", "/api/admin/echo",
      "Bearer configured-token", {"Authorization" => "Bearer ignored"}, "PATCH", "body\x00\xff".b)
    echo(port, "/portal-api/echo?Environment=secure&x=one;x=two",
      "/api/admin/echo?x=one&x=two", "Bearer configured-token")
    echo(port, "/portal-api/echo", "/api/admin/echo", "Bearer configured-token", {"Accept" => ""})
    status, _, body = exchange(port, "/portal-api/echo?environ%6dent=secure")
    unless status == 400 && JSON.parse(body)["message"] == "No URL configured for environment: secureaxiom"
      raise "environment normalization #{status} #{body.inspect}"
    end
    ["", "missing", "AXIOM"].each do |selector|
      status, _, body = exchange(port, "/portal-api/echo?environment=#{selector}")
      raise "selector #{selector.inspect} status #{status}" unless status == 400

      expected = {
        "error" => "Invalid environment",
        "message" => "No URL configured for environment: #{selector}"
      }
      raise "selector #{selector.inspect} #{body.inspect}" unless JSON.parse(body) == expected
    end
    echo(port, "/portal-api/echo", "/legacy/echo", "Bearer inert-example-token",
      "X-Test-Legacy" => "1")
    status, _, body = exchange(port, "/portal-api/echo?environment=secure",
      "GET", nil, "X-Test-Legacy" => "1")
    raise "legacy disable #{status} #{body.inspect}" unless status == 400 && JSON.parse(body)["error"] == "Invalid environment"

    status, headers, body = exchange(port, "/portal-api/gzip")
    raise "gzip identity #{status} #{body.bytesize}" unless status == 200 && body == PAYLOAD
    raise "gzip identity kept encoding" if fields(headers).key?("content-encoding")

    ["gzip", ""].each do |encoding|
      status, headers, body = exchange(port, "/portal-api/gzip", "GET", nil, "Accept-Encoding" => encoding)
      raise "gzip #{encoding.inspect} #{status} #{body.bytesize}" unless status == 200 && body == COMPRESSED
      raise "gzip #{encoding.inspect} encoding #{fields(headers).inspect}" unless fields(headers)["content-encoding"] == "gzip"
    end
    status, _, body = exchange(port, "/portal-api/audit")
    unless status == 202 && JSON.parse(body)["meta"]["lookup"]["identifier"] == "node-7"
      raise "audit #{status} #{body.inspect}"
    end
    status, _, body = exchange(port, "/portal-api/echo?environment=refused")
    unless status == 502 && JSON.parse(body)["error"] == "Portal backend proxy failure"
      raise "refused #{status} #{body.inspect}"
    end
    status, _, body = exchange(port, "/portal-api/echo?environment=mismatch")
    unless status == 502 && JSON.parse(body)["message"].to_s.include?("certificate verify failed")
      raise "mismatch #{status} #{body.inspect}"
    end
  end

  def self.run(executable, directory)
    work = directory
    plain = FixtureHTTP::Server.new(Upstream).start
    secure = FixtureHTTP::Server.new(Upstream,
      tls: FixtureHTTP.tls_context(File.join(work, "server.pem"), File.join(work, "server.key"))).start
    refused = FixtureHTTP.refused_port
    ready = File.join(work, "proxy-ready")
    stop = File.join(work, "proxy-stop")
    [ready, stop].each { |path| File.delete(path) if File.exist?(path) }
    env = {
      "PN_TEST_HTTP" => "http://127.0.0.1:#{plain.port}",
      "PN_TEST_HTTPS" => "https://localhost:#{secure.port}",
      "PN_TEST_MISMATCH" => "https://127.0.0.1:#{secure.port}",
      "PN_TEST_REFUSED" => "http://127.0.0.1:#{refused}",
      "PN_TEST_CA" => File.join(work, "ca.pem"),
      "PN_TEST_READY" => ready,
      "PN_TEST_STOP" => stop
    }
    child = FixtureHTTP::Child.new(executable, env)
    begin
      1000.times do
        break if File.exist?(ready) || !child.running?

        sleep 0.01
      end
      raise "consumer did not start (#{child.poll.inspect})" unless File.exist?(ready)

      portal_cases(Integer(File.read(ready).strip))
    ensure
      File.write(stop, "")
      begin
        child.wait(15)
      rescue FixtureHTTP::Error
        child.kill
        child.wait(5)
        raise
      end
      plain.shutdown
      secure.shutdown
    end
    raise "consumer exit status #{child.exitstatus.inspect}" unless child.exitstatus.zero?

    puts "PromptNook Portal/MCP HTTP/HTTPS consumer contracts passed"
    $stdout.flush
  end
end

if $PROGRAM_NAME == __FILE__
  PromptNookProxyFixture.run(ARGV[0], ARGV[1])
end
